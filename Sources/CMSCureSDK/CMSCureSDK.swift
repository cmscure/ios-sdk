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
public class CMSCureSDK {
    /// Shared singleton instance for accessing SDK functionality.
    public static let shared = CMSCureSDK()
    
    // MARK: - Configuration & State
    
    // --- NEW: Configuration Storage ---
    /// Structure to hold the essential SDK configuration. Set via the `configure` method.
    public struct CureConfiguration {
        let projectId: String
        let apiKey: String          // API Key for request header authentication
        let projectSecret: String   // Secret for legacy encryption/handshake
        let serverUrl: URL          // Base URL for API calls
        let socketIOURL: URL        // URL for Socket.IO
    }
    
    /// Holds the active SDK configuration. Access via configQueue. MUST be set by calling `configure()`.
    private var configuration: CureConfiguration?
    /// Serial queue for thread-safe access to the configuration property.
    private let configQueue = DispatchQueue(label: "com.cmscuresdk.configqueue") // Serial queue for config safety
    
    // --- Credentials & Tokens (Managed internally, access synchronized via cacheQueue) ---
    // These might be set during a specific authentication flow if needed by the backend,
    // beyond the primary API Key authentication.
    private var apiSecret: String? = nil        // Used for legacy encryption key derivation (often same as projectSecret)
    private var symmetricKey: SymmetricKey? = nil // Derived key for legacy encryption
    private var authToken: String? = nil        // Session token, if received from backend (e.g., via authenticate)
    
    /// List of known tab names associated with the project (loaded/updated). Access via cacheQueue.
    private var knownProjectTabs: Set<String> = []
    /// Array version for persistence. Access via cacheQueue.
    private var offlineTabList: [String] = []
    
    // --- SDK Settings ---
    /// Flag to enable/disable verbose logging to the console. Defaults to true.
    public var debugLogsEnabled: Bool = true
    /// Interval (in seconds) for periodically checking for content updates via polling. Defaults to 5 minutes (300s). Min 60s, Max 600s.
    public var pollingInterval: TimeInterval = 300 {
        didSet {
            pollingInterval = max(60, min(pollingInterval, 600)) // Enforce bounds
            DispatchQueue.main.async { // Timer operations should be on main thread
                if self.pollingTimer != nil { self.setupPollingTimer() } // Restart timer if running
            }
        }
    }
    
    // --- Cache & Language (Access MUST be synchronized via cacheQueue) ---
    /// In-memory cache storing fetched translations and colors. Structure: `[ScreenName: [Key: [Lang: Value]]]`
    private var cache: [String: [String: [String: String]]] = [:]
    /// The currently active language code (e.g., "en", "fr").
    private var currentLanguage: String = "en" // Default language
    
    // --- Persistence Paths ---
    // (Using original paths from the provided file)
    private let cacheFilePath: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }()
    private let tabsFilePath: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tabs.json")
    }()
    private let configFilePath: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CMSCureSDK")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()
    
    
    // --- Synchronization Queue ---
    /// Serial queue to manage thread-safe access to shared state (cache, token, tabs list, secrets).
    private let cacheQueue = DispatchQueue(label: "com.cmscure.cacheQueue")
    
    // --- Networking & Updates ---
    private var socket: SocketIOClient?
    private var manager: SocketManager?
    private var pollingTimer: Timer?
    private var translationUpdateHandlers: [String: ([String: String]) -> Void] = [:]
    private var handshakeAcknowledged = false // For legacy handshake
    private var lastSyncCheck: Date? // Potentially used for optimization
    
    
    // MARK: - Initialization
    
    /// Private initializer for the singleton pattern. Loads persistent state. **Requires `configure()` to be called afterwards.**
    private init() {
        // Load non-sensitive state synchronously (safe during init)
        loadCacheFromDisk() // Loads cache and offlineTabList (which updates knownProjectTabs)
        self.currentLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en"
        
        // Load persisted legacy config (token/secret) - This might be removed later
        if let savedLegacyConfig = readLegacyConfigFromDisk() {
            cacheQueue.sync { self.authToken = savedLegacyConfig["authToken"] }
        }
        
        // Defer Connection Attempt until configured
        DispatchQueue.main.async {
            self.observeAppActiveNotification()
            self.setupPollingTimer()
            self.startListening()
            // NOTE: startListening() is now called at the end of configure()
        }
        
        // Initial log messages
        if debugLogsEnabled {
            print("🚀 CMSCureSDK Initialized. **Waiting for configure() call.**")
            print("   - Initial Language: \(self.currentLanguage)")
            print("   - Initial Offline Tabs: \(self.offlineTabList)") // Log offline tabs
            if self.authToken != nil { print("   - Found saved legacy auth token.") }
        }
    }
    
    // MARK: - Public Configuration (MANDATORY - Single Step)
    
    /// Configures the CMSCureSDK. **MUST be called once, early in your application lifecycle.**
    /// This single call provides all necessary credentials and triggers internal setup, including legacy authentication if needed.
    /// - Parameters:
    ///   - projectId: Your unique Project ID obtained from CMSCure.
    ///   - apiKey: Your secret API Key obtained from CMSCure (used in request headers).
    ///   - projectSecret: Your project secret (used for legacy encryption/handshake).
    ///   - serverUrlString: The base URL of your CMSCure backend API (e.g., "https://app.cmscure.com"). Must use HTTPS for production.
    ///   - socketIOURLString: The URL for the CMSCure Socket.IO server (e.g., "wss://app.cmscure.com"). Must use WSS for production.
    public func configure(
        projectId: String,
        apiKey: String,
        projectSecret: String, // <-- Added projectSecret here
        serverUrlString: String,
        socketIOURLString: String
    ) {
        // --- Input Validation ---
        guard !projectId.isEmpty else { logError("Configuration failed: Project ID cannot be empty."); return }
        guard !apiKey.isEmpty else { logError("Configuration failed: API Key cannot be empty."); return }
        guard !projectSecret.isEmpty else { logError("Configuration failed: Project Secret cannot be empty."); return } // Validate secret
        guard let serverUrl = URL(string: serverUrlString), let socketUrl = URL(string: socketIOURLString) else {
            logError("Configuration failed: Invalid URL format."); return
        }
#if !DEBUG
        guard serverUrl.scheme == "https" else { logError("Configuration failed: Server URL must use HTTPS in production builds."); return }
        guard socketUrl.scheme == "wss" else { logError("Configuration failed: Socket URL must use WSS in production builds."); return }
#endif
        
        // --- Create and Store Configuration Safely ---
        let newConfiguration = CureConfiguration(
            projectId: projectId,
            apiKey: apiKey,
            projectSecret: projectSecret, // Store secret in config
            serverUrl: serverUrl,
            socketIOURL: socketUrl
        )
        
        var alreadyConfigured = false
        configQueue.sync {
            if self.configuration != nil { alreadyConfigured = true }
            else { self.configuration = newConfiguration }
        }
        if alreadyConfigured { logError("Configuration failed: SDK already configured."); return }
        
        logDebug("CMSCureSDK Configured successfully for Project ID: \(projectId)")
        logDebug("   - API Base URL: \(serverUrl.absoluteString)")
        logDebug("   - Socket Base URL: \(socketUrl.absoluteString)")
        
        // --- Derive Legacy Symmetric Key Immediately (Thread-Safe) ---
        cacheQueue.async(flags: .barrier) { // Use barrier write for key derivation
            self.apiSecret = projectSecret // Assume same for key derivation
            if let secretData = projectSecret.data(using: .utf8) {
                self.symmetricKey = SymmetricKey(data: SHA256.hash(data: secretData))
                self.logDebug("🔑 Symmetric key derived from projectSecret.")
            } else { self.logError("⚠️ Failed to create data from projectSecret."); self.symmetricKey = nil }
        }
        
        // --- Trigger Internal Legacy Authentication & Connection ---
        // This now happens automatically after configuration
        _performLegacyAuthenticationAndConnect { success in
            if success {
                self.logDebug("Internal legacy authentication successful. SDK ready.")
                // Optional: Trigger initial sync immediately after successful auth/connect
                 self.syncIfOutdated()
            } else {
                self.logError("Internal legacy authentication failed. SDK might not be fully functional (e.g., socket, encrypted sync).")
            }
        }
    }
    
    /// Internal helper to safely get the current configuration details. Returns nil if not configured.
    internal func getCurrentConfiguration() -> CureConfiguration? {
        var currentConfig: CureConfiguration?
        configQueue.sync { // Read safely from the queue
            currentConfig = self.configuration
        }
        // Avoid logging error here, let callers handle nil config
        return currentConfig
    }
    
    // MARK: - Internal Legacy Authentication & Setup Flow
    
    /// Performs the legacy authentication call to the backend and initiates connections upon success.
    /// Called internally by `configure`.
    private func _performLegacyAuthenticationAndConnect(completion: @escaping (Bool) -> Void) {
        guard let config = getCurrentConfiguration() else {
            logError("_performLegacyAuthentication: SDK not configured.")
            completion(false); return
        }
        let projectId = config.projectId
        let apiKey = config.apiKey
        // projectSecret is available via config.projectSecret if needed elsewhere, but not for body encryption here
        
        logDebug("Attempting internal legacy authentication (unencrypted body)...") // Updated log
        
        // --- Create Request WITHOUT Body Encryption ---
        guard var urlComponents = URLComponents(url: config.serverUrl, resolvingAgainstBaseURL: false) else {
            logError("Legacy Auth failed: Invalid base URL."); completion(false); return
        }
        urlComponents.path = "/api/sdk/auth"
        urlComponents.queryItems = [URLQueryItem(name: "projectId", value: projectId)] // Keep query param if backend uses it
        guard let authUrl = urlComponents.url else {
            logError("Legacy Auth failed: Could not construct URL."); completion(false); return
        }
        
        // Create plain JSON body
        let bodyToSend: [String: String] = ["apiKey": apiKey, "projectId": projectId]
        var plainJsonBody: Data? = nil
        do {
            plainJsonBody = try JSONSerialization.data(withJSONObject: bodyToSend, options: [])
        } catch {
            logError("Legacy Auth failed: Failed to serialize plain JSON body: \(error)"); completion(false); return
        }
        
        // Manually construct request with PLAIN JSON body and API Key header
        var request = URLRequest(url: authUrl)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") // Still send API Key header
        request.httpBody = plainJsonBody // Set plain JSON body
        
        // REMOVE: No symmetricKey check needed here as we aren't encrypting the body
        // REMOVE: No call to self.encryptBody(...)
        
        logDebug("🔑 Sending internal legacy authenticate call (Plain JSON Body + API Key Header)...") // Updated log
        
        // --- Execute Request (Keep the rest of the logic same) ---
        URLSession.shared.dataTask(with: request) { data, response, error in
            // ... handle response ...
            // ... decode AuthResult_OriginalWithTabs ...
            // ... update cacheQueue with token/secret/tabs on success ...
            // ... call connectSocket() and syncIfOutdated() on success ...
            // ... call completion(Bool) ...
            guard let responseData = self.handleNetworkResponse(data: data, response: response, error: error, context: "internal legacy authenticating") else {
                DispatchQueue.main.async { completion(false) }; return
            }
            if responseData.isEmpty { /* ... handle error ... */
                self.logError("Legacy Auth failed: Received empty success response.")
                DispatchQueue.main.async { completion(false) }; return
            }
            guard let result = try? JSONDecoder().decode(AuthResult_OriginalWithTabs.self, from: responseData),
                  let receivedToken = result.token,
                  let receivedProjectId = result.projectId,
                  let receivedProjectSecret = result.projectSecret
            else { /* ... handle decoding error ... */
                self.logError("Legacy Auth failed: Decoding response failed. Raw: \(String(data: responseData, encoding: .utf8) ?? "nil")")
                DispatchQueue.main.async { completion(false) }; return
            }
            
            let receivedTabs = result.tabs ?? []
            let legacyConfigToPersist: [String: String] = [ /* ... create dict ... */
                "authToken": receivedToken,
                "projectSecret": receivedProjectSecret
            ]
            
            self.cacheQueue.async(flags: .barrier) { /* ... update state ... */
                self.authToken = receivedToken
                // Decide if you trust the received secret over the configured one
                // self.projectSecret = receivedProjectSecret // Maybe don't overwrite configured one
                self.knownProjectTabs = Set(receivedTabs)
                self.offlineTabList = Array(receivedTabs)
                let configSaved = self.saveLegacyConfigToDisk(legacyConfigToPersist)
                self.saveOfflineTabListToDisk()
                
                DispatchQueue.main.async { /* ... log success, trigger connect/sync ... */
                    if self.debugLogsEnabled { print("✅ Internal legacy authenticate successful. Token received. Known Tabs: \(receivedTabs)") }
                    // Trigger socket connection and initial sync AFTER successful auth
                    self.connectSocket() // Now this should run
                    self.syncIfOutdated()
                    completion(configSaved)
                }
            }
        }.resume()
    }
    
    // MARK: - Public Methods (Language, Cache, Accessors)
    
    /// Sets the current language, updates UserDefaults, and triggers UI/cache updates for all known tabs.
    /// Requires SDK to be configured first.
    public func setLanguage(_ language: String, force: Bool = false, completion: (() -> Void)? = nil) {
        guard getCurrentConfiguration() != nil else {
            logError("Cannot set language: SDK not configured.")
            completion?()
            return
        }
        
        var shouldUpdate = false
        var screensToUpdate: [String] = []
        
        // Check if update is needed and get tabs list (thread-safe read)
        cacheQueue.sync {
            if language != self.currentLanguage || force {
                shouldUpdate = true
                self.currentLanguage = language // Update language synchronously
                UserDefaults.standard.set(language, forKey: "selectedLanguage") // Persist preference
                // Get combined list of cached tabs and known offline tabs
                screensToUpdate = Array(Set(self.cache.keys).union(self.knownProjectTabs)) // Use knownProjectTabs Set
            }
        }
        
        guard shouldUpdate else { completion?(); return } // Exit if no update needed
        if self.debugLogsEnabled { print("🔄 Switching to language '\(language)'") }
        
        let group = DispatchGroup()
        for screenName in screensToUpdate {
            if self.debugLogsEnabled { print("🔄 Updating language for tab '\(screenName)'") }
            let cachedValues = self.getCachedTranslations(for: screenName, language: language) // Thread-safe read
            DispatchQueue.main.async { self.notifyUpdateHandlers(screenName: screenName, values: cachedValues) }
            group.enter()
            self.sync(screenName: screenName) { _ in group.leave() } // Sync in background
        }
        group.notify(queue: .main) { completion?() }
    }
    
    /// Gets the currently active language code. Thread-safe read.
    public func getLanguage() -> String {
        return cacheQueue.sync { self.currentLanguage }
    }
    
    
    
    // setLanguage, getLanguage, clearCache (ensure clearCache clears config)
    public func clearCache() {
        cacheQueue.async(flags: .barrier) { /* ... clear cache, list, secrets, files ... */
            self.cache.removeAll(); self.offlineTabList.removeAll(); self.knownProjectTabs.removeAll()
            self.authToken = nil; self.symmetricKey = nil; self.apiSecret = nil
            self.handshakeAcknowledged = false
            do {
                if FileManager.default.fileExists(atPath: self.cacheFilePath.path) { try FileManager.default.removeItem(at: self.cacheFilePath) }
                if FileManager.default.fileExists(atPath: self.tabsFilePath.path) { try FileManager.default.removeItem(at: self.tabsFilePath) }
                if FileManager.default.fileExists(atPath: self.configFilePath.path) { try FileManager.default.removeItem(at: self.configFilePath) }
            } catch { self.logError("Failed to delete cache/config files: \(error)") }
            DispatchQueue.main.async {
                for screenName in self.translationUpdateHandlers.keys { self.notifyUpdateHandlers(screenName: screenName, values: [:]) }
            }
        }
        configQueue.sync { self.configuration = nil } // Clear runtime config
        if self.debugLogsEnabled { print("🧹 Cache, Tabs List, Config files, and runtime configuration cleared.") }
        stopListening()
    }
    
    // MARK: - Core Translation & Color Access (Thread-safe Reads)
    
    /// Retrieves the translation for a given key and screen name in the current language. Returns empty string if not found. Thread-safe.
    public func translation(for key: String, inTab screenName: String) -> String {
        return cacheQueue.sync { // Synchronized read
            let lang = self.currentLanguage
            // Optimization: Check config existence? Maybe not needed here, return "" if cache miss.
            guard let tabCache = cache[screenName], let keyMap = tabCache[key], let translation = keyMap[lang] else {
                // Optional logging for missing translations
                // if debugLogsEnabled { print("⚠️ Translation missing: \(screenName)/\(key)/\(lang)") }
                return ""
            }
            return translation
        }
    }
    
    /// Retrieves the color hex string for a given global color key (from `__colors__` tab). Returns nil if not found. Thread-safe.
    public func colorValue(for key: String) -> String? {
        return cacheQueue.sync { // Synchronized read
            guard let colorTab = cache["__colors__"], let valueMap = colorTab[key], let colorHex = valueMap["color"] else {
                // Optional logging for missing colors
                // if debugLogsEnabled { print("⚠️ Color missing: \(key)") }
                return nil
            }
            return colorHex
        }
    }
    
    /// Retrieves the image URL for a given key and screen name in the current language. Returns nil if not found or invalid URL. Thread-safe.
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
            var values: [String: String] = [:]
            if let tabCache = self.cache[screenName] {
                for (key, valueMap) in tabCache { values[key] = valueMap[language] } // Get value for specific language
            };
            return values.compactMapValues { $0 } // Remove keys where value is nil for the language
        }
    }
    
    // MARK: - Internal Network Helpers
    
    /// Creates a configured URLRequest for SDK API calls, adding necessary headers like the API Key.
    /// MUST be called after the SDK has been configured.
    internal func createAuthenticatedRequest(
        endpointPath: String,
        appendProjectIdToPath: Bool = false,
        httpMethod: String = "GET",
        body: [String: Any]? = nil,
        useEncryption: Bool = false // Flag for legacy encryption
    ) -> URLRequest? {
        
        guard let config = getCurrentConfiguration() else {
            logError("Cannot create request: SDK not configured.")
            return nil
        }
        let projectId = config.projectId
        let apiKey = config.apiKey
        
        // Construct URL
        var urlComponents = URLComponents(url: config.serverUrl, resolvingAgainstBaseURL: false)
        urlComponents?.path = endpointPath
        if appendProjectIdToPath {
            var urlPath = urlComponents?.path ?? ""
            urlPath += (urlComponents?.path.hasSuffix("/") == true ? "" : "/") + projectId
            urlComponents?.path = urlPath
        }
        guard let url = urlComponents?.url else {
            logError("Cannot create request: Invalid URL components for path '\(endpointPath)'. Base: \(config.serverUrl)"); return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") // *** ADD API KEY HEADER ***
        
        // Handle Request Body (Plain JSON or Encrypted)
        var requestBodyData: Data? = nil
        if let body = body, (httpMethod == "POST" || httpMethod == "PUT" || httpMethod == "PATCH") {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if useEncryption {
                requestBodyData = cacheQueue.sync { self.encryptBody(body) } // Encrypt on cache queue
                if requestBodyData == nil { logError("Failed to encrypt body for \(endpointPath)."); return nil }
                // Add signature if required for encrypted requests (implement signature logic if needed)
                // let signature = cacheQueue.sync { ... generate signature ... }; if let sig = signature { request.setValue(sig, forHTTPHeaderField: "X-Signature") }
            } else {
                do { requestBodyData = try JSONSerialization.data(withJSONObject: body, options: []) }
                catch { logError("Failed to encode plain JSON body for \(endpointPath): \(error)"); return nil }
            }
        }
        request.httpBody = requestBodyData
        logDebug("Created Request: \(httpMethod) \(url.path)")
        return request
    }
    
    /// Handles common checks for URLSession responses. Returns Data on success, nil on error.
    internal func handleNetworkResponse(data: Data?, response: URLResponse?, error: Error?, context: String) -> Data? {
        if let error = error { logError("Network error \(context): \(error.localizedDescription)"); return nil }
        guard let httpResponse = response as? HTTPURLResponse else { logError("Invalid response received \(context)."); return nil }
        // Allow 404 as non-error for sync (means no translations found)
        if httpResponse.statusCode == 404 && context.contains("syncing") {
            if debugLogsEnabled { print("ℹ️ Sync info for \(context): Resource not found (404), treating as empty result.") }
            return Data() // Return empty data to indicate success but no content
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No body"
            logError("HTTP error \(context): \(httpResponse.statusCode). Body: \(responseBody)"); return nil
        }
        // Allow empty data for certain success responses (e.g., 204 No Content or 200 OK with no body)
        guard let responseData = data else {
            // Return empty Data instead of nil for 2xx responses without data
            return Data()
        }
        return responseData
    }
    
    // MARK: - Synchronization Logic
    
    /// Fetches the latest translations/colors for a specific screen name (tab).
    /// Requires SDK to be configured. Uses API Key header. Encryption optional via flag.
    public func sync(screenName: String, completion: @escaping (Bool) -> Void) {
        guard let config = getCurrentConfiguration() else {
            logError("Sync failed for '\(screenName)': SDK not configured.")
            DispatchQueue.main.async { completion(false) }; return
        }
        let projectId = config.projectId
        
        // --- Determine if Encryption Needed ---
        let shouldUseEncryption = true // TODO: Make configurable. Assumes legacy encryption for now.
        
        // --- Create Request ---
        guard let request = createAuthenticatedRequest(
            endpointPath: "/api/sdk/translations/\(projectId)/\(screenName)", // Path includes screenName
            appendProjectIdToPath: false, // ProjectID already in path
            httpMethod: "POST",
            body: ["projectId": projectId, "screenName": screenName],
            useEncryption: shouldUseEncryption
        ) else {
            logError("Failed to create request for sync ('\(screenName)').")
            DispatchQueue.main.async { completion(false) }; return
        }
        if debugLogsEnabled { print("🔄 Syncing '\(screenName)' (Encryption: \(shouldUseEncryption))...") }
        
        // --- Execute Request ---
        URLSession.shared.dataTask(with: request) { data, response, error in
            // --- Handle Response ---
            // NOTE: handleNetworkResponse now returns empty Data for 404/204/200-no-body
            guard let responseData = self.handleNetworkResponse(data: data, response: response, error: error, context: "syncing '\(screenName)'") else {
                DispatchQueue.main.async { completion(false) }; return
            }
            
            // --- Handle Empty Response (Success, No Data) ---
            if responseData.isEmpty {
                if self.debugLogsEnabled { print("ℹ️ Sync successful for '\(screenName)' but no new data/keys found.") }
                // If no keys were returned, potentially clear the cache for this tab? Or just leave it.
                // Decide if this scenario requires UI update notifications. Maybe not if values didn't change.
                DispatchQueue.main.async { completion(true) }
                return
            }
            
            // --- Parse JSON (Assumes UNENCRYPTED Response) ---
            // ADJUST DECRYPTION HERE if response for encrypted sync is also encrypted
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let keys = json["keys"] as? [[String: Any]] else {
                if self.debugLogsEnabled { print("❌ Sync failed for '\(screenName)': Failed to parse JSON response."); print("   Raw response:", String(data: responseData, encoding: .utf8) ?? "nil") }
                DispatchQueue.main.async { completion(false) }; return
            }
            // --- End JSON Parsing ---
            
            // --- Update Cache (Thread-Safe Write) ---
            self.cacheQueue.async(flags: .barrier) { // Barrier write for cache update
                // *** DEFINE VARIABLE HERE ***
                var updatedTabValuesForCurrentLang: [String: String] = [:]
                var newCacheForScreen: [String: [String: String]] = self.cache[screenName] ?? [:]
                let currentLang = self.currentLanguage // Read language inside queue
                
                for item in keys {
                    if let k = item["key"] as? String, let values = item["values"] as? [String: String] {
                        newCacheForScreen[k] = values
                        if let v = values[currentLang] { updatedTabValuesForCurrentLang[k] = v }
                    }
                }
                self.cache[screenName] = newCacheForScreen
                if !self.knownProjectTabs.contains(screenName) { // Update Set
                    self.knownProjectTabs.insert(screenName)
                    self.offlineTabList = Array(self.knownProjectTabs) // Update Array for persistence
                }
                
                self.saveCacheToDisk()
                self.saveOfflineTabListToDisk()
                
                DispatchQueue.main.async {
                    self.notifyUpdateHandlers(screenName: screenName, values: updatedTabValuesForCurrentLang)
                    if self.debugLogsEnabled { print("✅ Synced translations for \(screenName)") }
                    completion(true)
                }
            } // End cacheQueue async barrier
        }.resume()
    }
    
    /// Triggers sync for all known project tabs plus special tabs (__colors__).
    /// Requires SDK to be configured and potentially authenticated (if secrets needed for encryption).
    private func syncIfOutdated() {
        guard let config = getCurrentConfiguration() else {
            if debugLogsEnabled { print("ℹ️ Skipping syncIfOutdated: SDK not configured.") }
            return
        }
        
        // Determine if secrets are needed/available (only if encryption is required for sync)
        let syncRequiresEncryption = true // TODO: Make this check dynamic if needed
        var secretsAvailable = true // Assume available unless encryption is needed and secrets missing
        if syncRequiresEncryption {
            cacheQueue.sync { secretsAvailable = self.symmetricKey != nil }
        }
        guard secretsAvailable else {
            if debugLogsEnabled { print("ℹ️ Skipping syncIfOutdated: Missing secrets/keys required for encryption.") }
            return
        }
        
        // Get list of tabs to sync (combine cached and known tabs)
        let tabsToSync = cacheQueue.sync {
            Array(Set(self.cache.keys).union(self.knownProjectTabs)).filter { !$0.starts(with: "__") }
        }
        let specialTabs = ["__colors__"] // Sync colors tab
        
        let allTabs = tabsToSync + specialTabs
        if debugLogsEnabled && !allTabs.isEmpty {
            print("🔄 Syncing tabs on app active/poll: \(allTabs.joined(separator: ", "))")
        } else if debugLogsEnabled {
            print("ℹ️ No tabs identified for sync.")
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
    
    // MARK: - Socket Communication (Legacy Handshake Method)
    
    /// Establishes connection with the Socket.IO server. Requires SDK to be configured.
    public func connectSocket() {
        guard let config = getCurrentConfiguration() else {
            logError("Cannot connect socket: SDK not configured.")
            return
        }
        let projectId = config.projectId
        let socketUrl = config.socketIOURL // Use configured URL
        
        DispatchQueue.main.async { // Socket operations often best on main thread
            let currentStatus = self.manager?.status ?? .notConnected
            guard currentStatus != .connected && currentStatus != .connecting else {
                if self.debugLogsEnabled { print("⚠️ Socket already connected or connecting.") }
                if currentStatus == .connected && !self.handshakeAcknowledged { self.sendHandshake(projectId: projectId) }
                return
            }
            
            let socketConfig: SocketIOClientConfiguration = [
                .log(self.debugLogsEnabled), .compress, .reconnects(true), .reconnectAttempts(-1),
                .reconnectWait(3), .reconnectWaitMax(10), .forceWebsockets(true)
            ]
            
            self.manager?.disconnect() // Disconnect old one if exists
            if self.debugLogsEnabled { print("🔌 Creating new SocketManager for \(socketUrl)...") }
            self.manager = SocketManager(socketURL: socketUrl, config: socketConfig)
            
            guard let currentManager = self.manager else { self.logError("Failed to create SocketManager."); return }
            
            self.socket = currentManager.defaultSocket
            if self.debugLogsEnabled { print("🔌 Attempting socket connect()...") }
            self.setupSocketHandlers(projectId: projectId) // Attach event handlers
            self.socket?.connect() // Initiate connection
        }
    }
    
    /// Sets up the event handlers (listeners) for the Socket.IO client.
    private func setupSocketHandlers(projectId: String) {
        guard let currentSocket = socket else { logError("setupSocketHandlers: Socket instance is nil."); return }
        if debugLogsEnabled { print("👂 Setting up socket handlers for socket ID: \(currentSocket.sid ?? "N/A") (nsp: \(currentSocket.nsp))") }
        
        currentSocket.off(clientEvent: .connect)
        currentSocket.off("handshake_ack")
        currentSocket.off("translationsUpdated")
        currentSocket.off(clientEvent: .disconnect)
        currentSocket.off(clientEvent: .error)
        currentSocket.off(clientEvent: .reconnect)
        currentSocket.off(clientEvent: .reconnectAttempt)
        currentSocket.off(clientEvent: .statusChange)
        
        currentSocket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("🟢✅ Socket connect handler fired! SID: \(self.socket?.sid ?? "N/A")") }
            self.cacheQueue.async { self.handshakeAcknowledged = false } // Reset handshake status
            self.sendHandshake(projectId: projectId) // Send legacy handshake
        }
        
        currentSocket.on("handshake_ack") { [weak self] _, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("🤝 Handshake acknowledged by server.") }
            self.cacheQueue.async { self.handshakeAcknowledged = true } // Mark handshake as successful
            self.syncIfOutdated() // Trigger sync after handshake
        }
        
        currentSocket.on("translationsUpdated") { [weak self] data, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("📡 Socket update received: \(data)") }
            self.handleSocketTranslationUpdate(data: data)
        }
        
        currentSocket.on(clientEvent: .disconnect) { [weak self] data, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("🔌 Socket disconnected. Reason: \(data)") }
            self.cacheQueue.async { self.handshakeAcknowledged = false } // Reset handshake status
        }
        
        currentSocket.on(clientEvent: .error) { [weak self] data, _ in
            guard let self = self else { return }
            if let error = data.first as? Error { self.logError("Socket error: \(error.localizedDescription)") }
            else { self.logError("Socket error: \(data)") }
        }
        
        currentSocket.on(clientEvent: .reconnect) { [weak self] data, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("🔁 Socket reconnected. Data: \(data)") }
            // Connect handler will fire again, triggering handshake.
        }
        
        currentSocket.on(clientEvent: .reconnectAttempt) { [weak self] data, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("🔁 Attempting socket reconnect... \(data)") }
            // Consider resetting handshake status if needed
        }
        
        currentSocket.on(clientEvent: .statusChange) { [weak self] data, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("ℹ️ Socket status changed: \(self.socket?.status.description ?? "Unknown")") }
        }
        
        if debugLogsEnabled { print("👂✅ Socket handlers setup complete.") }
    }
    
    /// Sends the encrypted handshake message to the server using projectSecret (Legacy).
    private func sendHandshake(projectId: String) {
        var secretToSend: String?
        cacheQueue.sync { secretToSend = configuration?.projectSecret } // Read secret safely
        
        guard let secret = secretToSend, !secret.isEmpty else {
            if debugLogsEnabled { print("❌ Cannot send handshake: Project secret not set/available.") }
            return
        }
        
        // Encrypt payload using legacy method
        let encryptedPayload = cacheQueue.sync { () -> Data? in
            guard let secretData = secret.data(using: .utf8) else { return nil }
            let handshakeKey = SymmetricKey(data: SHA256.hash(data: secretData)) // Derive key
            let body = ["projectId": projectId] // Payload
            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            do {
                let sealedBox = try AES.GCM.seal(jsonData, using: handshakeKey)
                let result: [String: String] = [ // Structure expected by backend
                    "iv": sealedBox.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
                    "ciphertext": sealedBox.ciphertext.base64EncodedString(),
                    "tag": sealedBox.tag.base64EncodedString()
                ]
                return try JSONSerialization.data(withJSONObject: result)
            } catch { self.logError("Handshake encryption failed: \(error)"); return nil }
        }
        
        guard let encryptedData = encryptedPayload,
              var sealedDict = try? JSONSerialization.jsonObject(with: encryptedData, options: []) as? [String: Any] else { // Make mutable
            if self.debugLogsEnabled { print("❌ Failed to serialize encrypted handshake payload.") }; return
        }
        // Add plain projectId if backend expects it alongside encrypted data
        sealedDict["projectId"] = projectId
        
        if self.debugLogsEnabled { print("🤝 Sending legacy handshake...") }
        DispatchQueue.main.async { self.socket?.emit("handshake", sealedDict) } // Emit from main thread
    }
    
    /// Handles incoming 'translationsUpdated' events from the socket.
    private func handleSocketTranslationUpdate(data: [Any]) {
        guard let dict = data.first as? [String: Any], let screenName = dict["screenName"] as? String else {
            if self.debugLogsEnabled { print("⚠️ Invalid socket data format for translationsUpdated: \(data)") }; return
        }
        if self.debugLogsEnabled { print("📡 Processing socket update for tab: \(screenName)") }
        if screenName == "__ALL__" { self.syncIfOutdated() }
        else { self.sync(screenName: screenName) { _ in } } // Sync specific tab
    }
    
    /// Attempts connection if config exists. Called by app lifecycle events or after configure.
    public func startListening() {
        // Check if SDK is configured (has URLs, projectId, projectSecret)
        guard let config = getCurrentConfiguration() else {
            if debugLogsEnabled { print("ℹ️ startListening: SDK not configured, connection deferred.") }
            return
        }
        // Also ensure projectSecret needed for handshake is available (should be in config now)
        guard !config.projectSecret.isEmpty else {
            if debugLogsEnabled { print("ℹ️ startListening: Project Secret missing in config, cannot connect socket for legacy handshake.") }
            return
        }
        
        // Config exists, proceed with connection attempt
        logDebug("startListening: Configuration present, attempting socket connection...")
        connectSocket() // Calls connectSocket which uses config.socketIOURL and config.projectSecret for handshake
    }
    
    /// Disconnects the socket.
    public func stopListening() {
        DispatchQueue.main.async { // Ensure socket ops on main thread
            self.manager?.disconnect()
            self.socket = nil // Release socket instance
            self.manager = nil // Release manager instance
            self.cacheQueue.async { self.handshakeAcknowledged = false } // Reset status
            if self.debugLogsEnabled { print("🔌 Socket disconnect requested and resources released.") }
        }
    }
    
    /// Checks if the socket is currently connected.
    public func isConnected() -> Bool {
        // Access manager status on main thread for safety if needed, or ensure manager access is synchronized
        var status: SocketIOStatus = .notConnected
        DispatchQueue.main.sync { // Synchronous check if called from background thread
            status = manager?.status ?? .notConnected
        }
        return status == .connected
    }
    
    // MARK: - Persistence (Cache, Tabs & Legacy Config) - Thread-safe implementations
    
    /// Saves the current in-memory cache to `cache.json`. Assumes running within `cacheQueue`.
    private func saveCacheToDisk() {
        let cacheToSave = self.cache
        do { try JSONEncoder().encode(cacheToSave).write(to: self.cacheFilePath, options: .atomic) }
        catch { logError("Failed to save cache: \(error)") }
    }
    
    /// Loads the cache from `cache.json` during initialization. Populates cache and offlineTabList.
    private func loadCacheFromDisk() {
        guard FileManager.default.fileExists(atPath: self.cacheFilePath.path) else { return }
        do {
            let data = try Data(contentsOf: self.cacheFilePath)
            if let loadedCache = try? JSONDecoder().decode([String: [String: [String: String]]].self, from: data) {
                self.cache = loadedCache
            } else { if debugLogsEnabled { print("⚠️ Failed to decode cache file, removing.") }; try? FileManager.default.removeItem(at: self.cacheFilePath) }
            loadOfflineTabListFromDisk() // Load tabs after cache
        } catch { if debugLogsEnabled { print("❌ Failed to load cache file, removing. Error: \(error)") }; try? FileManager.default.removeItem(at: self.cacheFilePath) }
    }
    
    /// Saves the list of known project tabs to `tabs.json`. Assumes running within `cacheQueue`.
    private func saveOfflineTabListToDisk() {
        let listToSave = self.offlineTabList
        do { try JSONEncoder().encode(listToSave).write(to: self.tabsFilePath, options: .atomic) }
        catch { logError("Failed to save known tabs list: \(error)") }
    }
    
    /// Loads the list of known project tabs from `tabs.json`. Updates `offlineTabList` and `knownProjectTabs`.
    private func loadOfflineTabListFromDisk() {
        guard FileManager.default.fileExists(atPath: self.tabsFilePath.path) else { return }
        do {
            let data = try Data(contentsOf: self.tabsFilePath)
            self.offlineTabList = try JSONDecoder().decode([String].self, from: data)
            self.knownProjectTabs = Set(self.offlineTabList) // Sync Set with loaded Array
            if debugLogsEnabled { print("📦 Loaded offline tab list: \(self.offlineTabList)") }
        } catch { if debugLogsEnabled { print("❌ Failed to load known tabs list, removing. Error: \(error)") }; try? FileManager.default.removeItem(at: self.tabsFilePath) }
    }
    
    /// Saves the legacy authentication configuration (token, secret) to `config.json`. Assumes running within `cacheQueue`.
    private func saveLegacyConfigToDisk(_ config: [String: String]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: configFilePath.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let jsonData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
            try jsonData.write(to: self.configFilePath, options: .atomic)
            if self.debugLogsEnabled { print("💾 Saved legacy config (token/secret) to \(configFilePath.lastPathComponent)") }
            return true
        } catch { logError("Failed to save legacy config: \(error)"); return false }
    }
    
    /// Reads the legacy authentication configuration (token, secret) from `config.json`.
    private func readLegacyConfigFromDisk() -> [String: String]? {
        guard FileManager.default.fileExists(atPath: configFilePath.path),
              let data = try? Data(contentsOf: configFilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return json
    }
    
    // MARK: - Background Handling & Polling
    
    private func observeAppActiveNotification() {
#if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
#endif
    }
    @objc private func appDidBecomeActive() {
        if self.debugLogsEnabled { print("📲 App became active — checking socket status & content.") }
        startListening() // Checks config and connects if needed
        syncIfOutdated() // Checks secrets/config and syncs if needed
    }
    private func setupPollingTimer() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in guard let self = self else { return }; if self.debugLogsEnabled { print("⏰ Polling timer fired — syncing content.") }; self.syncIfOutdated() }
        if debugLogsEnabled { print("⏱️ Polling timer setup with interval: \(pollingInterval) seconds.") }
    }
    
    // MARK: - Encryption Helper (Legacy)
    
    /// Encrypts the request body using AES.GCM with the derived symmetric key.
    /// MUST be called from within `cacheQueue` to safely access `symmetricKey`.
    private func encryptBody(_ body: [String: Any]) -> Data? {
        guard let symmetricKey = self.symmetricKey else { logError("Encryption failed: Symmetric key not set."); return nil }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { logError("Encryption failed: Could not serialize body."); return nil }
        do {
            let sealedBox = try AES.GCM.seal(jsonData, using: symmetricKey)
            let result: [String: String] = [ // Structure expected by legacy backend
                "iv": sealedBox.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
                "ciphertext": sealedBox.ciphertext.base64EncodedString(),
                "tag": sealedBox.tag.base64EncodedString()
            ]
            return try JSONSerialization.data(withJSONObject: result)
        } catch { logError("Encryption failed: AES.GCM sealing error - \(error)"); return nil }
    }
    
    // MARK: - Update Handling & Notifications
    
    public func onTranslationsUpdated(for screenName: String, handler: @escaping ([String: String]) -> Void) {
        DispatchQueue.main.async { // Ensure handler registration and initial call are on main thread
            self.translationUpdateHandlers[screenName] = handler
            // Provide initial cached values immediately if available
            let currentValues = self.getCachedTranslations(for: screenName, language: self.getLanguage())
            if !currentValues.isEmpty || self.isTabSynced(screenName) { // Check if tab ever synced or has values
                handler(currentValues)
            }
        }
    }
    private func postTranslationsUpdatedNotification(screenName: String) {
        assert(Thread.isMainThread, "Must be called on the main thread")
        let newUUID = UUID(); if debugLogsEnabled { print("📬 Posting update notification for '\(screenName)'. New Refresh Token: \(newUUID)") }
        CureTranslationBridge.shared.refreshToken = newUUID // Trigger SwiftUI updates
        NotificationCenter.default.post(name: .translationsUpdated, object: nil, userInfo: ["screenName": screenName])
    }
    private func notifyUpdateHandlers(screenName: String, values: [String: String]) {
        assert(Thread.isMainThread, "Must be called on the main thread")
        if debugLogsEnabled { print("📬 Notifying handlers for '\(screenName)'. Values count: \(values.count)") }
        self.translationUpdateHandlers[screenName]?(values) // Call specific handler
        self.postTranslationsUpdatedNotification(screenName: screenName) // Post general notification
    }
    
    
    // MARK: - Language List Fetching (Now uses API Key Header)
    
    /// Fetches the list of available languages from the server. Uses API Key header, no encryption.
    /// Requires SDK to be configured.
    public func availableLanguages(completion: @escaping ([String]) -> Void) {
        guard let config = getCurrentConfiguration() else {
            logError("Cannot fetch availableLanguages: SDK not configured.")
            DispatchQueue.main.async { completion([]) }; return
        }
        let projectId = config.projectId
        
        // Create request - NO ENCRYPTION
        guard let request = createAuthenticatedRequest(
            endpointPath: "/api/sdk/languages", // Path before projectId
            appendProjectIdToPath: true,         // Append projectId to path
            httpMethod: "POST",                  // Assuming POST
            body: ["projectId": projectId],      // Example body
            useEncryption: false                 // IMPORTANT: No encryption
        ) else {
            logError("Failed to create request for availableLanguages."); DispatchQueue.main.async { completion([]) }; return
        }
        
        // Execute request
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let responseData = self.handleNetworkResponse(data: data, response: response, error: error, context: "fetching languages") else {
                self.fallbackToCachedLanguages(completion: completion); return
            }
            // Handle empty success response
            if responseData.isEmpty {
                if self.debugLogsEnabled { print("ℹ️ Received empty success response for availableLanguages.") }
                DispatchQueue.main.async { completion([]) }; return
            }
            // Decode JSON { "languages": [...] }
            do {
                struct LanguagesResponse: Decodable { let languages: [String] }
                let decodedResponse = try JSONDecoder().decode(LanguagesResponse.self, from: responseData)
                DispatchQueue.main.async { completion(decodedResponse.languages) }
            } catch {
                self.logError("Failed to decode languages response: \(error). Data: \(String(data: responseData, encoding: .utf8) ?? "nil")")
                self.fallbackToCachedLanguages(completion: completion)
            }
        }.resume()
    }
    
    /// Provides cached languages as a fallback if fetching from server fails. Thread-safe read.
    private func fallbackToCachedLanguages(completion: @escaping ([String]) -> Void) {
        let cachedLangs = cacheQueue.sync { () -> [String] in
            var allLangs: Set<String> = []
            for (_, tabValues) in self.cache { for (_, langMap) in tabValues { allLangs.formUnion(langMap.keys) } }
            allLangs.remove("color") // Exclude special key if present
            return Array(allLangs).sorted()
        }
        DispatchQueue.main.async {
            if !cachedLangs.isEmpty { if self.debugLogsEnabled { print("⚠️ Using cached languages as fallback: \(cachedLangs)") } }
            completion(cachedLangs) // Return cached or empty array
        }
    }
    
    // MARK: - Utility & Logging
    
    /// Checks if a specific tab has any data in the cache. Thread-safe.
    public func isTabSynced(_ tab: String) -> Bool {
        return cacheQueue.sync { !(cache[tab]?.isEmpty ?? true) }
    }
    
    /// Internal logging helper for errors.
    internal func logError(_ message: String) { print("🆘 [CMSCureSDK Error] \(message)") }
    /// Internal logging helper for debug messages (only prints in DEBUG builds).
    internal func logDebug(_ message: String) {
#if DEBUG
        print("🛠️ [CMSCureSDK Debug] \(message)");
#endif
    }
    
    /// Helper struct for decoding authentication result (Legacy Flow).
    private struct AuthResult_OriginalWithTabs: Decodable {
        let token: String?
        let userId: String? // Keep if needed, otherwise remove
        let projectId: String?
        let projectSecret: String?
        let tabs: [String]? // Expect tabs array
    }
    
    /// Clean up resources when SDK instance is deallocated.
    deinit {
        NotificationCenter.default.removeObserver(self)
        pollingTimer?.invalidate()
        stopListening() // Disconnect socket and release resources
        if debugLogsEnabled { print("✨ CMSCureSDK Deinitialized.") }
    }
}

// MARK: - SwiftUI Color Extension
extension Color {
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
    public static let translationsUpdated = Notification.Name("CMSCureTranslationsUpdated")
}
// MARK: - Error Enum
enum CMSCureSDKError: Error {
    case notConfigured
    case missingTokenOrProjectId
    case invalidResponse
    case decodingFailed
    case syncFailed(String)
    case socketDisconnected
    case encryptionFailed
    case configurationError(String)
    case authenticationFailed
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
}
// MARK: - String Extension for Convenience
extension String {
    private var bridgeWatcher: UUID { CureTranslationBridge.shared.refreshToken }
    public func cure(tab: String) -> String {
        _ = bridgeWatcher
        return Cure.shared.translation(for: self, inTab: tab)
    }
}
// MARK: - Observable Objects for SwiftUI
final class CureTranslationBridge: ObservableObject {
    static let shared = CureTranslationBridge()
    @Published var refreshToken = UUID()
    private init() {}
}
public final class CureString: ObservableObject {
    private let key: String; private let tab: String; private var cancellable: AnyCancellable? = nil
    @Published public private(set) var value: String = ""
    public init(_ key: String, tab: String) {
        self.key = key; self.tab = tab; self.value = Cure.shared.translation(for: key, inTab: tab)
        cancellable = CureTranslationBridge.shared.$refreshToken.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateValue() }
    }
    private func updateValue() { let newValue = Cure.shared.translation(for: key, inTab: tab); if newValue != self.value { self.value = newValue } }
}
public final class CureColor: ObservableObject {
    private let key: String; private var cancellable: AnyCancellable? = nil
    @Published public private(set) var value: Color?
    public init(_ key: String) {
        self.key = key; self.value = Color(hex: Cure.shared.colorValue(for: key))
        cancellable = CureTranslationBridge.shared.$refreshToken.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateValue() }
    }
    private func updateValue() { let newValue = Color(hex: Cure.shared.colorValue(for: key)); if newValue != self.value { self.value = newValue } }
}
public final class CureImage: ObservableObject {
    private let key: String; private let tab: String; private var cancellable: AnyCancellable? = nil
    @Published public private(set) var value: URL?
    public init(_ key: String, tab: String) {
        self.key = key; self.tab = tab; self.value = Cure.shared.imageUrl(for: key, inTab: tab)
        cancellable = CureTranslationBridge.shared.$refreshToken.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateValue() }
    }
    private func updateValue() { let newValue = Cure.shared.imageUrl(for: key, inTab: tab); if newValue != self.value { self.value = newValue } }
}
// MARK: - SocketIOStatus Extension
extension SocketIOStatus {
    var description: String {
        switch self {
        case .notConnected: return "Not Connected"; case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"; case .connected: return "Connected"
        }
    }
}
