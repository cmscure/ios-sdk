// Standard Library & System Frameworks
import Foundation
#if canImport(UIKit)
import UIKit // For app lifecycle notifications
#endif

// Third-Party Frameworks
import SocketIO // Socket.IO Client Library
import CryptoKit // For SHA256, AES.GCM, HMAC
import Combine // For SwiftUI integration (@Published, ObservableObject)
import SwiftUI // For Color type and SwiftUI helpers

/// Convenience typealias for the SDK singleton
public typealias Cure = CMSCureSDK

/// The main class for interacting with the CMSCure backend and managing content.
/// NOTE: This version uses the original custom encryption and socket handshake logic.
public class CMSCureSDK {
    /// Shared singleton instance for accessing SDK functionality.
    public static let shared = CMSCureSDK()

    // MARK: - Configuration & State

    // --- Server URL Configuration ---
    /// Base URL for API calls, determined by build configuration.
    #if DEBUG
    // Use local IP/hostname for Debug builds (ensure backend is accessible)
    private var serverUrl = "http://10.12.23.144:5050" // Use original variable name
    /// Explicit URL for Socket.IO connections, determined by build configuration.
    private var socketIOURL = "ws://10.12.23.144:5050"   // Use original variable name
    #else
    // Use production URLs for Release builds
    /// Base URL for API calls, determined by build configuration.
    private var serverUrl = "https://app.cmscure.com" // Your production API endpoint
    /// Explicit URL for Socket.IO connections, determined by build configuration.
    private var socketIOURL = "wss://app.cmscure.com"  // Your production Socket.IO endpoint (use wss for HTTPS)
    #endif

    // --- Credentials & Tokens (Access MUST be synchronized via cacheQueue) ---
    /// The project secret provided during authentication (used for socket handshake).
    private var projectSecret: String = ""
    /// The API secret provided during authentication (used for deriving encryption key).
    private var apiSecret: String? = nil // Should typically be the same as projectSecret for this flow
    /// Symmetric key derived from apiSecret for encrypting API requests.
    private var symmetricKey: SymmetricKey? = nil
    /// Auth token received from the original /api/sdk/auth endpoint (might be JWT or custom).
    private var authToken: String? = nil // Store the token received from the original auth endpoint
    
    private var knownProjectTabs: Set<String> = []

    // --- SDK Settings ---
    /// Flag to enable/disable verbose logging to the console.
    public var debugLogsEnabled: Bool = true
    /// Interval (in seconds) for periodically checking for content updates via polling. Defaults to 5 minutes.
    public var pollingInterval: TimeInterval = 300 {
        didSet {
            pollingInterval = max(60, min(pollingInterval, 600)) // Enforce bounds
            DispatchQueue.main.async { // Timer operations should be on main thread
                if self.pollingTimer != nil { self.setupPollingTimer() }
            }
        }
    }

    // --- Cache & Language (Access MUST be synchronized via cacheQueue) ---
    /// In-memory cache storing fetched translations and colors. Structure: `[ScreenName: [Key: [Lang: Value]]]`
    private var cache: [String: [String: [String: String]]] = [:]
    /// The currently active language code (e.g., "en", "fr").
    private var currentLanguage: String = "en"
    /// List of known tab names associated with the authenticated project (loaded from disk). Used by syncIfOutdated.
    private var offlineTabList: [String] = [] // Use original variable name

    // --- Persistence Paths ---
    /// File URL for storing the content cache (`cache.json`).
    private let cacheFilePath: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK") // Original folder name
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }()
    /// File URL for storing the list of known project tabs (`tabs.json`).
    private let tabsFilePath: URL = { // Use original name pattern if preferred
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tabs.json") // Changed from offlineTabListFilePath
    }()
    /// File URL for storing the configuration (token, secrets) (`config.json`).
    private let configFilePath: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()


    // --- Synchronization Queue ---
    /// Concurrent queue to manage thread-safe access to shared state (cache, token, tabs list). Writes use barriers.
    // Using a serial queue as per the originally uploaded file
    private let cacheQueue = DispatchQueue(label: "com.cmscure.cacheQueue")

    // --- Networking & Updates ---
    /// The Socket.IO client instance. Access synchronized or on main thread.
    private var socket: SocketIOClient?
    /// The Socket.IO manager instance. Access synchronized or on main thread.
    private var manager: SocketManager?
    /// Timer for periodic polling syncs. Managed on the main thread.
    private var pollingTimer: Timer?
    /// Dictionary holding callback closures provided by the app for specific screen updates. Managed on the main thread.
    private var translationUpdateHandlers: [String: ([String: String]) -> Void] = [:]
    /// State to track if the custom handshake has been acknowledged. Reset on disconnect.
    private var handshakeAcknowledged = false
    /// Stores the last sync check time to potentially avoid redundant syncs (though not fully implemented in syncIfOutdated).
    private var lastSyncCheck: Date?

    // MARK: - Initialization

    /// Private initializer for the singleton pattern. Loads state and attempts connection.
    private init() {
        // Load initial state synchronously (safe during init)
        loadCacheFromDisk()
        // offlineTabList is loaded within loadCacheFromDisk in this version
        self.currentLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en"
        // Attempt to load saved config (token and secrets)
        if let savedConfig = readConfig() {
            self.authToken = savedConfig["authToken"]
            self.projectSecret = savedConfig["projectSecret"] ?? ""
            // Use projectSecret as the apiSecret for key derivation in this original flow
            if !self.projectSecret.isEmpty {
                 setAPISecret(self.projectSecret) // Derive symmetric key
            }
        }

        // Setup background tasks & listeners (on main thread)
        DispatchQueue.main.async {
            self.observeAppActiveNotification()
            self.setupPollingTimer()
            // Try to connect socket if config exists (original behavior)
            self.startListening()
        }

        // Initial log messages
        if debugLogsEnabled {
            print("🚀 CMSCureSDK Initialized (Reverted Original - Corrected).")
            print("   - API Base URL: \(serverUrl)") // Use correct variable
            print("   - Socket Base URL: \(socketIOURL)") // Use correct variable
            print("   - Initial Offline Tabs: \(offlineTabList)") // Log offline tabs
            if self.authToken != nil {
                print("   - Found saved auth token.")
            } else {
                print("   - No saved auth token found. Waiting for authenticate() call.")
            }
        }
    }

    // MARK: - Public Configuration

    /// Sets the API Secret used for encryption/decryption and derives the symmetric key.
    /// Called internally during `authenticate`. Ensures thread safety.
    public func setAPISecret(_ secret: String) {
        cacheQueue.async { // Use async for potential background derivation
            self.apiSecret = secret
            if let secretData = secret.data(using: .utf8) {
                // Use SHA256 from CryptoKit to derive the key
                self.symmetricKey = SymmetricKey(data: SHA256.hash(data: secretData))
                if self.debugLogsEnabled { print("🔑 Symmetric key derived.") }
            } else {
                 if self.debugLogsEnabled { print("⚠️ Failed to create data from API secret string.") }
                 self.symmetricKey = nil // Ensure key is nil if derivation fails
            }
        }
    }

    /// Sets the current language, updates UserDefaults, and triggers UI/cache updates for all known tabs.
    /// - Parameters:
    ///   - language: The new language code (e.g., "en", "fr").
    ///   - force: If true, forces sync even if language is the same.
    ///   - completion: Optional closure called after sync operations are attempted.
    public func setLanguage(_ language: String, force: Bool = false, completion: (() -> Void)? = nil) {
        var shouldUpdate = false
        var screensToUpdate: [String] = []

        // Check if update is needed and get tabs list (thread-safe read)
        cacheQueue.sync {
            if language != self.currentLanguage || force {
                shouldUpdate = true
                self.currentLanguage = language // Update language synchronously
                UserDefaults.standard.set(language, forKey: "selectedLanguage") // Persist preference
                // Get combined list of cached tabs and known offline tabs
                screensToUpdate = Array(Set(self.cache.keys).union(Set(self.offlineTabList)))
            }
        }

        // Exit if no update needed
        guard shouldUpdate else {
            completion?()
            return
        }

        if self.debugLogsEnabled { print("🔄 Switching to language '\(language)'") }

        // Use DispatchGroup to wait for all syncs to complete (optional)
        let group = DispatchGroup()

        for screenName in screensToUpdate {
            if self.debugLogsEnabled { print("🔄 Updating language for tab '\(screenName)'") }
            // Immediately trigger UI update with cached data for the new language
            let cachedValues = self.getCachedTranslations(for: screenName, language: language)
            DispatchQueue.main.async {
                self.notifyUpdateHandlers(screenName: screenName, values: cachedValues)
            }
            // Then sync in background for latest updates
            group.enter()
            self.sync(screenName: screenName) { success in
                 // Sync function handles its own UI updates now
                group.leave()
            }
        }
        group.notify(queue: .main) { completion?() }
    }

    /// Gets the currently active language code. Thread-safe read.
    public func getLanguage() -> String {
        return cacheQueue.sync { self.currentLanguage }
    }

    /// Clears all SDK data: in-memory cache, known tabs list, auth token, keys, and persisted files.
    public func clearCache() { // Use original function name
        cacheQueue.async { // Use async for file operations
            // Clear in-memory state
            self.cache.removeAll()
            self.offlineTabList.removeAll()
            self.authToken = nil
            self.symmetricKey = nil
            self.projectSecret = ""
            self.apiSecret = nil
            self.handshakeAcknowledged = false

            // Delete persisted files
            do {
                if FileManager.default.fileExists(atPath: self.cacheFilePath.path) {
                    try FileManager.default.removeItem(at: self.cacheFilePath)
                }
                // Use tabsFilePath here
                if FileManager.default.fileExists(atPath: self.tabsFilePath.path) {
                    try FileManager.default.removeItem(at: self.tabsFilePath)
                }
                 if FileManager.default.fileExists(atPath: self.configFilePath.path) {
                    try FileManager.default.removeItem(at: self.configFilePath)
                }
                if self.debugLogsEnabled { print("🧹 Cache, Tabs List, and Config files cleared.") }
            } catch {
                 if self.debugLogsEnabled { print("❌ Failed to delete cache/config files: \(error)") }
            }
            // Notify UI components to clear their state
            DispatchQueue.main.async {
                for screenName in self.translationUpdateHandlers.keys {
                    self.notifyUpdateHandlers(screenName: screenName, values: [:])
                }
            }
        }
    }

    // MARK: - Core Translation & Color Access (Thread-safe Reads)

    /// Retrieves the translation for a given key and screen name in the current language. Thread-safe.
    public func translation(for key: String, inTab screenName: String) -> String {
        return cacheQueue.sync { // Synchronized read
            let lang = self.currentLanguage
            if self.debugLogsEnabled { /* print("🔍 Reading '\(key)' from '\(screenName)' in '\(lang)'") */ }
            guard let tabCache = cache[screenName], let keyMap = tabCache[key], let translation = keyMap[lang] else {
                if self.debugLogsEnabled && (cache[screenName] == nil || cache[screenName]?[key] == nil || cache[screenName]?[key]?[lang] == nil) {
                     // print("⚠️ Translation missing: \(screenName)/\(key)/\(lang)")
                }
                return ""
            }
            return translation
        }
    }

    /// Retrieves the color hex string for a given global color key (from `__colors__` tab). Thread-safe.
    public func colorValue(for key: String) -> String? {
        return cacheQueue.sync { // Synchronized read
            if self.debugLogsEnabled { /* print("🎨 Reading global color value for key '\(key)'") */ }
            guard let colorTab = cache["__colors__"], let valueMap = colorTab[key], let colorHex = valueMap["color"] else {
                if self.debugLogsEnabled && (cache["__colors__"] == nil || cache["__colors__"]?[key] == nil || cache["__colors__"]?[key]?["color"] == nil) {
                    // print("⚠️ Color missing: \(key)")
                }
                return nil
            }
            return colorHex
        }
    }

    /// Retrieves the image URL for a given key and screen name in the current language. Thread-safe.
    public func imageUrl(for key: String, inTab screenName: String) -> URL? {
        let urlString = self.translation(for: key, inTab: screenName) // Uses thread-safe translation()
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            if self.debugLogsEnabled && !urlString.isEmpty { print("❌ Invalid URL format for key '\(key)' in tab '\(screenName)': \(urlString)") }
            return nil
        }
        return url
    }

    /// Retrieves all cached translations for a specific screen and language. Used internally. Thread-safe read.
    private func getCachedTranslations(for screenName: String, language: String) -> [String: String] {
         return cacheQueue.sync { // Synchronized read
            var values: [String: String] = [:]; if let tabCache = self.cache[screenName] { for (key, valueMap) in tabCache { values[key] = valueMap[language] } }; return values.compactMapValues { $0 }
        }
    }

    // MARK: - Synchronization Logic (Original Encryption Method)

    /// Fetches the latest translations/colors using the original encryption method.
    public func sync(screenName: String, completion: @escaping (Bool) -> Void) {
        // Read required credentials safely
        var currentProjectId: String?
        cacheQueue.sync { currentProjectId = self.readProjectIdFromConfig() }

        guard let projectId = currentProjectId else {
            if self.debugLogsEnabled { print("❌ Sync failed for '\(screenName)': Missing project ID.") }
            completion(false); return
        }

        // Construct the API URL using serverUrl
        guard let url = URL(string: "\(serverUrl)/api/sdk/translations/\(projectId)/\(screenName)") else {
            if self.debugLogsEnabled { print("❌ Sync failed for '\(screenName)': Invalid URL components. Base URL: \(serverUrl)") }
            completion(false); return
        }

        // Prepare the URLRequest
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        // --- *** Prepare Encrypted Body and Signature (Original Method) *** ---
        let (encryptedBody, signature) = cacheQueue.sync { () -> (Data?, String?) in
            let bodyDict: [String: Any] = ["projectId": projectId, "screenName": screenName]
            let encrypted = self.encryptBody(bodyDict)
            var sig: String? = nil
            if let bodyData = encrypted, let key = self.symmetricKey {
                let hmac = HMAC<SHA256>.authenticationCode(for: bodyData, using: key)
                sig = Data(hmac).base64EncodedString()
            }
            return (encrypted, sig)
        }

        guard let finalEncryptedBody = encryptedBody else {
            if self.debugLogsEnabled { print("❌ Sync failed for '\(screenName)': Failed to encrypt request body.") }
            completion(false); return
        }
        request.httpBody = finalEncryptedBody

        if let finalSignature = signature {
            request.setValue(finalSignature, forHTTPHeaderField: "X-Signature")
        } else if self.debugLogsEnabled {
             print("⚠️ Sync warning for '\(screenName)': Could not generate signature (symmetric key missing?).")
        }
        // --- *** END Encryption/Signature *** ---

        if debugLogsEnabled { print("🔄 Syncing '\(screenName)' (Using Encryption)...") }

        // Execute the network request
        URLSession.shared.dataTask(with: request) { data, response, error in
            // Handle Network Errors
            if let error = error {
                if self.debugLogsEnabled { print("❌ Sync failed for '\(screenName)': Network error - \(error.localizedDescription)") }
                completion(false); return
            }
            // Validate HTTP Response
            guard let httpResponse = response as? HTTPURLResponse else {
                 if self.debugLogsEnabled { print("❌ Sync failed for '\(screenName)': Invalid response type.") }
                 completion(false); return
            }
            // Check Status Code (Handle 404 gracefully)
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 404 else {
                if self.debugLogsEnabled {
                    print("❌ Sync failed for '\(screenName)': HTTP status code \(httpResponse.statusCode)")
                    if let data = data, let responseBody = String(data: data, encoding: .utf8) { print("   Response Body: \(responseBody)") }
                }
                completion(false); return
            }
             if httpResponse.statusCode == 404 {
                 if self.debugLogsEnabled { print("ℹ️ Sync info for '\(screenName)': No published translations found.") }
                 completion(true); return
             }

            // Validate and Parse Response Data
             guard let data = data else {
                if self.debugLogsEnabled { print("❌ Sync failed for '\(screenName)': No data received.") }
                completion(false); return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let keys = json["keys"] as? [[String: Any]] else {
                if self.debugLogsEnabled {
                    print("❌ Sync failed for '\(screenName)': Failed to parse JSON response.")
                    print("   Raw response:", String(data: data, encoding: .utf8) ?? "nil")
                }
                completion(false); return
            }

            // --- Update Cache and Persistence (Thread-Safe Write) ---
            self.cacheQueue.async { // Use async for cache update
                var updatedTabValuesForCurrentLang: [String: String] = [:]
                var newCacheForScreen: [String: [String: String]] = self.cache[screenName] ?? [:]
                let currentLang = self.currentLanguage

                for item in keys {
                    if let k = item["key"] as? String, let values = item["values"] as? [String: String] {
                        newCacheForScreen[k] = values
                        if let v = values[currentLang] { updatedTabValuesForCurrentLang[k] = v }
                    }
                }
                self.cache[screenName] = newCacheForScreen
                if !self.offlineTabList.contains(screenName) { self.offlineTabList.append(screenName) } // Use offlineTabList

                self.saveCacheToDisk()
                self.saveOfflineTabListToDisk() // Save updated tabs list

                DispatchQueue.main.async {
                    self.notifyUpdateHandlers(screenName: screenName, values: updatedTabValuesForCurrentLang)
                    if self.debugLogsEnabled { print("✅ Synced translations for \(screenName)") }
                    completion(true)
                }
            } // End cacheQueue async
        }.resume()
    }


    /// Triggers sync for all known project tabs plus special tabs.
    private func syncIfOutdated() {
        // Get list of tabs to sync (combine cached and offline lists)
        let tabsToSync = cacheQueue.sync {
             Array(Set(self.cache.keys).union(Set(self.offlineTabList))).filter { !$0.starts(with: "__") }
        }
        let specialTabs = ["__colors__", "__images__"] // Sync special tabs based on original logic

        let allTabs = tabsToSync + specialTabs
        if debugLogsEnabled && !allTabs.isEmpty {
             print("🔄 Syncing tabs on app active/poll: \(allTabs.joined(separator: ", "))")
        }

        // Check if authenticated (has secrets needed for encryption)
        var secretsAvailable: Bool = false
        cacheQueue.sync { secretsAvailable = self.symmetricKey != nil && !self.projectSecret.isEmpty }
        guard secretsAvailable else {
            if debugLogsEnabled { print("ℹ️ Skipping sync: Missing secrets/keys.") }
            return
        }

        // Trigger sync for each tab concurrently
        for tab in allTabs {
            self.sync(screenName: tab) { success in
                if !success && self.debugLogsEnabled {
                     print("⚠️ Failed to sync tab '\(tab)' during periodic/app-active sync.")
                }
            }
        }
    }

    // MARK: - Socket Communication (Original Handshake Method)

    /// Establishes connection with the Socket.IO server.
    public func connectSocket() { // Removed parameters as they weren't used in original call path
        // Read project ID safely
        var currentProjectId: String?
        cacheQueue.sync { currentProjectId = self.readProjectIdFromConfig() }

        guard let projectId = currentProjectId else {
            if self.debugLogsEnabled { print("ℹ️ Socket connection deferred: Missing project ID.") }
            return
        }

        // Perform on main thread if SocketManager requires it
        DispatchQueue.main.async {
            // Check existing status
            let currentStatus = self.manager?.status ?? .notConnected
            guard currentStatus != .connected && currentStatus != .connecting else {
                if self.debugLogsEnabled { print("⚠️ Socket already connected or connecting.") }
                if currentStatus == .connected && !self.handshakeAcknowledged { self.sendHandshake(projectId: projectId) }
                return
            }

            // Validate socket URL using socketIOURL
            guard let url = URL(string: self.socketIOURL) else {
                 if self.debugLogsEnabled { print("❌ Invalid socket URL: \(self.socketIOURL)") }
                 return
            }

            // Configure SocketManager (no specific auth params needed here for original handshake)
            let socketConfig: SocketIOClientConfiguration = [
                .log(self.debugLogsEnabled), .compress, .reconnects(true), .reconnectAttempts(-1),
                .reconnectWait(3), .reconnectWaitMax(10), .forceWebsockets(true)
            ]

            // Disconnect old manager and create a new one
            self.manager?.disconnect()
            if self.debugLogsEnabled { print("🔌 Creating new SocketManager for \(url)...") }
            self.manager = SocketManager(socketURL: url, config: socketConfig)

            guard let currentManager = self.manager else {
                 if self.debugLogsEnabled { print("❌ Failed to create SocketManager.") }
                 return
            }

            self.socket = currentManager.defaultSocket
            if self.debugLogsEnabled { print("🔌 Attempting socket connect()...") }
            self.setupSocketHandlers(projectId: projectId) // Attach event handlers
            self.socket?.connect() // Initiate connection
        }
    }


    /// Sets up the event handlers (listeners) for the Socket.IO client.
    private func setupSocketHandlers(projectId: String) {
        guard let currentSocket = socket else {
            if debugLogsEnabled { print("❌ setupSocketHandlers: Socket instance is nil.") }
            return
        }
         if debugLogsEnabled { print("👂 Setting up socket handlers for socket ID: \(currentSocket.sid ?? "N/A") (nsp: \(currentSocket.nsp))") }

        // Remove existing handlers first
        currentSocket.off(clientEvent: .connect)
        currentSocket.off("handshake_ack") // Listen for custom ack
        currentSocket.off("translationsUpdated")
        currentSocket.off(clientEvent: .disconnect)
        currentSocket.off(clientEvent: .error)
        currentSocket.off(clientEvent: .reconnect)
        currentSocket.off(clientEvent: .reconnectAttempt)
        currentSocket.off(clientEvent: .statusChange)

        // --- Handlers for Original Flow ---
        currentSocket.on(clientEvent: .connect) { [weak self] data, ack in
             guard let self = self else { return }
            if self.debugLogsEnabled { print("🟢✅ Socket connect handler fired! SID: \(self.socket?.sid ?? "N/A")") }
            // Reset handshake status and send handshake
            self.cacheQueue.async { self.handshakeAcknowledged = false } // Use async non-barrier
            self.sendHandshake(projectId: projectId)
        }

        // Listen for the custom handshake acknowledgement
        currentSocket.on("handshake_ack") { [weak self] data, ack in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("🤝 Handshake acknowledged by server.") }
            self.cacheQueue.async { self.handshakeAcknowledged = true } // Use async non-barrier
            // Trigger sync after successful handshake
            self.syncIfOutdated()
        }

        currentSocket.on("translationsUpdated") { [weak self] data, ack in
             guard let self = self else { return }
            print(">>> DEBUG: Received 'translationsUpdated' event from server. Data: \(data)")
            if self.debugLogsEnabled { print("📡 Socket update received: \(data)") }
            self.handleSocketTranslationUpdate(data: data)
        }

        currentSocket.on(clientEvent: .disconnect) { [weak self] data, ack in
             guard let self = self else { return }
             if self.debugLogsEnabled { print("🔌 Socket disconnected. Reason: \(data)") }
             // Reset handshake status on disconnect
             self.cacheQueue.async { self.handshakeAcknowledged = false }
        }

        currentSocket.on(clientEvent: .error) { [weak self] data, _ in
             guard let self = self else { return }
             if let error = data.first as? Error { print("❌ Socket error: \(error.localizedDescription)") }
             else { print("❌ Socket error: \(data)") }
             // Reset handshake status on error? Maybe not, depends on error type.
             // self.cacheQueue.async { self.handshakeAcknowledged = false }
        }

        currentSocket.on(clientEvent: .reconnect) { [weak self] data, _ in
             guard let self = self else { return }
             if self.debugLogsEnabled { print("🔁 Socket reconnected. Data: \(data)") }
             // Connect handler will fire again, triggering handshake.
        }

        currentSocket.on(clientEvent: .reconnectAttempt) { [weak self] data, _ in
             guard let self = self else { return }
             if self.debugLogsEnabled { print("🔁 Attempting socket reconnect... \(data)") }
             // Reset handshake status before attempting reconnect
             self.cacheQueue.async { self.handshakeAcknowledged = false }
        }

        currentSocket.on(clientEvent: .statusChange) { [weak self] data, _ in
             guard let self = self else { return }
             if self.debugLogsEnabled { print("ℹ️ Socket status changed: \(self.socket?.status.description ?? "Unknown")") }
        }

        if debugLogsEnabled { print("👂✅ Socket handlers setup complete for socket ID: \(currentSocket.sid ?? "N/A")") }
    }

    /// Sends the encrypted handshake message to the server using projectSecret.
    private func sendHandshake(projectId: String) {
         // Read projectSecret safely
         var secretToSend: String?
         cacheQueue.sync { secretToSend = self.projectSecret }

         guard let secret = secretToSend, !secret.isEmpty else {
             if debugLogsEnabled { print("❌ Cannot send handshake: Project secret not available.") }
             return
         }

         // Encrypt body containing projectId using projectSecret
         let encryptedPayload = cacheQueue.sync { () -> Data? in
             // Derive key from projectSecret specifically for handshake
             guard let secretData = secret.data(using: .utf8) else { return nil }
             let handshakeKey = SymmetricKey(data: SHA256.hash(data: secretData))
             let body = ["projectId": projectId] // Payload to encrypt
             guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
             do {
                 let sealedBox = try AES.GCM.seal(jsonData, using: handshakeKey)
                 let result: [String: String] = [
                     "iv": sealedBox.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
                     "ciphertext": sealedBox.ciphertext.base64EncodedString(),
                     "tag": sealedBox.tag.base64EncodedString()
                 ]
                 return try JSONSerialization.data(withJSONObject: result)
             } catch {
                 if debugLogsEnabled { print("❌ Handshake encryption failed: \(error)") }
                 return nil
             }
         }

         guard let encryptedData = encryptedPayload,
               var sealed = try? JSONSerialization.jsonObject(with: encryptedData, options: []) as? [String: Any] else { // Make sealed mutable
             if self.debugLogsEnabled { print("❌ Failed to encrypt handshake payload, cannot send.") }
             // Maybe disconnect or retry?
             return
         }

         // Add plain projectId if backend expects it alongside encrypted data
         sealed["projectId"] = projectId // Add projectId to the dictionary

         if self.debugLogsEnabled { print("🤝 Sending handshake: \(sealed)") }
         // Ensure socket is valid before emitting
         DispatchQueue.main.async { // Emit from main thread if required
             self.socket?.emit("handshake", sealed)
         }
    }


    /// Handles incoming 'translationsUpdated' events from the socket.
    private func handleSocketTranslationUpdate(data: [Any]) {
        print(">>> DEBUG: handleSocketTranslationUpdate entered. Data: \(data)")
        guard let dict = data.first as? [String: Any],
              let screenName = dict["screenName"] as? String else {
            if self.debugLogsEnabled { print("⚠️ Invalid socket data format received for translationsUpdated: \(data)") }
            return
        }
        if self.debugLogsEnabled { print("📡 Processing socket update for tab: \(screenName)") }

        // Trigger sync based on received screenName
        if screenName == "__ALL__" {
            if self.debugLogsEnabled { print("🔄 Socket requested sync for __ALL__ tabs.") }
            self.syncIfOutdated() // Sync all known tabs
        } else {
            // Sync only the specific tab mentioned in the event
            self.sync(screenName: screenName) { success in
                if !success && self.debugLogsEnabled {
                    print("❌ Failed to refresh tab '\(screenName)' after socket update signal.")
                }
            }
        }
    }

    /// Attempts connection if config exists. Called by app lifecycle events or after auth.
    public func startListening() {
        // Read config needed for connection (projectId)
        var currentProjectId: String?
        cacheQueue.sync { currentProjectId = self.readProjectIdFromConfig() }

        if currentProjectId != nil {
            connectSocket() // Call original connectSocket which doesn't require token param
        } else if debugLogsEnabled {
            print("ℹ️ startListening: No projectId available, connection deferred.")
        }
    }

    /// Disconnects the socket.
    public func stopListening() {
        // Perform on main thread if SocketManager requires it
        DispatchQueue.main.async {
            self.manager?.disconnect()
            if self.debugLogsEnabled { print("🔌 Socket disconnect requested.") }
        }
    }

    /// Checks if the socket is currently connected.
    public func isConnected() -> Bool {
        return manager?.status == .connected
    }


    // MARK: - Authentication (Original Encryption Method)

    /// Authenticates the SDK using the original encryption method.
    public func authenticate(apiKey: String, projectId: String, projectSecret: String, completion: @escaping (Bool) -> Void) {

        // Store secrets immediately for encryption and handshake
        self.cacheQueue.async { // Use async, barrier not strictly needed if only writes happen here
            self.projectSecret = projectSecret
            // Assume apiSecret is the same as projectSecret for key derivation
            self.apiSecret = projectSecret
            if let secretData = projectSecret.data(using: .utf8) {
                self.symmetricKey = SymmetricKey(data: SHA256.hash(data: secretData))
                if self.debugLogsEnabled { print("🔑 Symmetric key derived from projectSecret.") }
            } else {
                if self.debugLogsEnabled { print("⚠️ Failed to create data from projectSecret string.") }
                self.symmetricKey = nil
            }
        }

        // Construct URL - Use projectId in query param as per original controller
        guard let url = URL(string: "\(serverUrl)/api/sdk/auth?projectId=\(projectId)") else {
             if self.debugLogsEnabled { print("❌ Auth failed: Invalid API URL. Base: \(serverUrl)") }
             completion(false); return
        }

        // Prepare Request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        // Prepare Encrypted Body (using derived symmetricKey)
        // This needs to run after the key derivation has potentially completed.
        // Using a synchronous fetch from the queue ensures the key is available.
        let encryptedBody = cacheQueue.sync { () -> Data? in
            guard self.symmetricKey != nil else {
                if debugLogsEnabled { print("❌ Auth encryption failed: Symmetric key not ready.") }
                return nil
            }
            // Payload for encryption (as expected by original backend controller)
            let bodyDict: [String: String] = ["apiKey": apiKey, "projectId": projectId] // Removed projectSecret from here
            return self.encryptBody(bodyDict) // Use helper
        }

        guard let finalEncryptedBody = encryptedBody else {
            if self.debugLogsEnabled { print("❌ Auth failed: Failed to encrypt request body.") }
            completion(false); return
        }
        request.httpBody = finalEncryptedBody

        // Add signature header (optional, depends on original backend)
        // let signature = cacheQueue.sync { ... generate signature ... }
        // if let sig = signature { request.setValue(sig, forHTTPHeaderField: "X-Signature") }

        if debugLogsEnabled { print("🔑 Authenticating with Project ID: \(projectId) (Using Encryption)...") }

        // Perform Network Request
        URLSession.shared.dataTask(with: request) { data, response, error in
            // Handle network error
            if let error = error {
                if self.debugLogsEnabled { print("❌ Auth failed: Network error - \(error.localizedDescription)") }
                DispatchQueue.main.async { completion(false) }; return
            }
            // Check response type
            guard let httpResponse = response as? HTTPURLResponse else {
                 if self.debugLogsEnabled { print("❌ Auth failed: Invalid response.") }
                 DispatchQueue.main.async { completion(false) }; return
            }
            // Check status code (expect 200 for success)
            guard httpResponse.statusCode == 200 else {
                if self.debugLogsEnabled {
                    print("❌ Auth failed: HTTP status code \(httpResponse.statusCode)")
                     if let data = data, let responseBody = String(data: data, encoding: .utf8) { print("   Response Body: \(responseBody)") }
                }
                DispatchQueue.main.async { completion(false) }; return
            }
            // Decode response (Original backend returned token, userId, projectId, projectSecret)
            // Also expect 'tabs' now based on updated original backend logic
            guard let data = data,
                  let result = try? JSONDecoder().decode(AuthResult_OriginalWithTabs.self, from: data),
                  let receivedToken = result.token,
                  let receivedProjectId = result.projectId,
                  let receivedProjectSecret = result.projectSecret
            else {
                if self.debugLogsEnabled {
                    print("❌ Auth failed: Decoding failed or essential fields missing.")
                    print("   Raw response:", String(data: data ?? Data(), encoding: .utf8) ?? "nil")
                }
                DispatchQueue.main.async { completion(false) }; return
            }

            // --- Authentication successful ---
            let receivedTabs = result.tabs ?? [] // Get tabs if available

            // Prepare config to save (includes received token and received secret)
            let config: [String: String] = [
                "projectId": receivedProjectId,
                "authToken": receivedToken,
                "projectSecret": receivedProjectSecret
                // apiSecret is no longer needed if derived from projectSecret
            ]

            // Update internal state and save config/tabs (Thread-Safe Write)
            self.cacheQueue.async { // Use async, ensure completion handler runs after this block
                // Update in-memory state
                self.projectSecret = receivedProjectSecret // Update with value from server
                self.authToken = receivedToken
                self.knownProjectTabs = Set(receivedTabs) // Store tabs list

                // Persist config and tabs to disk
                let configSaved = self.saveConfig(config)
                self.saveOfflineTabListToDisk() // Save tabs list using correct function name

                // Dispatch back to main thread
                DispatchQueue.main.async {
                    if self.debugLogsEnabled { print("✅ Authenticated successfully (Original Method). Token received. Known Tabs: \(receivedTabs)") }
                    // Trigger socket connection and initial sync
                    self.connectSocket() // Uses original handshake logic
                    self.syncIfOutdated()
                    completion(configSaved)
                }
            }
        }.resume()
    }


    // MARK: - Persistence (Cache, Tabs & Config) - Thread-safe implementations

    /// Saves the current in-memory cache to `cache.json`. Assumes running within `cacheQueue`.
    private func saveCacheToDisk() {
        let cacheToSave = self.cache // Capture state within queue
        do {
            let data = try JSONEncoder().encode(cacheToSave)
            try data.write(to: self.cacheFilePath, options: .atomic) // Use standard option
        } catch { if self.debugLogsEnabled { print("❌ Failed to save cache: \(error)") } }
    }

    /// Loads the cache from `cache.json` during initialization.
    private func loadCacheFromDisk() {
        guard FileManager.default.fileExists(atPath: self.cacheFilePath.path) else { return }
        do {
            let data = try Data(contentsOf: self.cacheFilePath)
            if let loadedCache = try? JSONDecoder().decode([String: [String: [String: String]]].self, from: data) {
                 self.cache = loadedCache
            } else {
                if debugLogsEnabled { print("⚠️ Failed to decode cache file, removing.") }
                try? FileManager.default.removeItem(at: self.cacheFilePath)
            }
            // Load offline list after cache load
            loadOfflineTabListFromDisk()
        } catch {
            if debugLogsEnabled { print("❌ Failed to load cache file, removing. Error: \(error)") }
            try? FileManager.default.removeItem(at: self.cacheFilePath)
        }
    }

    /// Saves the list of known project tabs to `tabs.json`. Assumes running within `cacheQueue`.
    private func saveOfflineTabListToDisk() { // Use original function name
         let listToSave = self.offlineTabList // Use original variable name
         do {
             let data = try JSONEncoder().encode(listToSave)
             try data.write(to: self.tabsFilePath, options: .atomic) // Use standard option
             if debugLogsEnabled { /* print("💾 Saved known tabs list: \(listToSave)") */ }
         } catch { if debugLogsEnabled { print("❌ Failed to save known tabs list: \(error)") } }
     }

    /// Loads the list of known project tabs from `tabs.json` during initialization.
    private func loadOfflineTabListFromDisk() { // Use original function name
         guard FileManager.default.fileExists(atPath: self.tabsFilePath.path) else { return }
         do {
             let data = try Data(contentsOf: self.tabsFilePath)
             self.offlineTabList = try JSONDecoder().decode([String].self, from: data) // Load into original variable
             // Copy to Set if needed internally, but keep Array for persistence
             self.knownProjectTabs = Set(self.offlineTabList)
             if debugLogsEnabled { print("📦 Loaded offline tab list: \(self.offlineTabList)") }
         } catch {
             if debugLogsEnabled { print("❌ Failed to load known tabs list, removing. Error: \(error)") }
             try? FileManager.default.removeItem(at: self.tabsFilePath) // Remove corrupt file
         }
     }

    /// Saves the authentication configuration to `config.json`. Assumes running within `cacheQueue`.
    private func saveConfig(_ config: [String: String]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: configFilePath.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let jsonData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
            try jsonData.write(to: self.configFilePath, options: .atomic) // Use standard option
            if self.debugLogsEnabled { print("💾 Saved config to \(configFilePath.lastPathComponent)") }
            return true
        } catch { if self.debugLogsEnabled { print("❌ Failed to save config: \(error)") }; return false }
    }

    /// Reads the authentication configuration from `config.json`. Safe to call anytime.
    private func readConfig() -> [String: String]? {
        guard FileManager.default.fileExists(atPath: configFilePath.path),
              let data = try? Data(contentsOf: configFilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return json
    }

    /// Reads the auth token, checking memory first, then optionally disk. Thread-safe.
    private func readTokenFromConfig(readFromDisk: Bool = true) -> String? {
        var token: String? = nil
        cacheQueue.sync { token = self.authToken } // Check memory
        if token == nil && readFromDisk {
            token = readConfig()?["authToken"] // Check disk
            if let loadedToken = token { // Store in memory if loaded from disk
                cacheQueue.async(flags: .barrier) { self.authToken = loadedToken }
            }
        }
        return token
    }

    /// Reads the project ID from the saved config file. Safe to call anytime.
    private func readProjectIdFromConfig(readFromDisk: Bool = true) -> String? {
        return readConfig()?["projectId"]
    }

    /// Reads the project secret from the saved config file. Safe to call anytime.
    private func readProjectSecretFromConfig(readFromDisk: Bool = true) -> String? {
        return readConfig()?["projectSecret"]
    }

    /// Clears the saved configuration file (`config.json`).
    private func clearConfig() {
         try? FileManager.default.removeItem(at: configFilePath)
         if debugLogsEnabled { print("🧹 Cleared saved config file.") }
    }


    // MARK: - Background Handling & Polling

    /// Sets up observers for app lifecycle events (main thread).
    private func observeAppActiveNotification() {
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        #endif
    }
    /// Called when the app becomes active. Checks socket and triggers sync (main thread).
    @objc private func appDidBecomeActive() {
         if self.debugLogsEnabled { print("📲 App became active — checking socket status & content.") }
         startListening() // Checks config and connects if needed
         syncIfOutdated() // Checks secrets and syncs if needed
    }
    /// Sets up the periodic polling timer (main thread).
    private func setupPollingTimer() {
         pollingTimer?.invalidate()
         pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in guard let self = self else { return }; if self.debugLogsEnabled { print("⏰ Polling timer fired — syncing content.") }; self.syncIfOutdated() }
         if debugLogsEnabled { print("⏱️ Polling timer setup with interval: \(pollingInterval) seconds.") }
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
            // Encrypt using AES-GCM
            let sealedBox = try AES.GCM.seal(jsonData, using: symmetricKey)
            // Combine nonce, ciphertext, and tag into a dictionary for JSON serialization
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

    // MARK: - Update Handling & Notifications

    /// Registers a handler to be called on the main thread when translations for a specific screen are updated.
    public func onTranslationsUpdated(for screenName: String, handler: @escaping ([String: String]) -> Void) {
         DispatchQueue.main.async { // Ensure handler registration and initial call are on main thread
             self.translationUpdateHandlers[screenName] = handler
             let currentValues = self.getCachedTranslations(for: screenName, language: self.getLanguage())
             if !currentValues.isEmpty { handler(currentValues) }
         }
    }
    /// Posts the .translationsUpdated notification and updates the bridge. MUST be called on Main Thread.
    private func postTranslationsUpdatedNotification(screenName: String) {
         assert(Thread.isMainThread, "Must be called on the main thread")
         let newUUID = UUID(); if debugLogsEnabled { print("📬 Posting update notification for '\(screenName)'. New Refresh Token: \(newUUID)") }
         CureTranslationBridge.shared.refreshToken = newUUID
         NotificationCenter.default.post(name: .translationsUpdated, object: nil, userInfo: ["screenName": screenName])
    }
    /// Calls the registered update handlers for a given screen name. MUST be called on Main Thread.
    private func notifyUpdateHandlers(screenName: String, values: [String: String]) {
         assert(Thread.isMainThread, "Must be called on the main thread")
         if debugLogsEnabled { print("📬 Notifying handlers for '\(screenName)'. Values count: \(values.count)") }
         self.translationUpdateHandlers[screenName]?(values)
         self.postTranslationsUpdatedNotification(screenName: screenName) // Also post general notification
    }


    // MARK: - Deprecated / Utility

    /// Checks if a specific tab has any data in the cache. Thread-safe.
    public func isTabSynced(_ tab: String) -> Bool {
         return cacheQueue.sync { !(cache[tab]?.isEmpty ?? true) }
    }
    /// Fetches the list of available languages from the server using original encryption.
    public func availableLanguages(completion: @escaping ([String]) -> Void) {
        // Read required credentials safely (Keep this part)
        var currentProjectId: String?
        cacheQueue.sync { currentProjectId = self.readProjectIdFromConfig() }
        guard let projectId = currentProjectId else {
            self.logError("Missing Project ID for availableLanguages") // Add logging
            self.fallbackToCachedLanguages(completion: completion)
            return
        }
        guard let url = URL(string: "\(serverUrl)/api/sdk/languages/\(projectId)") else {
            self.logError("Invalid URL for availableLanguages: \(serverUrl)/api/sdk/languages/\(projectId)") // Add logging
            self.fallbackToCachedLanguages(completion: completion)
            return
        }

        // Prepare request WITHOUT encryption
        var request = URLRequest(url: url)
        request.httpMethod = "POST" // Or GET if your backend changed it? Verify this. Postman uses POST?
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10 // Keep timeout

        // Create the UNENCRYPTED request body
        let requestBodyDict = ["projectId": projectId] // Simple body, adjust if needed
        do {
            let jsonData = try JSONEncoder().encode(requestBodyDict)
            request.httpBody = jsonData // Set plain JSON data
        } catch {
            self.logError("Failed to encode request body for availableLanguages: \(error)") // Add logging
            self.fallbackToCachedLanguages(completion: completion) // Fallback on encoding error
            return
        }

        // ---- NO ENCRYPTION CALL ----
        // ---- NO SIGNATURE CALCULATION OR HEADER ----

        URLSession.shared.dataTask(with: request) { data, response, error in
            // 1. Handle Network Error (Keep or improve existing handling)
            if let error = error {
                self.logError("Network error fetching languages: \(error.localizedDescription)")
                self.fallbackToCachedLanguages(completion: completion) // Ensure fallback calls completion
                return
            }

            // 2. Check HTTP Response (Keep or improve existing handling)
            guard let httpResponse = response as? HTTPURLResponse else {
                self.logError("Invalid response received fetching languages.")
                 self.fallbackToCachedLanguages(completion: completion)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No body"
                self.logError("HTTP error fetching languages: \(httpResponse.statusCode). Body: \(responseBody)")
                 self.fallbackToCachedLanguages(completion: completion)
                return
            }

            // 3. Check for Data
            guard let responseData = data else {
                 self.logError("No data received fetching languages.")
                 self.fallbackToCachedLanguages(completion: completion)
                return
            }

            // 4. Parse the UNENCRYPTED JSON Response
            do {
                // Define a simple struct matching the expected JSON
                struct LanguagesResponse: Decodable {
                    let languages: [String]
                }
                let decodedResponse = try JSONDecoder().decode(LanguagesResponse.self, from: responseData)

                // --- SUCCESS ---
                // Cache the result if needed (add caching logic here if desired)
                // self.cacheLanguages(decodedResponse.languages)

                // Call the original completion handler on the main thread
                DispatchQueue.main.async {
                    completion(decodedResponse.languages) // <-- The crucial call back to your SwiftUI view
                }

            } catch {
                self.logError("Failed to decode languages response: \(error). Data: \(String(data: responseData, encoding: .utf8) ?? "Invalid data")")
                self.fallbackToCachedLanguages(completion: completion) // Fallback on decoding error
            }

        }.resume()
    }

    /// Provides cached languages as a fallback if fetching from server fails. Thread-safe read.
    private func fallbackToCachedLanguages(completion: @escaping ([String]) -> Void) {
         let cachedLangs = cacheQueue.sync { () -> [String] in
             var allLangs: Set<String> = []; for (_, tabValues) in self.cache { for (_, langMap) in tabValues { allLangs.formUnion(langMap.keys) } }; allLangs.remove("color"); return Array(allLangs).sorted()
         }
         DispatchQueue.main.async {
             if !cachedLangs.isEmpty { if self.debugLogsEnabled { print("⚠️ Using cached languages as fallback: \(cachedLangs)") }; completion(cachedLangs) }
             else { completion([]) }
         }
    }
    
    // Add logging functions to your SDK class for better debugging
    private func logError(_ message: String) {
        print("[CMSCureSDK Error] \(message)")
    }
    private func logDebug(_ message: String) {
        #if DEBUG
        print("[CMSCureSDK Debug] \(message)")
        #endif
    }

    /// Helper struct for decoding original authentication result.
    private struct AuthResult_Original: Decodable {
        let token: String?
        let userId: String?
        let projectId: String?
        let projectSecret: String?
        // Note: Original backend might not have returned tabs, so tabs array is removed here
    }

    /// Helper struct for decoding authentication result + tabs (Used if backend was modified to return tabs)
    // Keep this separate if needed for testing different backend versions
    private struct AuthResult_OriginalWithTabs: Decodable {
        let token: String?
        let userId: String?
        let projectId: String?
        let projectSecret: String?
        let tabs: [String]? // Expect tabs array
    }


    /// Clean up resources when SDK instance is deallocated.
    deinit {
        NotificationCenter.default.removeObserver(self)
        pollingTimer?.invalidate()
        stopListening() // Disconnect socket
    }
}

// MARK: - SwiftUI Color Extension
extension Color {
    /// Initializes a SwiftUI Color from a hex string (e.g., "#RRGGBB" or "RRGGBB"). Returns nil if invalid.
    init?(hex: String?) {
        guard var hexSanitized = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        guard hexSanitized.count == 6 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        self.init(red: Double((rgb & 0xFF0000) >> 16) / 255.0, green: Double((rgb & 0x00FF00) >> 8) / 255.0, blue: Double(rgb & 0x0000FF) / 255.0)
    }
}

// MARK: - Notification Name
extension Notification.Name {
    /// Notification posted when translations or colors are updated via sync or socket event.
    /// The `userInfo` dictionary contains `["screenName": String]`.
    public static let translationsUpdated = Notification.Name("CMSCureTranslationsUpdated") // Make name more specific
}

// MARK: - Error Enum
enum CMSCureSDKError: Error {
    case missingTokenOrProjectId
    case invalidResponse
    case decodingFailed
    case syncFailed(String) // Include screen name
    case socketDisconnected
    case encryptionFailed // Keep for this version
    case configurationError(String)
    case authenticationFailed
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
}

// MARK: - String Extension for Convenience
extension String {
    /// Helper to trigger refresh in SwiftUI views observing the bridge.
    private var bridgeWatcher: UUID { CureTranslationBridge.shared.refreshToken }

    /// Convenience method to get a translation using the shared CMSCureSDK instance.
    /// Example: `"my_label_key".cure(tab: "HomeScreen")`
    public func cure(tab: String) -> String {
        _ = bridgeWatcher // Reads the publisher to ensure view updates
        return Cure.shared.translation(for: self, inTab: tab) // Calls thread-safe SDK method
    }
}

// MARK: - Observable Objects for SwiftUI

/// Shared bridge object whose `refreshToken` changes trigger updates in CureString/CureColor/CureImage.
final class CureTranslationBridge: ObservableObject {
    static let shared = CureTranslationBridge()
    @Published var refreshToken = UUID() // Change this UUID to trigger updates
    private init() {}
}

/// Observable object to automatically update a String value in SwiftUI views.
public final class CureString: ObservableObject {
    private let key: String
    private let tab: String
    private var cancellable: AnyCancellable? = nil
    @Published public private(set) var value: String = ""

    public init(_ key: String, tab: String) {
        self.key = key; self.tab = tab
        self.value = Cure.shared.translation(for: key, inTab: tab) // Initial thread-safe fetch
        cancellable = CureTranslationBridge.shared.$refreshToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateValue() }
    }
    private func updateValue() { let newValue = Cure.shared.translation(for: key, inTab: tab); if newValue != self.value { self.value = newValue } }
}

/// Observable object to automatically update a Color value in SwiftUI views.
public final class CureColor: ObservableObject {
    private let key: String
    private var cancellable: AnyCancellable? = nil
    @Published public private(set) var value: Color? // Use SwiftUI Color

    public init(_ key: String) {
        self.key = key
        self.value = Color(hex: Cure.shared.colorValue(for: key)) // Initial thread-safe fetch
        cancellable = CureTranslationBridge.shared.$refreshToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateValue() }
    }
    private func updateValue() { let newValue = Color(hex: Cure.shared.colorValue(for: key)); if newValue != self.value { self.value = newValue } }
}

/// Observable object to automatically update a URL value (intended for images) in SwiftUI views.
public final class CureImage: ObservableObject {
    private let key: String
    private let tab: String
    private var cancellable: AnyCancellable? = nil
    @Published public private(set) var value: URL? // Stores the URL for the image

    public init(_ key: String, tab: String) {
        self.key = key; self.tab = tab
        self.value = Cure.shared.imageUrl(for: key, inTab: tab) // Initial thread-safe fetch
        cancellable = CureTranslationBridge.shared.$refreshToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateValue() }
    }
    private func updateValue() { let newValue = Cure.shared.imageUrl(for: key, inTab: tab); if newValue != self.value { self.value = newValue } }
}

// MARK: - SocketIOStatus Extension
/// Helper to provide a description for Socket.IO connection statuses.
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
