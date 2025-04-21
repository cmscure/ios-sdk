#if canImport(UIKit)
import UIKit
#endif
import Foundation
import SwiftUICore
import SocketIO
import CryptoKit
import Combine

public typealias Cure = CMSCureSDK

public class CMSCureSDK {
    public static let shared = CMSCureSDK()
    private var projectSecret: String
    private var lastSyncCheck: Date?
    private let cacheFilePath: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCure")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }()
    
    
    public var debugLogsEnabled: Bool = true
    public var pollingInterval: TimeInterval = 300 {
        didSet {
            if pollingInterval < 60 {
                pollingInterval = 60
            } else if pollingInterval > 600 {
                pollingInterval = 600
            }
        }
    }
    private var apiSecret: String?
    private var symmetricKey: SymmetricKey?
    
    private var currentLanguage: String = "en"
    private var cache: [String: [String: [String: String]]] = [:] // screenName -> [key: [language: value]]
    private var translationUpdateHandlers: [String: ([String: String]) -> Void] = [:]
    private var socket: SocketIOClient?
    private var manager: SocketManager?
    private var serverUrl = "10.12.23.144"
    private var offlineTabList: [String] = []
    
    private init() {
        self.projectSecret = ""
        self.apiSecret = nil
        self.symmetricKey = nil
        self.pollingInterval = 300
        self.loadCacheFromDisk()
        startListening()
        observeAppActiveNotification()
    }
    
    public func setAPISecret(_ secret: String) {
        self.apiSecret = secret
        if let secretData = secret.data(using: .utf8) {
            self.symmetricKey = SymmetricKey(data: SHA256.hash(data: secretData))
        }
    }
    
    private func encryptBody(_ body: [String: Any]) -> Data? {
        guard let symmetricKey = symmetricKey else { return nil }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        
        guard let sealedBox = try? AES.GCM.seal(jsonData, using: symmetricKey) else { return nil }
        
        let result: [String: String] = [
            "iv": sealedBox.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
            "ciphertext": sealedBox.ciphertext.base64EncodedString(),
            "tag": sealedBox.tag.base64EncodedString()
        ]
        return try? JSONSerialization.data(withJSONObject: result)
    }
    
    public func setLanguage(_ language: String, force: Bool = false, completion: (() -> Void)? = nil) {
        guard language != self.currentLanguage else {
            completion?()
            return
        }
        self.currentLanguage = language
        UserDefaults.standard.set(language, forKey: "selectedLanguage")
        
        let frozenLanguage = language // 👈 freeze the reference
        let group = DispatchGroup()
        
        for screenName in cache.keys {
            if self.debugLogsEnabled {
                print("🔄 Switching to language '\(frozenLanguage)' for tab '\(screenName)'")
            }
            
            // Immediately trigger UI update with cached data
            var cached: [String: String] = [:]
            if let tabCache = self.cache[screenName] {
                for (key, valueMap) in tabCache {
                    if let translatedValue = valueMap[frozenLanguage] {
                        cached[key] = translatedValue
                    }
                }
            }
            DispatchQueue.main.async {
                self.translationUpdateHandlers[screenName]?(cached)
                CureTranslationBridge.shared.refreshToken = UUID()
                NotificationCenter.default.post(name: .translationsUpdated, object: nil, userInfo: [
                    "screenName": screenName
                ])
            }
            
            // Then sync for latest updates
            group.enter()
            self.sync(screenName: screenName) { success in
                if success {
                    var updated: [String: String] = [:]
                    if let tabCache = self.cache[screenName] {
                        for (key, valueMap) in tabCache {
                            if let translatedValue = valueMap[frozenLanguage] {
                                updated[key] = translatedValue
                            }
                        }
                    }
                    DispatchQueue.main.async {
                        self.translationUpdateHandlers[screenName]?(updated)
                        CureTranslationBridge.shared.refreshToken = UUID()
                        NotificationCenter.default.post(name: .translationsUpdated, object: nil, userInfo: [
                            "screenName": screenName
                        ])
                    }
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            completion?()
        }
    }
    
    public func getLanguage() -> String {
        return self.currentLanguage
    }
    
    public func clearCache() {
        cache.removeAll()
    }
    
    public func translation(for key: String, inTab screenName: String) -> String {
        if self.debugLogsEnabled {
            print("🔍 Reading '\(key)' from '\(screenName)' in '\(self.currentLanguage)'")
        }
        
        if let tab = cache[screenName] {
            if let keyMap = tab[key] {
                if let translation = keyMap[self.currentLanguage] {
                    return translation
                }
                if self.debugLogsEnabled {
                    print("⚠️ No translation found for key '\(key)' in language '\(self.currentLanguage)'")
                }
            } else if self.debugLogsEnabled {
                print("⚠️ Key '\(key)' not found or corrupted in tab '\(screenName)'")
            }
        } else if self.debugLogsEnabled {
            print("⚠️ Screen '\(screenName)' not present or corrupted in cache")
        }
        return ""
    }
    
    public func sync(screenName: String, completion: @escaping (Bool) -> Void) {
        guard let token = UserDefaults.standard.string(forKey: "authToken") ?? self.readTokenFromConfig(),
              let projectId = self.readProjectIdFromConfig() else {
            if self.debugLogsEnabled {
                print("❌ Missing auth token or project ID")
            }
            completion(false)
            return
        }
        
        let versionURL = URL(string: "http://\(serverUrl):5050/api/translations/\(projectId)/version")!
        var versionRequest = URLRequest(url: versionURL)
        versionRequest.httpMethod = "GET"
        versionRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: versionRequest) { data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let remoteVersion = json["versionNumber"] as? Int else {
                if self.debugLogsEnabled {
                    print("❌ Failed to get version info: \(error?.localizedDescription ?? "Unknown error")")
                }
                DispatchQueue.main.async { completion(false) }
                return
            }
            print("BEFORE API CALL: \("http://\(self.serverUrl):5050/api/sdk/translations/\(projectId)/\(screenName)")")
            let url = URL(string: "http://\(self.serverUrl):5050/api/sdk/translations/\(projectId)/\(screenName)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body = ["projectId": projectId, "screenName": screenName]
            request.httpBody = self.encryptBody(body)
            if let bodyData = request.httpBody, let symmetricKey = self.symmetricKey {
                let signature = HMAC<SHA256>.authenticationCode(for: bodyData, using: symmetricKey)
                request.setValue(Data(signature).base64EncodedString(), forHTTPHeaderField: "X-Signature")
            }
            
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    if self.debugLogsEnabled {
                        print("❌ HTTP request failed with status code: \(httpResponse.statusCode)")
                    }
                    completion(false)
                    return
                }
                print("📥 Raw response for \(screenName):", String(data: data ?? Data(), encoding: .utf8) ?? "nil")
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let keys = json["keys"] as? [[String: Any]] else {
                    if self.debugLogsEnabled {
                        print("❌ Failed to parse translations for tab '\(screenName)': \(error?.localizedDescription ?? "Unknown error")")
                    }
                    completion(false)
                    return
                }
                
                self.cache[screenName] = [:]
                var tabValues: [String: String] = [:]
                for item in keys {
                    if let k = item["key"] as? String,
                       let values = item["values"] as? [String: String] {
                        for (lang, val) in values {
                            self.cache[screenName, default: [:]][k, default: [:]][lang] = val
                            if self.debugLogsEnabled {
                                print("📝 Updated cache[\(screenName)][\(k)][\(lang)] = \(val)")
                            }
                        }
                        if let v = values[self.currentLanguage] {
                            tabValues[k] = v
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.translationUpdateHandlers[screenName]?(tabValues)
                }
                
                DispatchQueue.main.async {
                    CureTranslationBridge.shared.refreshToken = UUID()
                    NotificationCenter.default.post(name: .translationsUpdated, object: nil, userInfo: [
                        "screenName": screenName
                    ])
                }
                
                DispatchQueue.global(qos: .background).async {
                    self.saveCacheToDisk()
                }
                
                if self.debugLogsEnabled {
                    print("✅ Synced translations for \(screenName): \(tabValues)")
                }
                
                completion(true)
            }.resume()
        }.resume()
    }
    
    public func connectSocket(apiKey: String, projectId: String) {
        if socket != nil, socket?.status == .connected {
            if self.debugLogsEnabled {
                print("⚠️ Socket already connected — skipping reinitialization.")
            }
            return
        }
        
        guard let url = URL(string: "http://\(serverUrl):5050") else { return }
        manager = SocketManager(socketURL: url, config: [.log(true), .compress])
        if self.manager == nil {
            print("⚠️ Failed to create SocketManager for URL: \(url)")
        }
        socket = manager?.defaultSocket
        
        socket?.on(clientEvent: .connect) { data, ack in
            if self.debugLogsEnabled {
                print("🟢 Socket connected")
            }
            let body = ["projectId": projectId]
            if var sealed = try? JSONSerialization.jsonObject(with: self.encryptBody(body) ?? Data(), options: []) as? [String: Any] {
                sealed["projectId"] = projectId
                self.socket?.emit("handshake", sealed)
            } else {
                print("❌ Failed to encrypt handshake payload, falling back")
                self.socket?.emit("handshake", ["projectId": projectId])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if self.debugLogsEnabled {
                    print("⚠️ No handshake ack received within 5 seconds. Falling back to manual sync if needed.")
                }
            }
        }
        
        socket?.on("handshake_ack") { data, ack in
            if self.debugLogsEnabled {
                print("🤝 Handshake acknowledged with server")
            }
            
            for screenName in self.cache.keys {
                self.sync(screenName: screenName) { success in
                    if success, self.debugLogsEnabled {
                        self.syncIfOutdated()
                        print("🔁 Synced '\(screenName)' on reconnect to catch up updates")
                    }
                }
            }
            
        }
        
        socket?.on(clientEvent: .disconnect) { data, ack in
            if self.debugLogsEnabled {
                print("🔌 Socket disconnected")
            }
        }
        
        socket?.on(clientEvent: .error) { data, _ in
            if self.debugLogsEnabled {
                print("❌ Socket error: \(data)")
            }
        }
        
        socket?.on(clientEvent: .reconnectAttempt) { data, _ in
            if self.debugLogsEnabled {
                print("🔁 Attempting to reconnect socket...")
            }
        }
        
        socket?.on("translationsUpdated") { [weak self] data, ack in
            guard let dict = data.first as? [String: Any],
                  let screenName = dict["screenName"] as? String else {
                print("⚠️ Invalid real-time data:", data)
                return
            }
            print("📡 Real-time update received for '\(screenName)' — posting notification")
            CureTranslationBridge.shared.refreshToken = UUID()
            NotificationCenter.default.post(name: .translationsUpdated, object: nil, userInfo: ["screenName": screenName])
            self?.handleSocketTranslationUpdate(data: data)
        }
        
        socket?.connect()
    }
    
    public func startListening() {
        guard socket == nil else {
            if self.debugLogsEnabled {
                print("⚠️ Socket is already connected but data is missing in config.")
            }
            return
        }
        
        let configDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
        let configFilePath = configDir.appendingPathComponent("config.json")
        
        guard let data = try? Data(contentsOf: configFilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let projectId = json["projectId"],
              let token = json["authToken"] else {
            if self.debugLogsEnabled {
                print("❌ Failed to load config for socket connection")
            }
            return
        }
        
        guard let url = URL(string: "http://\(serverUrl):5050") else { return }
        manager = SocketManager(socketURL: url, config: [.log(true), .compress])
        socket = manager?.defaultSocket
        
        socket?.on(clientEvent: .connect) { data, ack in
            if self.debugLogsEnabled {
                print("🟢 Socket connected")
            }
            let body = ["projectId": projectId]
            if var sealed = try? JSONSerialization.jsonObject(with: self.encryptBody(body) ?? Data(), options: []) as? [String: Any] {
                sealed["projectId"] = projectId
                self.socket?.emit("handshake", sealed)
            } else {
                print("❌ Failed to encrypt handshake payload, falling back")
                self.socket?.emit("handshake", ["projectId": projectId])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if self.debugLogsEnabled {
                    print("⚠️ No handshake ack received within 5 seconds. Falling back to manual sync if needed.")
                }
            }
        }
        
        socket?.on("handshake_ack") { data, ack in
            if self.debugLogsEnabled {
                print("🤝 Handshake acknowledged with server")
            }
        }
        
        socket?.on(clientEvent: .disconnect) { data, ack in
            if self.debugLogsEnabled {
                print("🔌 Socket disconnected")
            }
        }
        
        socket?.on(clientEvent: .error) { data, _ in
            if self.debugLogsEnabled {
                print("❌ Socket error: \(data)")
            }
        }
        
        socket?.on(clientEvent: .reconnectAttempt) { data, _ in
            if self.debugLogsEnabled {
                print("🔁 Attempting to reconnect socket...")
            }
        }
        
        
        guard socket?.status != .connected else { return }
        socket?.connect()
    }
    
    public func authenticate(apiKey: String, projectId: String, projectSecret: String, completion: @escaping (Bool) -> Void) {
        let url = URL(string: "http://\(serverUrl):5050/api/sdk/auth?projectId=\(projectId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
    let body = ["apiKey": apiKey, "projectId": projectId, "projectSecret": projectSecret]
    self.setAPISecret(projectSecret)
    request.httpBody = encryptBody(body)
        if self.debugLogsEnabled {
            print("🛡️ Auth Body Payload:", body)
            if let encoded = request.httpBody {
                print("📦 Encoded Body:", String(data: encoded, encoding: .utf8) ?? "invalid")
            } else {
                print("❌ Failed to encode auth body")
            }
        }
        guard request.httpBody != nil else {
            if self.debugLogsEnabled {
                print("❌ Encryption returned nil. Skipping request.")
            }
            completion(false)
            return
        }
        if let bodyData = request.httpBody, let symmetricKey = symmetricKey {
            let signature = HMAC<SHA256>.authenticationCode(for: bodyData, using: symmetricKey)
            request.setValue(Data(signature).base64EncodedString(), forHTTPHeaderField: "X-Signature")
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                if self.debugLogsEnabled {
                    print("❌ HTTP request failed with status code: \(httpResponse.statusCode)")
                }
                completion(false)
                return
            }
            
            guard let data = data,
                  let result = try? JSONDecoder().decode(AuthResult.self, from: data),
                  let token = result.token else {
                if self.debugLogsEnabled {
                    print("❌ Authentication failed: \(error?.localizedDescription ?? "Decoding failed")")
                }
                completion(false)
                return
            }
            
            var config: [String: String] = [
                "projectId": projectId,
                "authToken": token,
                "projectSecret": projectSecret
            ]
            
            do {
                let configDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                let configFilePath = configDir.appendingPathComponent("config.json")
                let jsonData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
                try jsonData.write(to: configFilePath)
                if self.debugLogsEnabled {
                    print("✅ Authenticated and saved config at \(configFilePath.path)")
                }
                self.projectSecret = projectSecret
                self.connectSocket(apiKey: apiKey, projectId: projectId)
                completion(true)
            } catch {
                if self.debugLogsEnabled {
                    print("❌ Failed to save config: \(error)")
                }
                completion(false)
            }
        }.resume()
    }
    
    public func isTabSynced(_ tab: String) -> Bool {
        return !(cache[tab]?.isEmpty ?? true)
    }
    
    public func isConnected() -> Bool {
        return socket?.status == .connected
    }
    
    public func stopListening() {
        socket?.disconnect()
        socket = nil
        manager = nil
        if self.debugLogsEnabled {
            print("🔌 Socket disconnected")
        }
    }
    
    public func onTranslationsUpdated(for screenName: String, handler: @escaping ([String: String]) -> Void) {
        self.translationUpdateHandlers[screenName] = handler
    }
    
    public func colorValue(for key: String) -> String? {
        if self.debugLogsEnabled {
            print("🎨 Reading global color value for key '\(key)'")
        }
        
        if let colorTab = cache["__colors__"] {
            if let valueMap = colorTab[key] {
                return valueMap["color"]
            } else if self.debugLogsEnabled {
                print("⚠️ Color key '\(key)' not found in global tab '__colors__'")
            }
        } else if self.debugLogsEnabled {
            print("⚠️ Global color tab '__colors__' not found in cache")
        }
        return nil
    }
    
    private func readTokenFromConfig() -> String? {
        let configDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
        let configFilePath = configDir.appendingPathComponent("config.json")
        
        guard let data = try? Data(contentsOf: configFilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let token = json["authToken"] else {
            return nil
        }
        
        return token
    }
    
    private func readProjectIdFromConfig() -> String? {
        let configDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
        let configFilePath = configDir.appendingPathComponent("config.json")
        
        guard let data = try? Data(contentsOf: configFilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let projectId = json["projectId"] else {
            return nil
        }
        
        return projectId
    }
    
    private func readProjectSecretFromConfig() -> String? {
        let configDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
        let configFilePath = configDir.appendingPathComponent("config.json")
        
        guard let data = try? Data(contentsOf: configFilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let secret = json["projectSecret"] else {
            return nil
        }
        
        return secret
    }
    
    public func availableLanguages(completion: @escaping ([String]) -> Void) {
        guard let token = UserDefaults.standard.string(forKey: "authToken") ?? self.readTokenFromConfig(),
              let projectId = self.readProjectIdFromConfig() else {
            if self.debugLogsEnabled {
                print("❌ Missing auth token or project ID")
            }
            completion([])
            return
        }
        
        let url = URL(string: "http://\(serverUrl):5050/api/sdk/languages/\(projectId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["projectId": projectId]
        request.httpBody = encryptBody(body)
        if let bodyData = request.httpBody, let symmetricKey = symmetricKey {
            let signature = HMAC<SHA256>.authenticationCode(for: bodyData, using: symmetricKey)
            request.setValue(Data(signature).base64EncodedString(), forHTTPHeaderField: "X-Signature")
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            let j = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
            print("📦 Raw translation payload:", j ?? [:])
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let languages = json["languages"] as? [String] else {
                if self.debugLogsEnabled {
                    print("❌ Failed to fetch available languages: \(error?.localizedDescription ?? "Unknown error")")
                }
                // ✅ Fallback to cached languages
                if !self.cache.isEmpty {
                    var allLangs: Set<String> = []
                    for (_, tabValues) in self.cache {
                        for (_, langMap) in tabValues {
                            for lang in langMap.keys {
                                allLangs.insert(lang)
                            }
                        }
                    }
                    
                    let uniqueLangs = Array(allLangs)
                    DispatchQueue.main.async {
                        if self.debugLogsEnabled {
                            print("⚠️ Using cached languages: \(uniqueLangs)")
                        }
                        completion(uniqueLangs)
                    }
                    return
                }
                completion([])
                return
            }
            
            if self.debugLogsEnabled {
                print("🌐 Available languages: \(languages)")
            }
            completion(languages)
        }.resume()
    }
    
    private struct AuthResult: Decodable {
        let token: String?
        let projectSecret: String?
    }
    
    public func printEncryptedPayloadForTesting(apiKey: String, projectId: String) {
        let payload = ["apiKey": apiKey, "projectId": projectId]
        guard let data = encryptBody(payload),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: String],
              let iv = json["iv"], let ct = json["ciphertext"], let tag = json["tag"] else {
            print("❌ Failed to generate encrypted test payload.")
            return
        }
        
        print("""
        🔐 Encrypted Payload for Postman (use as raw JSON):
        {
          "iv": "\(iv)",
          "ciphertext": "\(ct)",
          "tag": "\(tag)"
        }
        """)
    }
    
    private func saveCacheToDisk() {
        do {
            // Sanitize cache by ensuring all inner values are [String: String]
            var sanitizedCache: [String: [String: [String: String]]] = [:]
            
            for (tab, keys) in self.cache {
                var sanitizedKeys: [String: [String: String]] = [:]
                for (key, langMap) in keys {
                    var sanitizedLangMap: [String: String] = [:]
                    for (lang, value) in langMap {
                        if let strVal = value as? String {
                            sanitizedLangMap[lang] = strVal
                        } else if self.debugLogsEnabled {
                            print("⚠️ Skipping invalid value for key '\(key)'[\(lang)] = \(value) (\(type(of: value)))")
                        }
                    }
                    sanitizedKeys[key] = sanitizedLangMap
                }
                sanitizedCache[tab] = sanitizedKeys
            }
            
            let data = try JSONSerialization.data(withJSONObject: sanitizedCache, options: .prettyPrinted)
            try data.write(to: self.cacheFilePath)
            if self.debugLogsEnabled {
                print("💾 Saved cache to disk.")
            }
            
        } catch {
            if self.debugLogsEnabled {
                print("❌ Failed to save cache or versions: \(error)")
            }
        }
    }
    
    private func loadCacheFromDisk() {
        guard FileManager.default.fileExists(atPath: self.cacheFilePath.path) else {
            if self.debugLogsEnabled {
                print("⚠️ No cache file found at startup.")
            }
            return
        }
        
        _ = CureTranslationBridge.shared
        
        do {
            let data = try Data(contentsOf: self.cacheFilePath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: [String: String]]] {
                self.cache = json
                if self.debugLogsEnabled {
                    print("📦 Loaded cache from disk with tabs: \(self.cache.keys.joined(separator: ", "))")
                }
                
                DispatchQueue.main.async {
                    for tab in self.cache.keys {
                        CureTranslationBridge.shared.refreshToken = UUID()
                        NotificationCenter.default.post(name: .translationsUpdated, object: nil, userInfo: ["screenName": tab])
                    }
                }
            }
            let tabListPath = self.cacheFilePath.deletingLastPathComponent().appendingPathComponent("tabs.json")
            if let tabData = try? Data(contentsOf: tabListPath),
               let tabs = try? JSONSerialization.jsonObject(with: tabData) as? [String] {
                self.offlineTabList = tabs
            }
            
        } catch {
            if self.debugLogsEnabled {
                print("❌ Failed to load cache or versions from disk: \(error)")
            }
        }
    }
    
    
    private func observeAppActiveNotification() {
#if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.debugLogsEnabled == true {
                print("📲 App became active — checking for outdated content")
            }
            DispatchQueue.main.async {
                self?.syncIfOutdated()
            }
        }
        
#endif
        Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.debugLogsEnabled {
                print("⏰ Polling triggered — syncing all tabs")
            }
            DispatchQueue.main.async {
                self.syncIfOutdated()
            }
        }
    }
    
    private func syncIfOutdated() {
        let tabsToSync = Array(Set(self.cache.keys).union(Set(self.offlineTabList)).union(["__colors__","__images__"]))
        
        for tab in tabsToSync {
            self.sync(screenName: tab) { success in
                if success {
                    DispatchQueue.main.async {
                        CureTranslationBridge.shared.refreshToken = UUID()
                        NotificationCenter.default.post(name: .translationsUpdated, object: nil, userInfo: [
                            "screenName": tab
                        ])
                    }
                }
            }
        }
    }
    
    private func handleSocketTranslationUpdate(data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let screenName = dict["screenName"] as? String else {
            if self.debugLogsEnabled {
                print("⚠️ Invalid socket data format: \(data)")
            }
            return
        }

        if self.debugLogsEnabled {
            print("📡 Socket update received for tab: \(screenName)")
        }

        if screenName == "__ALL__" {
            let allTabs = Array(Set(self.cache.keys).union(Set(self.offlineTabList)))
            for tab in allTabs {
                self.sync(screenName: tab) { success in
                    if success {
                        var updated: [String: String] = [:]
                        if let tabCache = self.cache[tab] {
                            for (key, valueMap) in tabCache {
                                if let translatedValue = valueMap[self.currentLanguage] {
                                    updated[key] = translatedValue
                                }
                            }
                        }
                        DispatchQueue.main.async {
                            self.translationUpdateHandlers[tab]?(updated)
                            CureTranslationBridge.shared.refreshToken = UUID()
                            NotificationCenter.default.post(name: .translationsUpdated, object: nil, userInfo: [
                                "screenName": tab
                            ])
                        }
                    } else if self.debugLogsEnabled {
                        print("❌ Failed to sync tab '\(tab)' during __ALL__ update")
                    }
                }
            }
            return
        }

        self.sync(screenName: screenName) { success in
            if success {
                DispatchQueue.main.async {
                    if self.debugLogsEnabled {
                        print("📣 Posting Notification + Forcing view refresh for: \(screenName)")
                    }
                    NotificationCenter.default.post(name: .translationsUpdated, object: nil, userInfo: [
                        "screenName": screenName
                    ])
                }
            } else if self.debugLogsEnabled {
                print("❌ Failed to refresh tab '\(screenName)' after socket update")
            }
        }
    }
    
}

extension Color {
    init?(hex: String?) {
        guard let hex = hex?.replacingOccurrences(of: "#", with: ""), hex.count == 6 else { return nil }
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        self.init(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }
}

extension Notification.Name {
    public static let translationsUpdated = Notification.Name("translationsUpdated")
}

enum CMSCureSDKError: Error {
    case missingTokenOrProjectId
    case invalidResponse
    case decodingFailed
    case syncFailed(String)
    case socketDisconnected
}

extension String {
    private var bridgeWatcher: UUID {
        CureTranslationBridge.shared.refreshToken
    }

    public func cure(tab: String) -> String {
        _ = bridgeWatcher
        return Cure.shared.translation(for: self, inTab: tab)
    }
}

public final class CureString: ObservableObject {
    private let key: String
    private let tab: String

    @Published public private(set) var value: String = ""

    public init(_ key: String, tab: String) {
        self.key = key
        self.tab = tab
        self.value = Cure.shared.translation(for: key, inTab: tab)

        NotificationCenter.default.addObserver(self, selector: #selector(updateValue), name: .translationsUpdated, object: nil)
    }

    @objc private func updateValue(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let updatedTab = userInfo["screenName"] as? String,
              updatedTab == tab || updatedTab == "__ALL__" else { return }

        self.value = Cure.shared.translation(for: key, inTab: tab)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

final class CureTranslationBridge: ObservableObject {
    static let shared = CureTranslationBridge()
    @Published var refreshToken = UUID()

    private init() {
        NotificationCenter.default.addObserver(forName: .translationsUpdated, object: nil, queue: .main) { _ in
            self.refreshToken = UUID()
        }
    }
}

public final class CureColor: ObservableObject {
    private let key: String
    @Published public private(set) var value: Color?

    public init(_ key: String) {
        self.key = key
        self.value = Color(hex: Cure.shared.colorValue(for: key))
        
        NotificationCenter.default.addObserver(self, selector: #selector(updateValue), name: .translationsUpdated, object: nil)
    }

    @objc private func updateValue(_ notification: Notification) {
        self.value = Color(hex: Cure.shared.colorValue(for: key))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
