#if canImport(UIKit)
import UIKit
#endif
import Foundation
// NOTE: Ensure SwiftUICore is the correct import for Color. If using SwiftUI, it should be `import SwiftUI`.
// If using UIKit, you might need a different Color type or extension.
import SwiftUI // Assuming SwiftUI for Color type. Adjust if using UIKit.
import SocketIO
import CryptoKit
import Combine

public typealias Cure = CMSCureSDK

public class CMSCureSDK {
    public static let shared = CMSCureSDK()
    
    // --- Configuration & State ---
    private var projectSecret: String
    private var apiSecret: String?
    private var symmetricKey: SymmetricKey?
    private var serverUrl = "https://app.cmscure.com" // Consider making this configurable
    
    public var debugLogsEnabled: Bool = true
    public var pollingInterval: TimeInterval = 300 {
        didSet {
            // Enforce bounds for polling interval
            pollingInterval = max(60, min(pollingInterval, 600))
            // TODO: Restart timer if interval changes while running
        }
    }
    
    // --- Cache & Language ---
    private let cacheFilePath: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCure")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }()
    // The core cache: screenName -> [key: [language: value]]
    private var cache: [String: [String: [String: String]]] = [:]
    private var currentLanguage: String = "en"
    private var offlineTabList: [String] = [] // List of tabs known from last session
    
    // --- Synchronization ---
    // Serial queue to synchronize access to `cache` and `currentLanguage`
    private let cacheQueue = DispatchQueue(label: "com.cmscure.cacheQueue")
    
    // --- Networking & Updates ---
    private var socket: SocketIOClient?
    private var manager: SocketManager?
    private var pollingTimer: Timer?
    private var lastSyncCheck: Date? // To potentially avoid redundant syncs
    private var translationUpdateHandlers: [String: ([String: String]) -> Void] = [:] // Handlers for specific screen updates
    
    // --- Initialization ---
    private init() {
        self.projectSecret = "" // Initialize, should be set by authenticate
        self.apiSecret = nil
        self.symmetricKey = nil
        
        // Load initial state
        loadCacheFromDisk() // Accesses cache, happens safely before concurrency starts
        self.currentLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en"
        
        // Setup background tasks
        startListening() // Setup socket connection if config exists
        observeAppActiveNotification()
        setupPollingTimer()
    }
    
    // MARK: - Public Configuration
    
    /// Sets the API Secret used for encryption/decryption and derives the symmetric key.
    /// Should be called before making authenticated requests if not using `authenticate`.
    public func setAPISecret(_ secret: String) {
        // Synchronize access as this modifies shared crypto state
        cacheQueue.async {
            self.apiSecret = secret
            if let secretData = secret.data(using: .utf8) {
                self.symmetricKey = SymmetricKey(data: SHA256.hash(data: secretData))
                if self.debugLogsEnabled {
                    print("🔑 Symmetric key derived from API secret.")
                }
            } else {
                 if self.debugLogsEnabled {
                    print("⚠️ Failed to create data from API secret string.")
                }
            }
        }
    }
    
    /// Sets the current language, updates UserDefaults, and triggers UI/cache updates.
    /// - Parameters:
    ///   - language: The new language code (e.g., "en", "fr").
    ///   - force: If true, forces sync even if language is the same (rarely needed).
    ///   - completion: Called after all sync operations for the language change are attempted.
    public func setLanguage(_ language: String, force: Bool = false, completion: (() -> Void)? = nil) {
        // Read current language and get cache keys synchronously
        let (shouldUpdate, screensToUpdate) = cacheQueue.sync { () -> (Bool, [String]) in
            let needsUpdate = (language != self.currentLanguage || force)
            if needsUpdate {
                self.currentLanguage = language // Update language synchronously
                UserDefaults.standard.set(language, forKey: "selectedLanguage")
            }
            // Return whether update is needed and the list of screens to update
            return (needsUpdate, Array(self.cache.keys))
        }
        
        guard shouldUpdate else {
            completion?()
            return
        }
        
        if self.debugLogsEnabled {
            print("🔄 Switching to language '\(language)'")
        }
        
        let group = DispatchGroup()
        
        for screenName in screensToUpdate {
            if self.debugLogsEnabled {
                print("🔄 Updating language for tab '\(screenName)'")
            }
            
            // Immediately trigger UI update with cached data for the new language
            // Read cache synchronously
            let cachedValues = self.getCachedTranslations(for: screenName, language: language)
            DispatchQueue.main.async {
                self.notifyUpdateHandlers(screenName: screenName, values: cachedValues)
            }
            
            // Then sync in background for latest updates
            group.enter()
            self.sync(screenName: screenName) { success in
                if success {
                    // If sync succeeded, trigger another UI update with potentially newer data
                    let updatedValues = self.getCachedTranslations(for: screenName, language: language)
                    DispatchQueue.main.async {
                         self.notifyUpdateHandlers(screenName: screenName, values: updatedValues)
                    }
                }
                group.leave()
            }
        }
        
        // Notify completion when all syncs are done
        group.notify(queue: .main) {
            completion?()
        }
    }
    
    /// Gets the currently active language code.
    public func getLanguage() -> String {
        // Synchronize read access
        return cacheQueue.sync { self.currentLanguage }
    }
    
    /// Clears the in-memory and on-disk cache.
    public func clearCache() {
        // Synchronize write access
        cacheQueue.async(flags: .barrier) { // Use barrier to ensure this completes before other writes
            self.cache.removeAll()
            self.offlineTabList.removeAll()
            do {
                if FileManager.default.fileExists(atPath: self.cacheFilePath.path) {
                    try FileManager.default.removeItem(at: self.cacheFilePath)
                }
                let tabListPath = self.cacheFilePath.deletingLastPathComponent().appendingPathComponent("tabs.json")
                 if FileManager.default.fileExists(atPath: tabListPath.path) {
                    try FileManager.default.removeItem(at: tabListPath)
                }
                if self.debugLogsEnabled {
                    print("🧹 Cache cleared.")
                }
            } catch {
                 if self.debugLogsEnabled {
                    print("❌ Failed to delete cache files: \(error)")
                }
            }
            // Notify UI that cache is cleared (optional, might require specific handling)
            // Consider posting a specific notification if needed
        }
    }
    
    // MARK: - Core Translation & Color Access
    
    /// Retrieves the translation for a given key and screen name in the current language.
    /// Returns an empty string if the key, screen, or language translation is not found.
    public func translation(for key: String, inTab screenName: String) -> String {
        // Synchronize read access to cache and currentLanguage
        return cacheQueue.sync {
            let lang = self.currentLanguage // Read language inside sync block
            if self.debugLogsEnabled {
                // Limit frequency of logs if needed, this can be noisy
                // print("🔍 Reading '\(key)' from '\(screenName)' in '\(lang)'")
            }
            
            guard let tabCache = cache[screenName] else {
                if self.debugLogsEnabled {
                    print("⚠️ Screen '\(screenName)' not present in cache for key '\(key)'")
                }
                return ""
            }
            
            guard let keyMap = tabCache[key] else {
                 if self.debugLogsEnabled {
                    print("⚠️ Key '\(key)' not found in tab '\(screenName)'")
                }
                return ""
            }
            
            guard let translation = keyMap[lang] else {
                if self.debugLogsEnabled {
                    print("⚠️ No translation found for key '\(key)' in language '\(lang)' (Tab: \(screenName))")
                }
                // Optionally fallback to a default language like "en"
                // return keyMap["en"] ?? ""
                return ""
            }
            
            return translation
        }
    }
    
    /// Retrieves the color hex string for a given global color key.
    /// Looks for the key within the special `__colors__` tab.
    public func colorValue(for key: String) -> String? {
        // Synchronize read access
        return cacheQueue.sync {
            if self.debugLogsEnabled {
                // print("🎨 Reading global color value for key '\(key)'")
            }
            
            // Access cache safely within the sync block
            guard let colorTab = cache["__colors__"] else {
                if self.debugLogsEnabled {
                    print("⚠️ Global color tab '__colors__' not found in cache for key '\(key)'")
                }
                return nil
            }
            
            guard let valueMap = colorTab[key] else {
                if self.debugLogsEnabled {
                    print("⚠️ Color key '\(key)' not found in global tab '__colors__'")
                }
                return nil
            }
            
            // Assuming color value is stored under the key "color" within the valueMap
            guard let colorHex = valueMap["color"] else {
                 if self.debugLogsEnabled {
                    print("⚠️ 'color' field not found for key '\(key)' in '__colors__'")
                }
                return nil
            }
            
            return colorHex
        }
    }
    
    /// Retrieves all cached translations for a specific screen and language.
    /// Used internally for notifying handlers.
    private func getCachedTranslations(for screenName: String, language: String) -> [String: String] {
        // Synchronize read access
        return cacheQueue.sync {
            var values: [String: String] = [:]
            if let tabCache = self.cache[screenName] {
                for (key, valueMap) in tabCache {
                    if let translatedValue = valueMap[language] {
                        values[key] = translatedValue
                    }
                }
            }
            return values
        }
    }
    
    // MARK: - Synchronization Logic
    
    /// Fetches the latest translations for a specific screen name from the server.
    /// Updates the cache and notifies relevant handlers upon success.
    public func sync(screenName: String, completion: @escaping (Bool) -> Void) {
        // Read config synchronously before going async
        guard let token = readTokenFromConfig(), let projectId = readProjectIdFromConfig() else {
            if self.debugLogsEnabled {
                print("❌ Sync failed for '\(screenName)': Missing auth token or project ID")
            }
            completion(false)
            return
        }
        
        // Construct URL - Ensure serverUrl is correct
        guard let socketUrl = URL(string: "wss://app.cmscure.com") else { // Use serverUrl directly
            if self.debugLogsEnabled { print("❌ Invalid socket URL: \(serverUrl)") }
            return
        }
        
        // Ensure manager and socket are created if nil
        if manager == nil || socket == nil {
            manager = SocketManager(socketURL: socketUrl, config: [.log(debugLogsEnabled), .compress, .reconnects(true), .reconnectAttempts(-1), .reconnectWait(3), .reconnectWaitMax(10)]) // Pass the correct socketURL
            socket = manager?.defaultSocket
            setupSocketHandlers(projectId: projectId) // Setup handlers only once
        }

        if self.debugLogsEnabled {
            print("🔌 Attempting to connect socket to \(socketUrl)...") // Log the correct URL
        }
        socket?.connect()
        
        let apiBaseUrl = "https://app.cmscure.com" // Use HTTPS for API calls
        guard let url = URL(string: "\(apiBaseUrl)/api/sdk/translations/\(projectId)/\(screenName)") else {
            if self.debugLogsEnabled {
               print("❌ Sync failed for '\(screenName)': Invalid URL components.")
            }
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15 // Add a timeout
        
        // Prepare body and signature (read symmetricKey synchronously)
        let (encryptedBody, signature) = cacheQueue.sync { () -> (Data?, String?) in
            let bodyDict = ["projectId": projectId, "screenName": screenName]
            let encrypted = self.encryptBody(bodyDict)
            var sig: String? = nil
            if let bodyData = encrypted, let key = self.symmetricKey {
                let hmac = HMAC<SHA256>.authenticationCode(for: bodyData, using: key)
                sig = Data(hmac).base64EncodedString()
            }
            return (encrypted, sig)
        }
        
        guard let finalEncryptedBody = encryptedBody else {
            if self.debugLogsEnabled {
                print("❌ Sync failed for '\(screenName)': Failed to encrypt request body.")
            }
            completion(false)
            return
        }
        
        request.httpBody = finalEncryptedBody
        if let finalSignature = signature {
            request.setValue(finalSignature, forHTTPHeaderField: "X-Signature")
        } else if self.debugLogsEnabled {
             print("⚠️ Sync warning for '\(screenName)': Could not generate signature (symmetric key missing?).")
        }
        
        // Perform network request
        URLSession.shared.dataTask(with: request) { data, response, error in
            // Check for network errors
            if let error = error {
                if self.debugLogsEnabled {
                    print("❌ Sync failed for '\(screenName)': Network error - \(error.localizedDescription)")
                }
                completion(false)
                return
            }
            
            // Check HTTP status code
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                if self.debugLogsEnabled {
                    print("❌ Sync failed for '\(screenName)': HTTP status code \(statusCode)")
                    if let data = data, let responseBody = String(data: data, encoding: .utf8) {
                        print("   Response Body: \(responseBody)")
                    }
                }
                completion(false)
                return
            }
            
            // Check for valid data
            guard let data = data else {
                if self.debugLogsEnabled {
                    print("❌ Sync failed for '\(screenName)': No data received.")
                }
                completion(false)
                return
            }
            
            // Parse JSON response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let keys = json["keys"] as? [[String: Any]] else {
                if self.debugLogsEnabled {
                    print("❌ Sync failed for '\(screenName)': Failed to parse JSON response.")
                    print("   Raw response:", String(data: data, encoding: .utf8) ?? "nil")
                }
                completion(false)
                return
            }
            
            // --- Update Cache Synchronously ---
            self.cacheQueue.async(flags: .barrier) { // Use barrier for safety if queue becomes concurrent
                var updatedTabValuesForCurrentLang: [String: String] = [:]
                var newCacheForScreen: [String: [String: String]] = [:]
                let currentLang = self.currentLanguage // Read language inside sync block
                
                for item in keys {
                    if let k = item["key"] as? String,
                       let values = item["values"] as? [String: String] {
                        
                        newCacheForScreen[k] = values // Store all language values for the key
                        
                        if let v = values[currentLang] {
                            updatedTabValuesForCurrentLang[k] = v // Store value for current language
                        }
                        
                        if self.debugLogsEnabled {
                           // print("📝 Updated cache[\(screenName)][\(k)] = \(values)") // Log all languages if needed
                        }
                    }
                }
                
                // Replace the entire entry for the screenName
                self.cache[screenName] = newCacheForScreen
                
                // Add screen name to offline list
                 if !self.offlineTabList.contains(screenName) {
                     self.offlineTabList.append(screenName)
                 }

                // Save updated cache and tab list to disk
                self.saveCacheToDisk() // Call within the queue after modification
                self.saveOfflineTabListToDisk() // Save updated tabs list

                // --- Dispatch UI Updates to Main Thread ---
                DispatchQueue.main.async {
                    // Notify specific handler for this screen
                    self.translationUpdateHandlers[screenName]?(updatedTabValuesForCurrentLang)
                    
                    // Post general notification for SwiftUI views or other listeners
                    self.postTranslationsUpdatedNotification(screenName: screenName)
                    
                    if self.debugLogsEnabled {
                        print("✅ Synced translations for \(screenName)") // Log count: \(updatedTabValuesForCurrentLang.count) keys")
                    }
                    completion(true) // Call completion *after* potential UI updates are dispatched
                }
            } // End cacheQueue.async
            
        }.resume()
    }
    
    /// Checks if the content is outdated based on `lastSyncCheck` and triggers sync if needed.
    private func syncIfOutdated() {
        // Add logic here if needed to check lastSyncCheck against pollingInterval
        // For now, it syncs all known tabs unconditionally when called.
        
        // Get list of tabs to sync (combine cached and offline lists)
        let tabsToSync = cacheQueue.sync {
             Array(Set(self.cache.keys).union(Set(self.offlineTabList))).filter { !$0.starts(with: "__") } // Exclude special tabs like __colors__ initially
        }
        let specialTabs = ["__colors__", "__images__"] // Sync special tabs always or based on separate logic
        
        if debugLogsEnabled {
             print("🔄 Syncing tabs: \(tabsToSync.joined(separator: ", ")), \(specialTabs.joined(separator: ", "))")
        }
        
        for tab in tabsToSync + specialTabs {
            self.sync(screenName: tab) { success in
                // Completion is handled within sync now (posts notification)
                if !success && self.debugLogsEnabled {
                     print("⚠️ Failed to sync tab '\(tab)' during periodic/app-active sync.")
                }
            }
        }
    }
    
    // MARK: - Socket Communication
    
    /// Establishes connection with the Socket.IO server.
    public func connectSocket(apiKey: String, projectId: String) {
        // Check existing status safely
        guard socket?.status != .connected && socket?.status != .connecting else {
            if self.debugLogsEnabled {
                print("⚠️ Socket already connected or connecting — skipping reinitialization.")
            }
            return
        }
        
        guard let url = URL(string: serverUrl) else {
             if self.debugLogsEnabled { print("❌ Invalid socket URL.") }
             return
        }
        
        // Ensure manager and socket are created if nil
        if manager == nil || socket == nil {
             manager = SocketManager(socketURL: url, config: [.log(debugLogsEnabled), .compress, .reconnects(true), .reconnectAttempts(-1), .reconnectWait(3), .reconnectWaitMax(10)])
             socket = manager?.defaultSocket
             setupSocketHandlers(projectId: projectId) // Setup handlers only once
        }

        if self.debugLogsEnabled {
            print("🔌 Attempting to connect socket...")
        }
        socket?.connect()
    }
    
    /// Sets up the event handlers for the Socket.IO client.
    private func setupSocketHandlers(projectId: String) {
        socket?.on(clientEvent: .connect) { [weak self] data, ack in
            guard let self = self else { return }
            if self.debugLogsEnabled {
                print("🟢 Socket connected")
            }
            // Send handshake immediately after connection
            self.sendHandshake(projectId: projectId)
        }
        
        socket?.on("handshake_ack") { [weak self] data, ack in
             guard let self = self else { return }
            if self.debugLogsEnabled {
                print("🤝 Handshake acknowledged by server.")
            }
            // Sync content after successful handshake
            self.syncIfOutdated()
        }
        
        socket?.on("translationsUpdated") { [weak self] data, ack in
             guard let self = self else { return }
            if self.debugLogsEnabled {
                 print("📡 Socket update received: \(data)")
            }
            self.handleSocketTranslationUpdate(data: data)
        }
        
        socket?.on(clientEvent: .disconnect) { [weak self] data, ack in
             guard let self = self else { return }
            if self.debugLogsEnabled {
                print("🔌 Socket disconnected. Reason: \(data)")
            }
        }
        
        socket?.on(clientEvent: .error) { [weak self] data, _ in
             guard let self = self else { return }
            if self.debugLogsEnabled {
                // Data often contains an Error object
                 if let error = data.first as? Error {
                     print("❌ Socket error: \(error.localizedDescription)")
                 } else {
                     print("❌ Socket error: \(data)")
                 }
            }
        }
        
        socket?.on(clientEvent: .reconnect) { [weak self] data, _ in
             guard let self = self else { return }
             if self.debugLogsEnabled { print("🔁 Socket reconnected.") }
             // Re-send handshake on successful reconnect
             self.sendHandshake(projectId: projectId)
        }
        
        socket?.on(clientEvent: .reconnectAttempt) { [weak self] data, _ in
             guard let self = self else { return }
             // Data usually contains reconnect attempt number and delay
             if self.debugLogsEnabled { print("🔁 Attempting socket reconnect... \(data)") }
        }
        
        // Handle status changes if needed
        socket?.on(clientEvent: .statusChange) { [weak self] data, _ in
             guard let self = self else { return }
             if self.debugLogsEnabled { print("ℹ️ Socket status changed: \(self.socket?.status.description ?? "Unknown")") }
        }
    }

    /// Sends the encrypted handshake message to the server.
    private func sendHandshake(projectId: String) {
         // Encrypt body synchronously
         let encryptedPayload = cacheQueue.sync {
             let body = ["projectId": projectId]
             return self.encryptBody(body)
         }

         guard let encryptedData = encryptedPayload,
               var sealed = try? JSONSerialization.jsonObject(with: encryptedData, options: []) as? [String: Any] else {
             if self.debugLogsEnabled { print("❌ Failed to encrypt handshake payload, sending plain.") }
             // Fallback to sending plain projectId if encryption fails
             self.socket?.emit("handshake", ["projectId": projectId])
             return
         }

         // Add projectId plain text alongside encrypted data if required by backend
         sealed["projectId"] = projectId
         if self.debugLogsEnabled { print("🤝 Sending handshake: \(sealed)") }
         self.socket?.emit("handshake", sealed)

         // Optional: Add a timeout for handshake acknowledgement
         // ...
    }
    
    /// Handles incoming translation update messages from the socket.
    private func handleSocketTranslationUpdate(data: [Any]) {
        guard let dict = data.first as? [String: Any],
              let screenName = dict["screenName"] as? String else {
            if self.debugLogsEnabled {
                print("⚠️ Invalid socket data format received: \(data)")
            }
            return
        }
        
        if self.debugLogsEnabled {
            print("📡 Processing socket update for tab: \(screenName)")
        }
        
        // If update is for all screens, trigger sync for all known tabs
        if screenName == "__ALL__" {
            if self.debugLogsEnabled { print("🔄 Socket requested sync for __ALL__ tabs.") }
            self.syncIfOutdated() // Sync all relevant tabs
            return
        }
        
        // Otherwise, sync the specific screen mentioned
        self.sync(screenName: screenName) { success in
            // Completion/notification is handled within sync now
            if !success && self.debugLogsEnabled {
                print("❌ Failed to refresh tab '\(screenName)' after socket update signal.")
            }
        }
    }
    
    /// Attempts to start the socket connection using saved config.
    public func startListening() {
        // Read config synchronously
        guard let config = readConfig(),
              let projectId = config["projectId"],
              let token = config["authToken"], // Token might not be needed for connect, but good to check
              let secret = config["projectSecret"]
        else {
            if self.debugLogsEnabled {
                print("ℹ️ No saved config found or config incomplete. Socket connection deferred until authentication.")
            }
            return
        }
        
        // Ensure secret is set for potential handshake encryption
        setAPISecret(secret)
        
        // Connect socket using loaded projectId
        connectSocket(apiKey: "", projectId: projectId) // apiKey might not be needed here if already authenticated
    }
    
    /// Disconnects the socket.
    public func stopListening() {
        socket?.disconnect()
        // Don't nil out manager/socket immediately if using auto-reconnect
        if self.debugLogsEnabled {
            print("🔌 Socket disconnect requested.")
        }
    }
    
    /// Checks if the socket is currently connected.
    public func isConnected() -> Bool {
        return socket?.status == .connected
    }
    
    // MARK: - Authentication
    
    /// Authenticates the SDK with the backend using API keys.
    /// Saves configuration on success and initiates socket connection.
    public func authenticate(apiKey: String, projectId: String, projectSecret: String, completion: @escaping (Bool) -> Void) {
        
        // Set the secret immediately for encryption
        setAPISecret(projectSecret)
        
        guard let url = URL(string: "\(serverUrl)/api/sdk/auth?projectId=\(projectId)") else {
             if self.debugLogsEnabled { print("❌ Auth failed: Invalid URL.") }
             completion(false)
             return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15 // Add timeout
        
        // Prepare body and signature (reads symmetricKey synchronously)
        let (encryptedBody, signature) = cacheQueue.sync { () -> (Data?, String?) in
            let bodyDict = ["apiKey": apiKey, "projectId": projectId, "projectSecret": projectSecret] // Include secret if backend expects it
            let encrypted = self.encryptBody(bodyDict)
            var sig: String? = nil
            if let bodyData = encrypted, let key = self.symmetricKey {
                let hmac = HMAC<SHA256>.authenticationCode(for: bodyData, using: key)
                sig = Data(hmac).base64EncodedString()
            }
             if self.debugLogsEnabled {
                 print("🛡️ Auth Body Payload (Plain):", bodyDict)
                 if let encoded = encrypted {
                     print("📦 Encoded Auth Body:", String(data: encoded, encoding: .utf8) ?? "invalid")
                 } else {
                     print("❌ Failed to encode auth body")
                 }
             }
            return (encrypted, sig)
        }
        
        guard let finalEncryptedBody = encryptedBody else {
            if self.debugLogsEnabled {
                print("❌ Auth failed: Encryption returned nil.")
            }
            completion(false)
            return
        }
        
        request.httpBody = finalEncryptedBody
        if let finalSignature = signature {
            request.setValue(finalSignature, forHTTPHeaderField: "X-Signature")
        } else if self.debugLogsEnabled {
             print("⚠️ Auth warning: Could not generate signature (symmetric key missing?).")
        }
        
        // Perform network request
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                if self.debugLogsEnabled { print("❌ Auth failed: Network error - \(error.localizedDescription)") }
                completion(false)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                if self.debugLogsEnabled {
                    print("❌ Auth failed: HTTP status code \(statusCode)")
                     if let data = data, let responseBody = String(data: data, encoding: .utf8) {
                        print("   Response Body: \(responseBody)")
                    }
                }
                completion(false)
                return
            }
            
            guard let data = data,
                  let result = try? JSONDecoder().decode(AuthResult.self, from: data),
                  let token = result.token else {
                if self.debugLogsEnabled {
                    print("❌ Auth failed: Decoding failed or token missing.")
                    print("   Raw response:", String(data: data ?? Data(), encoding: .utf8) ?? "nil")
                }
                completion(false)
                return
            }
            
            // Authentication successful, save config
            let config: [String: String] = [
                "projectId": projectId,
                "authToken": token,
                "projectSecret": projectSecret // Save secret to derive key later
            ]
            
            if self.saveConfig(config) {
                if self.debugLogsEnabled {
                    print("✅ Authenticated successfully.")
                }
                // Update internal state and connect socket
                self.cacheQueue.async { self.projectSecret = projectSecret } // Update internal secret
                self.connectSocket(apiKey: apiKey, projectId: projectId)
                completion(true)
            } else {
                // Failed to save config
                completion(false)
            }
        }.resume()
    }
    
    /// Retrieves the image URL string for a given key and screen name in the current language.
    /// Returns nil if the key, screen, or language value is not found or not a valid URL string.
    public func imageUrl(for key: String, inTab screenName: String) -> URL? {
        // Use the existing thread-safe translation method to get the URL string
        let urlString = self.translation(for: key, inTab: screenName) // Re-use translation logic

        guard !urlString.isEmpty else {
            if self.debugLogsEnabled {
                print("⚠️ Image URL string not found for key '\(key)' in tab '\(screenName)' (Lang: \(getLanguage()))")
            }
            return nil
        }

        guard let url = URL(string: urlString) else {
             if self.debugLogsEnabled {
                print("❌ Invalid URL format for key '\(key)' in tab '\(screenName)': \(urlString)")
            }
            return nil
        }
        
        if self.debugLogsEnabled {
            // print("🖼️ Resolved image URL for '\(key)'/\(screenName)': \(url)") // Can be noisy
        }
        return url
    }
    
    // MARK: - Update Handling & Notifications
    
    /// Registers a handler to be called when translations for a specific screen are updated.
    public func onTranslationsUpdated(for screenName: String, handler: @escaping ([String: String]) -> Void) {
        // No direct cache access, safe to call from any thread.
        // The handler itself will be called on the main thread from sync/setLanguage.
        self.translationUpdateHandlers[screenName] = handler
        
        // Immediately provide current cached values if available
        let currentValues = self.getCachedTranslations(for: screenName, language: self.getLanguage())
        if !currentValues.isEmpty {
             DispatchQueue.main.async {
                 handler(currentValues)
             }
        }
    }
    
    /// Posts the .translationsUpdated notification and updates the bridge.
    private func postTranslationsUpdatedNotification(screenName: String) {
        // Ensure this is called on the main thread as it triggers UI updates
        assert(Thread.isMainThread, "Must be called on the main thread")
        
        CureTranslationBridge.shared.refreshToken = UUID() // Update bridge for SwiftUI views
        NotificationCenter.default.post(name: .translationsUpdated, object: nil, userInfo: [
            "screenName": screenName
        ])
        if debugLogsEnabled {
             // print("📬 Posted .translationsUpdated notification for '\(screenName)'")
        }
    }

    /// Calls the registered update handlers for a given screen name.
    private func notifyUpdateHandlers(screenName: String, values: [String: String]) {
         // Ensure this is called on the main thread
         assert(Thread.isMainThread, "Must be called on the main thread")
         self.translationUpdateHandlers[screenName]?(values)
         self.postTranslationsUpdatedNotification(screenName: screenName) // Also post general notification
    }
    
    // MARK: - Persistence (Cache & Config)
    
    /// Saves the current in-memory cache to disk. MUST be called from within `cacheQueue`.
    private func saveCacheToDisk() {
        // This method assumes it's already running within cacheQueue.sync or cacheQueue.async
        do {
            // Cache is already accessed synchronously, no need to sanitize here again if writes are safe
            let data = try JSONEncoder().encode(self.cache) // Use JSONEncoder for Codable types if possible
            // let data = try JSONSerialization.data(withJSONObject: self.cache, options: []) // Use if not Codable
            try data.write(to: self.cacheFilePath, options: .atomic)
            if self.debugLogsEnabled {
                // print("💾 Saved cache to disk.")
            }
        } catch {
            if self.debugLogsEnabled {
                print("❌ Failed to save cache: \(error)")
            }
        }
    }
    
    /// Loads the cache from disk during initialization.
    private func loadCacheFromDisk() {
        // This runs at init time, before concurrent access starts, so direct access is safe here.
        guard FileManager.default.fileExists(atPath: self.cacheFilePath.path) else {
            if self.debugLogsEnabled {
                print("ℹ️ No cache file found at startup.")
            }
            return
        }
        
        do {
            let data = try Data(contentsOf: self.cacheFilePath)
            // Use JSONDecoder if cache structure is simple enough or conforms to Codable
            if let loadedCache = try? JSONDecoder().decode([String: [String: [String: String]]].self, from: data) {
                 self.cache = loadedCache
                 if self.debugLogsEnabled {
                     print("📦 Loaded cache from disk with tabs: \(self.cache.keys.joined(separator: ", "))")
                 }
            } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: [String: String]]] {
                // Fallback to JSONSerialization if Decoder fails or not applicable
                self.cache = json
                if self.debugLogsEnabled {
                    print("📦 Loaded cache via JSONSerialization with tabs: \(self.cache.keys.joined(separator: ", "))")
                }
            } else {
                 if self.debugLogsEnabled { print("⚠️ Failed to decode cache data from disk.") }
                 // Consider deleting the corrupted cache file
                 try? FileManager.default.removeItem(at: self.cacheFilePath)
                 return
            }

            // Load offline tab list
            loadOfflineTabListFromDisk() // Load the list of known tabs

            // Initial UI update after loading cache (do this after setting up listeners if needed)
            // This might be too early if called from init before UI is ready.
            // Consider triggering initial updates after authentication or first sync.
            /*
             DispatchQueue.main.async {
                 for tab in self.cache.keys {
                     self.postTranslationsUpdatedNotification(screenName: tab)
                 }
             }
             */
            
        } catch {
            if self.debugLogsEnabled {
                print("❌ Failed to load cache from disk: \(error)")
            }
             // Attempt to delete corrupted cache file
             try? FileManager.default.removeItem(at: self.cacheFilePath)
        }
    }

     /// Saves the list of known tabs (including offline ones) to disk. MUST be called from within `cacheQueue`.
     private func saveOfflineTabListToDisk() {
         // Assumes running within cacheQueue
         let tabListPath = self.cacheFilePath.deletingLastPathComponent().appendingPathComponent("tabs.json")
         do {
             let data = try JSONEncoder().encode(self.offlineTabList)
             try data.write(to: tabListPath, options: .atomic)
             if debugLogsEnabled {
                 // print("💾 Saved offline tab list: \(self.offlineTabList)")
             }
         } catch {
             if debugLogsEnabled {
                 print("❌ Failed to save offline tab list: \(error)")
             }
         }
     }

     /// Loads the list of known tabs from disk. Called during init.
     private func loadOfflineTabListFromDisk() {
         // Safe to call during init
         let tabListPath = self.cacheFilePath.deletingLastPathComponent().appendingPathComponent("tabs.json")
         guard FileManager.default.fileExists(atPath: tabListPath.path) else { return }

         do {
             let data = try Data(contentsOf: tabListPath)
             self.offlineTabList = try JSONDecoder().decode([String].self, from: data)
             if debugLogsEnabled {
                 print("📦 Loaded offline tab list: \(self.offlineTabList)")
             }
         } catch {
             if debugLogsEnabled {
                 print("❌ Failed to load offline tab list: \(error)")
             }
             try? FileManager.default.removeItem(at: tabListPath) // Remove corrupted file
         }
     }
    
    /// Saves the authentication configuration to disk.
    private func saveConfig(_ config: [String: String]) -> Bool {
        // File operations are generally safe but can block, consider background if needed
        do {
            let configDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true, attributes: nil)
            let configFilePath = configDir.appendingPathComponent("config.json")
            let jsonData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
            try jsonData.write(to: configFilePath, options: .atomic)
            if self.debugLogsEnabled {
                print("💾 Saved config to \(configFilePath.path)")
            }
            return true
        } catch {
            if self.debugLogsEnabled {
                print("❌ Failed to save config: \(error)")
            }
            return false
        }
    }
    
    /// Reads the authentication configuration from disk.
    private func readConfig() -> [String: String]? {
        let configDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
        let configFilePath = configDir.appendingPathComponent("config.json")
        
        guard FileManager.default.fileExists(atPath: configFilePath.path),
              let data = try? Data(contentsOf: configFilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return json
    }
    
    /// Reads the auth token from the saved config file.
    private func readTokenFromConfig() -> String? {
        return readConfig()?["authToken"]
    }
    
    /// Reads the project ID from the saved config file.
    private func readProjectIdFromConfig() -> String? {
        return readConfig()?["projectId"]
    }
    
    /// Reads the project secret from the saved config file.
    private func readProjectSecretFromConfig() -> String? {
        return readConfig()?["projectSecret"]
    }
    
    // MARK: - Background Handling & Polling
    
    /// Sets up observers for app lifecycle events and polling timer.
    private func observeAppActiveNotification() {
#if canImport(UIKit) && !os(watchOS) // Ensure UIKit is available and not watchOS
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
#endif
        // Add equivalent observers for AppKit (macOS) or other platforms if needed
    }
    
    @objc private func appDidBecomeActive() {
        if self.debugLogsEnabled {
            print("📲 App became active — checking for outdated content & socket status.")
        }
        // Ensure socket is connected or attempts to connect
        startListening() // This will attempt connection if config exists and not connected
        // Trigger sync
        syncIfOutdated()
    }
    
    private func setupPollingTimer() {
        // Invalidate existing timer first
        pollingTimer?.invalidate()
        // Schedule new timer
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.debugLogsEnabled {
                print("⏰ Polling timer fired — syncing content.")
            }
            // Perform sync
            self.syncIfOutdated()
        }
         if debugLogsEnabled {
             print("⏱️ Polling timer setup with interval: \(pollingInterval) seconds.")
         }
    }
    
    // MARK: - Encryption Helper
    
    /// Encrypts the request body using AES.GCM with the derived symmetric key.
    /// MUST be called from within `cacheQueue` to safely access `symmetricKey`.
    private func encryptBody(_ body: [String: Any]) -> Data? {
        // Assumes running within cacheQueue
        guard let symmetricKey = self.symmetricKey else {
             if debugLogsEnabled { print("❌ Encryption failed: Symmetric key not set.") }
             return nil
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
             if debugLogsEnabled { print("❌ Encryption failed: Could not serialize body to JSON.") }
             return nil
        }
        
        do {
            let sealedBox = try AES.GCM.seal(jsonData, using: symmetricKey)
            let result: [String: String] = [
                "iv": sealedBox.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
                "ciphertext": sealedBox.ciphertext.base64EncodedString(),
                "tag": sealedBox.tag.base64EncodedString()
            ]
            return try JSONSerialization.data(withJSONObject: result)
        } catch {
            if debugLogsEnabled { print("❌ Encryption failed: AES.GCM sealing error - \(error)") }
            return nil
        }
    }
    
    // MARK: - Deprecated / Utility (Keep if needed)
    
    /// Checks if a specific tab has any data in the cache.
    public func isTabSynced(_ tab: String) -> Bool {
        // Synchronize read access
        return cacheQueue.sync { !(cache[tab]?.isEmpty ?? true) }
    }
    
    /// Fetches the list of available languages from the server.
    public func availableLanguages(completion: @escaping ([String]) -> Void) {
        // Read config synchronously
        guard let projectId = readProjectIdFromConfig() else {
            if self.debugLogsEnabled { print("❌ Fetch languages failed: Missing project ID") }
            completion([])
            return
        }
        
        guard let url = URL(string: "\(serverUrl)/api/sdk/languages/\(projectId)") else {
             if self.debugLogsEnabled { print("❌ Fetch languages failed: Invalid URL.")}
             completion([])
             return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST" // Should this be GET? Check API design. Assuming POST for consistency.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        
        // Prepare body and signature (read symmetricKey synchronously)
        let (encryptedBody, signature) = cacheQueue.sync { () -> (Data?, String?) in
            let bodyDict = ["projectId": projectId]
            let encrypted = self.encryptBody(bodyDict)
            var sig: String? = nil
            if let bodyData = encrypted, let key = self.symmetricKey {
                let hmac = HMAC<SHA256>.authenticationCode(for: bodyData, using: key)
                sig = Data(hmac).base64EncodedString()
            }
            return (encrypted, sig)
        }
        
        // Continue only if encryption succeeded (or is not required by backend)
        request.httpBody = encryptedBody
        if let finalSignature = signature {
            request.setValue(finalSignature, forHTTPHeaderField: "X-Signature")
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                if self.debugLogsEnabled { print("❌ Fetch languages failed: Network error - \(error.localizedDescription)") }
                self.fallbackToCachedLanguages(completion: completion)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                 if self.debugLogsEnabled { print("❌ Fetch languages failed: HTTP status \(statusCode)") }
                 self.fallbackToCachedLanguages(completion: completion)
                 return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let languages = json["languages"] as? [String] else {
                if self.debugLogsEnabled { print("❌ Fetch languages failed: Invalid JSON response.") }
                self.fallbackToCachedLanguages(completion: completion)
                return
            }
            
            if self.debugLogsEnabled {
                print("🌐 Available languages from server: \(languages)")
            }
            DispatchQueue.main.async { completion(languages) }
            
        }.resume()
    }
    
    /// Provides cached languages as a fallback if fetching from server fails.
    private func fallbackToCachedLanguages(completion: @escaping ([String]) -> Void) {
        // Synchronize read access
        let cachedLangs = cacheQueue.sync { () -> [String] in
            var allLangs: Set<String> = []
            // Iterate safely within the sync block
            for (_, tabValues) in self.cache {
                for (_, langMap) in tabValues {
                    allLangs.formUnion(langMap.keys)
                }
            }
             // Don't include "color" if it sneakily appears as a language key in __colors__
             allLangs.remove("color")
            return Array(allLangs).sorted() // Sort for consistency
        }
        
        DispatchQueue.main.async {
            if !cachedLangs.isEmpty {
                if self.debugLogsEnabled {
                    print("⚠️ Using cached languages as fallback: \(cachedLangs)")
                }
                completion(cachedLangs)
            } else {
                completion([]) // No cached languages either
            }
        }
    }
    
    /// Helper struct for decoding authentication result.
    private struct AuthResult: Decodable {
        let token: String?
        // let projectSecret: String? // Secret usually isn't returned, it's provided by user
    }
    
    /// Prints an encrypted payload for testing purposes (e.g., Postman).
    public func printEncryptedPayloadForTesting(apiKey: String, projectId: String) {
        // Read key synchronously
        let encryptedData = cacheQueue.sync {
             let payload = ["apiKey": apiKey, "projectId": projectId]
             return self.encryptBody(payload)
        }
        
        guard let data = encryptedData,
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: String],
              let iv = json["iv"], let ct = json["ciphertext"], let tag = json["tag"] else {
            print("❌ Failed to generate encrypted test payload.")
            return
        }
        
        print("""
        🔐 Encrypted Payload for Postman (use as raw JSON Body):
        {
          "iv": "\(iv)",
          "ciphertext": "\(ct)",
          "tag": "\(tag)"
        }
        """)
    }
    
    deinit {
        // Clean up observers and timers
        NotificationCenter.default.removeObserver(self)
        pollingTimer?.invalidate()
        stopListening() // Disconnect socket
    }
}

// MARK: - SwiftUI Color Extension (Keep as is)

extension Color {
    /// Initializes a SwiftUI Color from a hex string (e.g., "#RRGGBB" or "RRGGBB").
    init?(hex: String?) {
        guard var hexSanitized = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        guard hexSanitized.count == 6 else { return nil } // Ensure 6 hex digits
        
        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}

// MARK: - Notification Name (Keep as is)

extension Notification.Name {
    /// Notification posted when translations or colors are updated.
    /// The `userInfo` dictionary contains `["screenName": String]`.
    public static let translationsUpdated = Notification.Name("CMSCureTranslationsUpdated") // Make name more specific
}

// MARK: - Error Enum (Keep as is)

enum CMSCureSDKError: Error {
    case missingTokenOrProjectId
    case invalidResponse
    case decodingFailed
    case syncFailed(String) // Include screen name
    case socketDisconnected
    case encryptionFailed
    case configurationError(String)
}

// MARK: - String Extension for Convenience (Keep as is)

extension String {
    // Helper to trigger refresh in SwiftUI views observing the bridge
    private var bridgeWatcher: UUID {
        CureTranslationBridge.shared.refreshToken
    }
    
    /// Convenience method to get a translation using the shared CMSCureSDK instance.
    /// Example: `"my_label_key".cure(tab: "HomeScreen")`
    public func cure(tab: String) -> String {
        _ = bridgeWatcher // Reads the publisher to ensure view updates
        // Calls the thread-safe translation method
        return Cure.shared.translation(for: self, inTab: tab)
    }
}

// MARK: - Observable Objects for SwiftUI (Keep as is, they call thread-safe SDK methods)

/// Observable object to automatically update a String value in SwiftUI views.
public final class CureString: ObservableObject {
    private let key: String
    private let tab: String
    private var cancellable: AnyCancellable? = nil
    
    @Published public private(set) var value: String = ""
    
    public init(_ key: String, tab: String) {
        self.key = key
        self.tab = tab
        // Initial value fetch is now thread-safe
        self.value = Cure.shared.translation(for: key, inTab: tab)
        
        // Observe the bridge's refreshToken publisher
        cancellable = CureTranslationBridge.shared.$refreshToken
            .receive(on: DispatchQueue.main) // Ensure updates happen on main thread
            .sink { [weak self] _ in
                self?.updateValue()
            }
    }
    
    private func updateValue() {
        // Fetching the value is thread-safe
        let newValue = Cure.shared.translation(for: key, inTab: tab)
        // Update @Published property only if value changed
        if newValue != self.value {
            self.value = newValue
        }
    }
    
    // No need for NotificationCenter observation if using the bridge publisher
    // deinit { NotificationCenter.default.removeObserver(self) }
}

/// Shared bridge object whose `refreshToken` changes trigger updates in CureString/CureColor.
final class CureTranslationBridge: ObservableObject {
    static let shared = CureTranslationBridge()
    @Published var refreshToken = UUID()
    
    private init() {
        // No need for NotificationCenter observation here if postTranslationsUpdatedNotification updates refreshToken
    }
}

/// Observable object to automatically update a Color value in SwiftUI views.
public final class CureColor: ObservableObject {
    private let key: String
    private var cancellable: AnyCancellable? = nil
    
    @Published public private(set) var value: Color? // Use SwiftUI Color
    
    public init(_ key: String) {
        self.key = key
        // Initial value fetch is thread-safe
        self.value = Color(hex: Cure.shared.colorValue(for: key))
        
        // Observe the bridge's refreshToken publisher
        cancellable = CureTranslationBridge.shared.$refreshToken
            .receive(on: DispatchQueue.main) // Ensure updates happen on main thread
            .sink { [weak self] _ in
                self?.updateValue()
            }
    }
    
    private func updateValue() {
        // Fetching the value is thread-safe
        let newValue = Color(hex: Cure.shared.colorValue(for: key))
        // Update @Published property only if value changed
        if newValue != self.value {
             self.value = newValue
        }
    }
    
    // No need for NotificationCenter observation if using the bridge publisher
    // deinit { NotificationCenter.default.removeObserver(self) }
}

/// Observable object to automatically update a URL value (intended for images) in SwiftUI views.
public final class CureImage: ObservableObject {
    private let key: String
    private let tab: String
    private var cancellable: AnyCancellable? = nil

    @Published public private(set) var value: URL? // Stores the URL for the image

    public init(_ key: String, tab: String) {
        self.key = key
        self.tab = tab
        // Initial value fetch (implement imageUrl function in SDK)
        self.value = Cure.shared.imageUrl(for: key, inTab: tab) // <- New SDK function needed

        // Observe the bridge's refreshToken publisher for updates
        cancellable = CureTranslationBridge.shared.$refreshToken
            .receive(on: DispatchQueue.main) // Ensure updates happen on main thread
            .sink { [weak self] _ in
                self?.updateValue()
            }
    }

    private func updateValue() {
        // Fetching the value is thread-safe (assuming imageUrl is)
        let newValue = Cure.shared.imageUrl(for: key, inTab: tab) // <- New SDK function needed
        // Update @Published property only if value changed
        if newValue != self.value {
            self.value = newValue
        }
    }
}

// SocketIOClient status description helper
extension SocketIOStatus {
    var description: String {
        switch self {
        case .notConnected: return "Not Connected"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }
}
