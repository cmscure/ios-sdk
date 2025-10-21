// Updated SDK

// Standard Library & System Frameworks
import Foundation
#if canImport(UIKit)
import UIKit // For app lifecycle notifications (UIApplication.didBecomeActiveNotification)
#endif

// Third-Party Frameworks
import SocketIO // For real-time communication via WebSockets
import CryptoKit // For cryptographic operations like hashing (SHA256) and encryption (AES.GCM)
import Combine // For reactive programming patterns, particularly for SwiftUI integration
import SwiftUI // For UI-related types like Color and ObservableObject helpers
import Kingfisher

// MARK: - Public Typealiases

/// Provides a convenient shorthand for accessing the `CMSCureSDK` singleton.
///
/// Usage:
/// ```swift
/// Cure.shared.setLanguage("fr")
/// let title = "home_title".cure(tab: "general_ui")
/// ```
public typealias Cure = CMSCureSDK

// MARK: - CMSCureSDK Class Definition

/// The primary class for interacting with the CMSCure backend.
///
/// This singleton class manages content synchronization, language settings, real-time updates via Socket.IO,
/// and provides access to translations, colors, and image URLs managed within the CMS.
///
/// **Key Responsibilities:**
/// - Configuration: Must be configured once with project-specific credentials.
/// - Authentication: Handles authentication with the backend.
/// - Data Caching: Stores fetched content (translations, colors) in an in-memory cache with disk persistence.
/// - Synchronization: Fetches content updates via API calls and real-time socket events.
/// - Language Management: Allows setting and retrieving the active language for content.
/// - Socket Communication: Manages a WebSocket connection for receiving live updates.
/// - Thread Safety: Uses dispatch queues to ensure thread-safe access to shared resources.
/// - SwiftUI Integration: Provides observable objects and helpers for easy use in SwiftUI views.
public class CMSCureSDK {
    // MARK: - Singleton Instance
    
    /// The shared singleton instance of the `CMSCureSDK`.
    /// Use this instance to access all SDK functionalities.
    public static let shared = CMSCureSDK()
    
    // MARK: - Core Configuration & State
    
    /// Defines the structure for holding essential SDK configuration parameters.
    /// This configuration is provided once via the `configure()` method.
    public struct CureConfiguration {
        let projectId: String       /// The unique identifier for your project in CMSCure.
        let apiKey: String          /// The API key used for authenticating requests with the CMSCure backend.
        let projectSecret: String   /// The secret key associated with your project, used for legacy encryption and handshake validation.
        let enableAutoRealTimeUpdates: Bool /// Whether to automatically enable real-time updates for screens accessed via translation() method. Default: true
        
        /// Convenience initializer with auto real-time updates enabled by default
        public init(projectId: String, apiKey: String, projectSecret: String, enableAutoRealTimeUpdates: Bool = true) {
            self.projectId = projectId
            self.apiKey = apiKey
            self.projectSecret = projectSecret
            self.enableAutoRealTimeUpdates = enableAutoRealTimeUpdates
        }
    }
    
    /// Holds the active SDK configuration. This is `nil` until `configure()` is successfully called.
    /// Access to this property is thread-safe via `configQueue`.
    private var configuration: CureConfiguration?
    
    /// A serial dispatch queue to ensure thread-safe read and write access to the `configuration` property.
    private let configQueue = DispatchQueue(label: "com.cmscuresdk.configqueue")
    
    // MARK: - Internal Credentials & Tokens
    // These are managed internally by the SDK, primarily related to legacy authentication or session management.
    // Access to these properties is thread-safe via `cacheQueue`.
    
    /// The API secret, often the same as `projectSecret`, used specifically for deriving the encryption key in legacy flows.
    private var apiSecret: String? = nil
    /// The symmetric key derived from `projectSecret` or `apiSecret`, used for AES.GCM encryption/decryption in legacy flows.
    private var symmetricKey: SymmetricKey? = nil
    /// An authentication token received from the backend, potentially after a successful legacy authentication.
    private var authToken: String? = nil // TODO: Review if this is still actively used or if API Key is sufficient.
    
    // MARK: - Content & Cache State
    // Access to these properties is thread-safe via `cacheQueue`.
    
    /// A set of known "tab" or "screen" names associated with the project, loaded from disk or updated via sync/auth.
    private var knownProjectTabs: Set<String> = []
    private var knownDataStoreIdentifiers: Set<String> = []
    /// An array representation of `knownProjectTabs`, used for persistence to disk.
    private var offlineTabList: [String] = []
    private var offlineDataStoreList: [String] = []
    
    /// The in-memory cache for storing translations and color data.
    /// Structure: `[ScreenName: [Key: [LanguageCode: Value]]]`
    /// For colors (typically under `__colors__` screenName), the LanguageCode might be a generic identifier like "color".
    private var cache: [String: [String: [String: String]]] = [:]
    private var dataStoreCache: [String: [DataStoreItem]] = [:]
    
    /// The currently active language code (e.g., "en", "fr") for retrieving translations.
    /// Defaults to "en". Persisted in `UserDefaults`.
    private var currentLanguage: String = "en"
    
    /// List of available languages for the project, received during authentication.
    /// Defaults to ["en"] and is updated from the authentication response.
    private var availableLanguagesList: [String] = ["en"]
    
    // MARK: - SDK Settings
    
    /// A flag to enable or disable verbose debug logging to the console.
    /// Default is `true`. Set to `false` for production releases to reduce console noise.
    public var debugLogsEnabled: Bool = true
    
    /// A dictionary mapping screen names (tabs) to their respective update handlers.
    /// These handlers are called when translations for a screen are updated.
    private var translationUpdateHandlers: [String: ([String: String]) -> Void] = [:]

    /// Handlers managed internally by the SDK to support automatic updates.
    /// Stored separately so integrator-provided handlers are not overridden.
    private var internalTranslationUpdateHandlers: [String: ([String: String]) -> Void] = [:]
    
    /// Auto-subscription tracking: Keeps track of screens accessed via translation() method.
    /// This enables automatic real-time updates for screens that are actively being used.
    private var autoSubscribedScreens: Set<String> = []
    
    /// Auto-subscription tracking for colors: Keeps track when colorValue() is called.
    /// This enables automatic real-time updates for colors that are actively being used.
    private var autoSubscribedColors: Bool = false
    
    /// Auto-subscription tracking for global images: Keeps track when imageURL() is called.
    /// This enables automatic real-time updates for global images that are actively being used.
    private var autoSubscribedGlobalImages: Bool = false
    
    /// Auto-subscription tracking for data stores: Keeps track of stores accessed via getStoreItems().
    /// This enables automatic real-time updates for data stores that are actively being used.
    private var autoSubscribedDataStores: Set<String> = []
    
    /// Cache for the last returned values per key/screen combination.
    /// This prevents unnecessary notifications when values haven't actually changed.
    private var lastReturnedValues: [String: [String: String]] = [:] // [screenName: [key: lastValue]]
    
    private var syncingScreens: Set<String> = []
    
    private var autoRegisteredScreens: Set<String> = []

#if canImport(UIKit) && !os(watchOS)
    private let legacyUIKitContentUpdateSelector = NSSelectorFromString("cmsContentDidUpdate")
#endif
    
    // MARK: - Persistence File Paths
    // URLs for storing SDK data (cache, tabs, legacy config) in the app's Documents directory.
    
    private func getSdkDirectory() -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var sdkDirectory = baseDirectory.appendingPathComponent("CMSCureSDK", isDirectory: true)
        
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        
        do {
            try fileManager.createDirectory(at: sdkDirectory, withIntermediateDirectories: true)
            try sdkDirectory.setResourceValues(resourceValues)
        } catch {
            logError("Failed to prepare CMSCureSDK cache directory: \(error)")
        }
        
        return sdkDirectory
    }
    
    private lazy var cacheFilePath: URL = getSdkDirectory().appendingPathComponent("cache.json")
    private lazy var tabsFilePath: URL = getSdkDirectory().appendingPathComponent("tabs.json")
    private lazy var configFilePath: URL = getSdkDirectory().appendingPathComponent("config.json")
    private lazy var dataStoreCacheFilePath: URL = getSdkDirectory().appendingPathComponent("dataStoreCache.json")
    private lazy var dataStoreListFilePath: URL = getSdkDirectory().appendingPathComponent("dataStoreList.json")
    
    // MARK: - Synchronization & Networking
    
    /// A serial dispatch queue to manage thread-safe access to shared mutable state
    /// such as `cache`, `authToken`, `apiSecret`, `symmetricKey`, `knownProjectTabs`, `offlineTabList`, and `handshakeAcknowledged`.
    private let cacheQueue = DispatchQueue(label: "com.cmscure.cacheQueue") // Serial by default
    
    /// The Socket.IO client instance used for real-time communication.
    private var socket: SocketIOClient?
    /// The manager for the Socket.IO client, responsible for connection and configuration.
    private var manager: SocketManager?
    
    
    
    /// A flag indicating whether the legacy Socket.IO handshake has been acknowledged by the server.
    /// Accessed via `cacheQueue`.
    private var handshakeAcknowledged = false
    
    /// Timestamp of the last successful full sync operation.
    private var lastSyncCheck: Date? // TODO: Implement logic to use this for optimizing syncIfOutdated.
    
    private let serverUrlString: String = "https://gateway.cmscure.com" // Default server URL
    private let socketIOURLString: String = "wss://app.cmscure.com"  // Default Socket.IO URL
    
    private var serverURL: URL!
    private var socketIOUrl: URL!
    
    
    // MARK: - Initialization
    
    /// Private initializer to enforce the singleton pattern.
    /// This loads any persisted state from disk (cache, tabs, language preference, legacy config).
    ///
    /// **Important:** The SDK is not fully operational after `init()`. The `configure()` method
    /// **MUST** be called to provide necessary credentials and URLs.
    private init() {
        // Safely initialize URLs with fallbacks
        if let serverUrl = URL(string: serverUrlString) {
            self.serverURL = serverUrl
        } else {
            print("🆘 [CMSCureSDK Error] Invalid server URL: \(serverUrlString). Using fallback.")
            self.serverURL = URL(string: "https://app.cmscure.com")! // Fallback URL
        }
        
        if let socketUrl = URL(string: socketIOURLString) {
            self.socketIOUrl = socketUrl
        } else {
            print("🆘 [CMSCureSDK Error] Invalid socket URL: \(socketIOURLString). Using fallback.")
            self.socketIOUrl = URL(string: "wss://app.cmscure.com")! // Fallback URL
        }
        
        // Safe disk loading with error handling
        do {
            loadCacheFromDisk()
            loadDataStoreCacheFromDisk()
            loadOfflineTabListFromDisk()
            loadDataStoreListFromDisk()
        } catch {
            print("🆘 [CMSCureSDK Error] Failed to load cached data: \(error). Starting with clean state.")
        }
        
        self.currentLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en"
        
        do {
            if let savedLegacyConfig = readLegacyConfigFromDisk() {
                cacheQueue.sync { self.authToken = savedLegacyConfig["authToken"] }
            }
        } catch {
            print("🆘 [CMSCureSDK Error] Failed to load legacy config: \(error). Continuing without cached auth token.")
        }
        
        DispatchQueue.main.async {
            self.observeAppActiveNotification()
        }
        
        if debugLogsEnabled {
            print("🚀 CMSCureSDK Initialized. **Waiting for configure() call.**")
        }
    }
    
    // MARK: - Public Configuration
    
    /// Configures the CMSCureSDK with necessary project credentials and server details.
    ///
    /// This method **MUST** be called once, typically early in your application's lifecycle (e.g., in `AppDelegate` or `SceneDelegate`),
    /// before any other SDK functionality is used.
    ///
    /// Calling this method multiple times will result in an error, and subsequent calls will be ignored.
    ///
    /// Upon successful configuration, the SDK will:
    /// 1. Store the provided configuration.
    /// 2. Derive cryptographic keys if needed for legacy encryption.
    /// 3. Attempt a legacy authentication flow with the backend.
    /// 4. If authentication is successful, establish a Socket.IO connection for real-time updates.
    /// 5. Trigger an initial content sync.
    ///
    /// - Parameters:
    ///   - projectId: Your unique Project ID from the CMSCure dashboard.
    ///   - apiKey: Your secret API Key from the CMSCure dashboard, used for authenticating API requests.
    ///   - projectSecret: Your Project Secret from the CMSCure dashboard, used for legacy encryption and socket handshake.
    ///   - enableAutoRealTimeUpdates: Whether to automatically enable real-time updates for screens accessed via translation() method.
    ///                                 When enabled, calling translation() automatically subscribes to real-time updates for that screen.
    ///                                 Defaults to `true` for enhanced developer experience. Set to `false` for traditional behavior.
    public func configure(projectId: String, apiKey: String, projectSecret: String, enableAutoRealTimeUpdates: Bool = true) {
        print("🚀 [CMSCureSDK] Configure method called - entry point reached")
        
        // Ensure configuration parameters are valid.
        guard !projectId.isEmpty else { logError("Configuration failed: Project ID cannot be empty."); return }
        guard !apiKey.isEmpty else { logError("Configuration failed: API Key cannot be empty."); return }
        guard !projectSecret.isEmpty else { logError("Configuration failed: Project Secret cannot be empty."); return }
        
        if debugLogsEnabled {
            print("🚀 [CMSCureSDK] Starting configuration...")
            print("📋 [CMSCureSDK] Project ID: \(projectId)")
            print("🔑 [CMSCureSDK] API Key: \(String(apiKey.prefix(8)))...")
            print("🔒 [CMSCureSDK] Project Secret: \(String(projectSecret.prefix(8)))...")
        }
        
        print("🚀 [CMSCureSDK] About to create configuration object")
        
        // Create the configuration object.
        let newConfiguration = CureConfiguration(projectId: projectId, apiKey: apiKey, projectSecret: projectSecret, enableAutoRealTimeUpdates: enableAutoRealTimeUpdates)
        
        print("🚀 [CMSCureSDK] Configuration object created, checking if already configured")
        
        var sdkAlreadyConfigured = false
        configQueue.sync {
            if self.configuration != nil {
                sdkAlreadyConfigured = true
            } else {
                self.configuration = newConfiguration
            }
        }
        
        if sdkAlreadyConfigured {
            logError("Configuration ignored: SDK has already been configured."); return
        }
        
        if debugLogsEnabled {
            print("✅ [CMSCureSDK] Configuration object created successfully")
        }
        
        print("🚀 [CMSCureSDK] About to derive cryptographic key")
        
        // Asynchronously derive the cryptographic key on the cache queue.
        cacheQueue.async(flags: .barrier) {
            do {
                print("🚀 [CMSCureSDK] Inside cache queue for key derivation")
                self.apiSecret = projectSecret
                if let secretData = projectSecret.data(using: .utf8) {
                    self.symmetricKey = SymmetricKey(data: SHA256.hash(data: secretData))
                    if self.debugLogsEnabled {
                        print("🔐 [CMSCureSDK] Cryptographic key derived successfully")
                    }
                } else {
                    self.logError("Failed to convert project secret to UTF-8 data")
                }
            } catch {
                self.logError("Failed to derive cryptographic key: \(error)")
            }
        }
        
        if debugLogsEnabled {
            print("🌐 [CMSCureSDK] Starting authentication process...")
        }
        
        print("🚀 [CMSCureSDK] About to call _performLegacyAuthenticationAndConnect")
        
        // Perform initial authentication and setup.
        _performLegacyAuthenticationAndConnect { success in
            if success {
                if self.debugLogsEnabled {
                    print("✅ [CMSCureSDK] Authentication successful, starting sync...")
                }
                self.syncIfOutdated()
            } else {
                self.logError("Authentication failed during configuration")
            }
        }
        
        print("🚀 [CMSCureSDK] Configure method completed")
    }
    
    /// Internal helper to safely retrieve the current SDK configuration.
    /// - Returns: The `CureConfiguration` if the SDK has been configured, otherwise `nil`.
    internal func getCurrentConfiguration() -> CureConfiguration? {
        var currentConfig: CureConfiguration?
        configQueue.sync { // Thread-safe read.
            currentConfig = self.configuration
        }
        // Callers are responsible for handling a nil configuration (e.g., by logging an error or returning early).
        return currentConfig
    }
    
    // MARK: - Internal Legacy Authentication & Connection Flow
    
    /// Performs the legacy authentication process with the backend.
    /// This involves sending the API key and Project ID to an auth endpoint.
    /// On success, it stores the received token and project tabs, then initiates socket connection and sync.
    /// This method is called internally after `configure()` completes.
    ///
    /// - Parameter completion: A closure called with `true` if authentication and subsequent setup steps succeed, `false` otherwise.
    private func _performLegacyAuthenticationAndConnect(completion: @escaping (Bool) -> Void) {
        print("🔐 [CMSCureSDK] _performLegacyAuthenticationAndConnect called")
        
        guard let config = getCurrentConfiguration() else {
            logError("_performLegacyAuthenticationAndConnect: SDK not configured.")
            completion(false); return
        }
        
        print("🔐 [CMSCureSDK] Configuration retrieved successfully")
        
        guard let authUrl = URL(string: "\(self.serverURL.absoluteString)/api/sdk/auth") else {
            logError("Legacy Auth failed: Could not construct auth URL.")
            completion(false); return
        }
        
        print("🔐 [CMSCureSDK] Auth URL constructed: \(authUrl)")
        
        let requestBody: [String: String] = ["apiKey": config.apiKey, "projectId": config.projectId]
        guard let plainJsonHttpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            logError("Legacy Auth failed: Could not serialize plain JSON request body.")
            completion(false); return
        }
        
        print("🔐 [CMSCureSDK] Request body serialized successfully")
        
        var request = URLRequest(url: authUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = plainJsonHttpBody
        
        print("🔐 [CMSCureSDK] Making authentication request...")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                print("❌ [CMSCureSDK] Self is nil in auth response")
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            print("🔐 [CMSCureSDK] Authentication response received")
            
            if let error = error {
                self.logError("Authentication network error: \(error)")
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("🔐 [CMSCureSDK] HTTP Status Code: \(httpResponse.statusCode)")
            }
            
            guard let responseData = self.handleNetworkResponse(data: data, response: response, error: error, context: "internal legacy authenticating")
            else {
                print("❌ [CMSCureSDK] Network response handling failed")
                DispatchQueue.main.async { completion(false) }; return
            }
            
            print("🔐 [CMSCureSDK] Network response handled successfully, attempting to decode...")
            
            do {
                let authResult = try JSONDecoder().decode(AuthResult_OriginalWithTabs.self, from: responseData)
                guard let receivedToken = authResult.token, !receivedToken.isEmpty else {
                    self.logError("Legacy Auth failed: Response did not contain a token.")
                    DispatchQueue.main.async { completion(false) }; return
                }
                
                // Log the authentication result for debugging (unconditional for troubleshooting)
                print("✅ [CMSCureSDK] Authentication successful!")
                print("📋 [CMSCureSDK] Received tabs: \(authResult.tabs ?? [])")
                print("🏪 [CMSCureSDK] Received stores: \(authResult.stores ?? [])")
                print("🌍 [CMSCureSDK] Received languages: \(authResult.availableLanguages ?? ["none received"])")
                
                // Update internal state and persist data.
                self.cacheQueue.async(flags: .barrier) {
                    self.authToken = receivedToken
                    let receivedTabs = authResult.tabs ?? []
                    self.knownProjectTabs = Set(receivedTabs)
                    self.offlineTabList = Array(receivedTabs)
                    
                    // Store available languages from auth response
                    if let languages = authResult.availableLanguages, !languages.isEmpty {
                        self.availableLanguagesList = languages
                        print("🌍 [CMSCureSDK] Stored available languages: \(languages)")
                    } else {
                        self.availableLanguagesList = ["en"] // Fallback to default
                        print("⚠️ [CMSCureSDK] No languages received, defaulting to ['en']")
                    }
                    
                    self.saveOfflineTabListToDisk()
                    let receivedStores = authResult.stores ?? []
                    self.knownDataStoreIdentifiers = Set(receivedStores)
                    self.offlineDataStoreList = Array(receivedStores)
                    self.saveDataStoreListToDisk()
                    
                    self.saveLegacyConfigToDisk(["authToken": receivedToken])
                    
                    DispatchQueue.main.async {
                        print("🔐 [CMSCureSDK] Authentication completed successfully, starting socket connection...")
                        self.startListening()
                        completion(true)
                    }
                }
            } catch {
                self.logError("Legacy Auth failed: Could not decode response. Error: \(error)")
                if self.debugLogsEnabled {
                    print("📄 [CMSCureSDK] Raw response data: \(String(data: responseData, encoding: .utf8) ?? "Invalid UTF-8")")
                }
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }
    
    // MARK: - Public API - Language Management
    
    /// Sets the current active language for retrieving translations.
    ///
    /// This method updates the `currentLanguage` property, persists the preference to `UserDefaults`,
    /// and then triggers an update for all registered translation handlers and a data sync for all known tabs
    /// to fetch content in the new language.
    ///
    /// - Parameters:
    ///   - language: The language code to set (e.g., "en", "fr").
    ///   - force: If `true`, forces updates and sync even if the new language is the same as the current one. Defaults to `false`.
    ///   - completion: An optional closure called on the main thread after all tabs have attempted to sync for the new language.
    public func setLanguage(_ language: String, force: Bool = false, completion: (() -> Void)? = nil) {
        guard getCurrentConfiguration() != nil else {
            logError("Cannot set language: SDK not configured.")
            completion?() // Call completion even on failure to unblock caller.
            return
        }
        
        var shouldProceedWithUpdate = false
        var tabsToUpdateForNewLanguage: [String] = []
        
        // Determine if an update is necessary and gather tabs (Thread-Safe Read/Write for currentLanguage).
        cacheQueue.sync { // Sync to ensure currentLanguage is read and updated atomically.
            if language != self.currentLanguage || force {
                shouldProceedWithUpdate = true
                self.currentLanguage = language // Update the internal state.
                UserDefaults.standard.set(language, forKey: "selectedLanguage") // Persist the new language preference.
                
                // Combine tabs from the current cache and the known (potentially offline) project tabs.
                // This ensures all relevant content areas are updated.
                tabsToUpdateForNewLanguage = Array(Set(self.cache.keys).union(self.knownProjectTabs))
            }
        }
        
        guard shouldProceedWithUpdate else {
            // No change in language and not forced, so no update needed.
            completion?(); return
        }
        
        if self.debugLogsEnabled { print("🔄 Switching to language '\(language)'. Will update tabs: \(tabsToUpdateForNewLanguage.isEmpty ? "None (or only __colors__)" : tabsToUpdateForNewLanguage.joined(separator: ", "))") }
        
        // Use a DispatchGroup to wait for all sync operations to complete.
        let syncGroup = DispatchGroup()
        
        for screenName in tabsToUpdateForNewLanguage {
            if self.debugLogsEnabled { print("   - Updating UI for tab '\(screenName)' with new language '\(language)'.") }
            
            // Immediately notify handlers with currently cached values for the new language.
            // This provides a responsive UI update while fresh data is fetched in the background.
            let cachedValuesForNewLanguage = self.getCachedTranslations(for: screenName, language: language) // Thread-safe read.
            DispatchQueue.main.async {
                self.notifyUpdateHandlers(screenName: screenName, values: cachedValuesForNewLanguage)
            }
            
            // Enter the group for each sync operation.
            syncGroup.enter()
            self.sync(screenName: screenName) { success in
                if !success && self.debugLogsEnabled {
                    print("⚠️ Failed to sync tab '\(screenName)' after language change to '\(language)'.")
                }
                syncGroup.leave() // Leave the group when sync completes (success or failure).
            }
        }
        
        // Notify the caller once all sync operations initiated by the language change are done.
        syncGroup.notify(queue: .main) {
            completion?()
        }
    }
    
    /// Retrieves the currently active language code.
    /// - Returns: The current language code (e.g., "en").
    public func getLanguage() -> String {
        // Thread-safe read of currentLanguage.
        return cacheQueue.sync { self.currentLanguage }
    }
    
    /// Returns whether automatic real-time updates are currently enabled.
    /// This reflects the configuration setting provided during SDK initialization.
    /// - Returns: `true` if auto real-time updates are enabled, `false` otherwise.
    public func isAutoRealTimeUpdatesEnabled() -> Bool {
        guard let config = getCurrentConfiguration() else { return false }
        return config.enableAutoRealTimeUpdates
    }
    
    /// Returns a list of screens that have been automatically subscribed to real-time updates.
    /// This includes screens accessed via the translation() method when auto real-time updates are enabled.
    /// - Returns: An array of screen names that are auto-subscribed to real-time updates.
    public func getAutoSubscribedScreens() -> [String] {
        return DispatchQueue.main.sync { Array(autoSubscribedScreens) }
    }
    
    /// Returns whether colors have been automatically subscribed to real-time updates.
    /// This reflects whether colorValue() has been called when auto real-time updates are enabled.
    /// - Returns: `true` if colors are auto-subscribed to real-time updates, `false` otherwise.
    public func isColorsAutoSubscribed() -> Bool {
        return DispatchQueue.main.sync { autoSubscribedColors }
    }
    
    /// Returns whether global images have been automatically subscribed to real-time updates.
    /// This reflects whether imageURL() has been called when auto real-time updates are enabled.
    /// - Returns: `true` if global images are auto-subscribed to real-time updates, `false` otherwise.
    public func isGlobalImagesAutoSubscribed() -> Bool {
        return DispatchQueue.main.sync { autoSubscribedGlobalImages }
    }
    
    /// Returns a list of data stores that have been automatically subscribed to real-time updates.
    /// This includes data stores accessed via the getStoreItems() method when auto real-time updates are enabled.
    /// - Returns: An array of data store API identifiers that are auto-subscribed to real-time updates.
    public func getAutoSubscribedDataStores() -> [String] {
        return DispatchQueue.main.sync { Array(autoSubscribedDataStores) }
    }
    
    // MARK: - Public API - Cache Management
    
    /// Clears all cached data, persisted files (cache, tabs, config), and runtime configuration.
    /// This effectively resets the SDK to its initial state before `configure()` was called.
    /// Active socket connections will be stopped.
    public func clearCache() {
        // Clear auto-registered screens
        DispatchQueue.main.async {
            self.autoRegisteredScreens.removeAll()
        }
        
        // Perform cache clearing and file deletion on the cacheQueue for thread safety.
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAll()
            self.dataStoreCache.removeAll()
            self.offlineTabList.removeAll()
            self.offlineDataStoreList.removeAll()
            self.knownProjectTabs.removeAll()
            self.knownDataStoreIdentifiers.removeAll()
            self.authToken = nil
            self.symmetricKey = nil
            self.apiSecret = nil
            self.handshakeAcknowledged = false
            
            // Delete persisted files.
            do {
                if FileManager.default.fileExists(atPath: self.cacheFilePath.path) {
                    try FileManager.default.removeItem(at: self.cacheFilePath)
                }
                if FileManager.default.fileExists(atPath: self.tabsFilePath.path) {
                    try FileManager.default.removeItem(at: self.tabsFilePath)
                }
                if FileManager.default.fileExists(atPath: self.configFilePath.path) {
                    try FileManager.default.removeItem(at: self.configFilePath)
                }
                if FileManager.default.fileExists(atPath: self.dataStoreCacheFilePath.path) {
                    try FileManager.default.removeItem(at: self.dataStoreCacheFilePath)
                }
                if FileManager.default.fileExists(atPath: self.dataStoreListFilePath.path) {
                    try FileManager.default.removeItem(at: self.dataStoreListFilePath)
                }
            } catch {
                self.logError("Failed to delete one or more cache/config files during clearCache: \(error)")
            }
            
            // Notify all handlers that their data is now empty.
            DispatchQueue.main.async {
                let allHandlerKeys = Set(self.translationUpdateHandlers.keys)
                    .union(self.internalTranslationUpdateHandlers.keys)
                for screenName in allHandlerKeys {
                    self.notifyUpdateHandlers(screenName: screenName, values: [:])
                }
            }
        }
        
        KingfisherManager.shared.cache.clearMemoryCache()
        KingfisherManager.shared.cache.clearDiskCache()
        
        // Clear the runtime configuration state.
        configQueue.sync {
            self.configuration = nil
        }
    }
    
    // MARK: - Public API - Content Accessors
    
    /// Retrieves a translation for a specific key within a given tab (screen name), using the currently set language.
    ///
    /// **Enhanced with Automatic Real-time Updates:**
    /// - Maintains exact same method signature for backward compatibility
    /// - Automatically subscribes to real-time updates for accessed screens
    /// - Returns immediate cached values while setting up real-time subscriptions in background
    /// - No breaking changes for existing implementations
    ///
    /// If the translation is not found in the cache, an empty string is returned.
    /// This method is thread-safe.
    ///
    /// - Parameters:
    ///   - key: The key for the desired translation.
    ///   - screenName: The name of the tab/screen where the translation key is located.
    /// - Returns: The translated string for the current language, or an empty string if not found.
    public func translation(for key: String, inTab screenName: String) -> String {
        // Set up auto real-time updates for this screen if not already done
        setupAutoRealTimeUpdates(for: screenName)
        
        let cachedValue = cacheQueue.sync {
            return cache[screenName]?[key]?[self.currentLanguage] ?? ""
        }
        
        // Add debug logging for translation requests
        if debugLogsEnabled && cachedValue.isEmpty {
            print("🔍 Translation requested: key='\(key)', tab='\(screenName)', language='\(self.currentLanguage)' - NOT FOUND in cache")
        } else if debugLogsEnabled {
            print("✅ Translation found: key='\(key)', tab='\(screenName)', language='\(self.currentLanguage)' - '\(cachedValue)'")
        }
        
        return cachedValue
    }
    
    private func setupAutoRealTimeUpdates(for screenName: String) {
        // Use main queue to avoid threading issues
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            print("🔧 setupAutoRealTimeUpdates called for: '\(screenName)'")
            
            // Check if we've already set up updates for this screen
            guard !self.autoRegisteredScreens.contains(screenName) else { 
                print("ℹ️ Screen '\(screenName)' already registered for auto-updates")
                return 
            }
            
            print("📝 Registering screen '\(screenName)' for auto-updates")
            
            // Mark this screen as registered
            self.autoRegisteredScreens.insert(screenName)

            // Register an internal handler to observe updates without overriding
            // any handlers the app developer may have registered manually.
            self.registerInternalTranslationHandler(for: screenName) { [weak self] updatedTranslations in
                self?.logDebug("Auto-updates: Screen '\(screenName)' refreshed with \(updatedTranslations.count) keys")
            }
            
            // If the screen hasn't been synced yet, sync it now
            let isSynced = self.isTabSynced(screenName)
            print("🔍 Is tab '\(screenName)' already synced? \(isSynced)")
            
            if !isSynced {
                print("🔄 Auto-syncing screen '\(screenName)'...")
                self.sync(screenName: screenName) { success in
                    if success {
                        print("✅ Auto-sync completed successfully for screen '\(screenName)'")
                    } else {
                        print("❌ Auto-sync failed for screen '\(screenName)'")
                    }
                }
            } else {
                print("✅ Screen '\(screenName)' is already synced")
            }
        }
    }
    
    /// Retrieves all cached items for a specific Data Store.
    ///
    /// **Enhanced with Automatic Real-time Updates:**
    /// - Maintains exact same method signature for backward compatibility
    /// - Automatically subscribes to real-time updates for accessed data stores
    /// - Returns immediate cached values while setting up real-time subscriptions in background
    /// - No breaking changes for existing implementations
    ///
    /// This method is synchronous and reads directly from the in-memory cache.
    /// Returns an empty array if the store is not found in the cache.
    /// - Parameter apiIdentifier: The unique API identifier of the store.
    /// - Returns: An array of `DataStoreItem` objects.
    public func getStoreItems(for apiIdentifier: String) -> [DataStoreItem] {
        // Set up auto real-time updates for this data store
        setupAutoRealTimeUpdatesForDataStore(apiIdentifier)
        
        return cacheQueue.sync {
            return self.dataStoreCache[apiIdentifier] ?? []
        }
    }

    /// Provides a simplified collection of data store records with convenient accessors.
    ///
    /// This helper mirrors the ergonomics of `translation(for:inTab:)` by letting UIKit
    /// or SwiftUI callers fetch items and immediately iterate over user-friendly records.
    /// Each record includes handy typed accessors (string/int/bool/double) and automatically
    /// resolves localized fields using the SDK's currently selected language.
    ///
    /// Just like `getStoreItems`, this method sets up real-time updates the first time a
    /// store is accessed and returns the most recent cached values synchronously.
    ///
    /// - Parameter apiIdentifier: The unique API identifier of the data store.
    /// - Returns: An array of `CureDataStoreRecord` objects for easy iteration.
    public func dataStoreRecords(for apiIdentifier: String) -> [CureDataStoreRecord] {
        return getStoreItems(for: apiIdentifier).map { CureDataStoreRecord(item: $0) }
    }
    
    private func setupAutoRealTimeUpdatesForDataStore(_ apiIdentifier: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Check if we've already set up updates for this store
            guard !self.autoRegisteredScreens.contains("datastore_\(apiIdentifier)") else { return }
            
            // Mark this store as registered (using a prefixed key to avoid conflicts)
            self.autoRegisteredScreens.insert("datastore_\(apiIdentifier)")
            
            // If the store hasn't been synced yet, sync it now
            self.syncStore(apiIdentifier: apiIdentifier) { success in
                if self.debugLogsEnabled {
                    if success {
                        print("✅ Auto-sync completed for data store '\(apiIdentifier)'")
                    } else {
                        print("⚠️ Auto-sync failed for data store '\(apiIdentifier)'")
                    }
                }
            }
        }
    }
    
    /// Fetches the latest items for a specific Data Store from the backend and updates the cache.
    /// - Parameters:
    ///   - apiIdentifier: The unique API identifier of the store to synchronize.
    ///   - completion: A closure called on the main thread with `true` on success, `false` on failure.
    public func syncStore(apiIdentifier: String, completion: @escaping (Bool) -> Void) { // --- ADD THIS ENTIRE METHOD ---
        guard let config = getCurrentConfiguration() else {
            logError("Sync Store failed for '\(apiIdentifier)': SDK is not configured.")
            DispatchQueue.main.async { completion(false) }
            return
        }
        
        guard let request = createAuthenticatedRequest(
            endpointPath: "/api/sdk/store/\(config.projectId)/\(apiIdentifier)",
            httpMethod: "GET",
            body: nil,
            useEncryption: false
        ) else {
            logError("Failed to create sync request for data store '\(apiIdentifier)'.")
            DispatchQueue.main.async { completion(false) }
            return
        }
        
        if debugLogsEnabled { print("🔄 Syncing data store '\(apiIdentifier)'...") }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self,
                  let responseData = self.handleNetworkResponse(data: data, response: response, error: error, context: "syncing data store '\(apiIdentifier)'") else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            if responseData.isEmpty {
                if self.debugLogsEnabled { print("ℹ️ No data for store '\(apiIdentifier)'") }
                DispatchQueue.main.async { completion(true) }
                return
            }
            
            do {
                let decodedResponse = try JSONDecoder().decode(DataStoreResponse.self, from: responseData)
                
                self.cacheQueue.async(flags: .barrier) {
                    self.dataStoreCache[apiIdentifier] = decodedResponse.items
                    self.saveDataStoreCacheToDisk()
                    
                    DispatchQueue.main.async {
                        if self.debugLogsEnabled {
                            print("✅ Synced data store '\(apiIdentifier)' - \(decodedResponse.items.count) items")
                        }
                        self.postTranslationsUpdatedNotification(screenName: apiIdentifier)
                        completion(true)
                    }
                }
            } catch {
                self.logError("Failed to decode data store '\(apiIdentifier)': \(error)")
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }
    
    /// Retrieves a color hex string for a given global color key.
    ///
    /// **Enhanced with Automatic Real-time Updates:**
    /// - Maintains exact same method signature for backward compatibility
    /// - Automatically subscribes to real-time updates for colors when called
    /// - Returns immediate cached values while setting up real-time subscriptions in background
    /// - No breaking changes for existing implementations
    ///
    /// Colors are typically stored in a special tab named `__colors__`.
    /// If the color key is not found, `nil` is returned. This method is thread-safe.
    ///
    /// - Parameter key: The key for the desired color.
    /// - Returns: The color hex string (e.g., "#RRGGBB") or `nil` if not found.
    public func colorValue(for key: String) -> String? {
        // Set up auto real-time updates for colors
        setupAutoRealTimeUpdates(for: "__colors__")
        
        return cacheQueue.sync {
            guard let colorsCache = cache["__colors__"] else {
                if debugLogsEnabled { print("🔍 No colors cache found") }
                return nil
            }
            
            // Look for the color in the cache structure: cache["__colors__"][key]["color"]
            if let colorData = colorsCache[key]?["color"] {
                if debugLogsEnabled { print("🎨 Found color for '\(key)': \(colorData)") }
                return colorData
            }
            
            if debugLogsEnabled { print("🔍 Color not found for key: '\(key)'") }
            return nil
        }
    }
    
    /// Retrieves a URL for an image associated with a given key and tab, in the current language.
    ///
    /// The underlying translation for the key is expected to be a valid URL string.
    /// If the translation is not found, is empty, or is not a valid URL, `nil` is returned.
    /// This method is thread-safe.
    ///
    /// - Parameters:
    ///   - key: The key for the desired image URL.
    ///   - screenName: The name of the tab/screen where the image URL key is located.
    /// - Returns: A `URL` object if a valid URL string is found, otherwise `nil`.
    public func imageUrl(for key: String, inTab screenName: String) -> URL? {
        let urlString = self.translation(for: key, inTab: screenName)
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        return url
    }
    
    /// Retrieves a URL for a globally managed image asset from the central image library.
    ///
    /// **Enhanced with Automatic Real-time Updates:**
    /// - Maintains exact same method signature for backward compatibility
    /// - Automatically subscribes to real-time updates for global images when called
    /// - Returns immediate cached values while setting up real-time subscriptions in background
    /// - No breaking changes for existing implementations
    ///
    /// - Parameter forKey: The key for the desired global image asset.
    /// - Returns: A URL for the global image, or `nil` if not found or invalid.
    public func imageURL(forKey: String) -> URL? {
        // Set up auto real-time updates for images
        setupAutoRealTimeUpdates(for: "__images__")
        
        let urlString = cacheQueue.sync {
            return self.cache["__images__"]?[forKey]?["url"]
        }
        
        guard let urlStr = urlString, !urlStr.isEmpty, let url = URL(string: urlStr) else {
            return nil
        }
        return url
    }
    
    /// Retrieves all cached key-value pairs for a specific screen (tab) and language.
    /// Used internally for populating update handlers. This method is thread-safe.
    ///
    /// - Parameters:
    ///   - screenName: The name of the tab/screen.
    ///   - language: The language code for which to retrieve translations.
    /// - Returns: A dictionary of `[Key: Value]` for the specified screen and language.
    private func getCachedTranslations(for screenName: String, language: String) -> [String: String] {
        return cacheQueue.sync { // Thread-safe read from the cache.
            var valuesForLanguage: [String: String] = [:]
            if let tabCache = self.cache[screenName] {
                for (key, languageMap) in tabCache {
                    // If a value exists for the requested language, add it to the result.
                    if let translation = languageMap[language] {
                        valuesForLanguage[key] = translation
                    }
                }
            }
            return valuesForLanguage // `compactMapValues` is not needed if we only add non-nil values.
        }
    }
    
    // MARK: - Internal Network Request Helper
    
    /// Creates and configures a `URLRequest` for API calls to the CMSCure backend.
    ///
    /// This method ensures that the request is constructed with the correct base URL, endpoint path,
    /// HTTP method, and necessary authentication headers.
    ///
    /// **Hybrid Approach Implementation:**
    /// - Auth endpoint (`/api/sdk/auth`) sends credentials in body, no auth header
    /// - All other endpoints use Bearer token (received from auth endpoint)
    /// - Falls back to X-API-Key if token is missing (shouldn't happen in normal flow)
    ///
    /// **Note:** The SDK must be configured via `configure()` before this method can be used successfully.
    ///
    /// - Parameters:
    ///   - endpointPath: The specific API endpoint path (e.g., "/api/sdk/translations").
    ///   - appendProjectIdToPath: If `true`, the `projectId` from the configuration will be appended to the `endpointPath`. Defaults to `false`.
    ///   - httpMethod: The HTTP method for the request (e.g., "GET", "POST"). Defaults to "GET".
    ///   - body: An optional dictionary representing the JSON body for "POST", "PUT", "PATCH" requests.
    ///   - useEncryption: If `true`, the request body will be encrypted using the legacy encryption method. Defaults to `false`.
    /// - Returns: A configured `URLRequest` instance, or `nil` if configuration is missing or an error occurs during request creation.
    internal func createAuthenticatedRequest(
        endpointPath: String,
        appendProjectIdToPath: Bool = false,
        httpMethod: String = "GET",
        body: [String: Any]? = nil,
        useEncryption: Bool = false
    ) -> URLRequest? {
        
        guard let config = getCurrentConfiguration() else {
            logError("Cannot create authenticated request: SDK is not configured.")
            return nil
        }
        let projectId = config.projectId
        let apiKey = config.apiKey
        
        // --- Construct Full URL ---
        var urlComponents = URLComponents(url: self.serverURL, resolvingAgainstBaseURL: false)
        urlComponents?.path = endpointPath
        
        if appendProjectIdToPath {
            var currentPath = urlComponents?.path ?? ""
            if !currentPath.hasSuffix("/") { currentPath += "/" }
            currentPath += projectId
            urlComponents?.path = currentPath
        }
        
        guard let finalUrl = urlComponents?.url else {
            logError("Cannot create authenticated request: Failed to construct valid URL for endpoint '\(endpointPath)' with base '\(self.serverURL)'.")
            return nil
        }
        
        // --- Initialize Request ---
        var request = URLRequest(url: finalUrl)
        request.httpMethod = httpMethod
        request.timeoutInterval = 15
        
        // --- Set Standard Headers ---
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // --- Authentication Headers (Hybrid Approach) ---
        
        // Special case: Auth endpoint doesn't need auth header (credentials are in body)
        if endpointPath.contains("/api/sdk/auth") {
            // No auth header needed for auth endpoint
            // API key and projectId will be in the request body
            logDebug("Auth endpoint detected - no authorization header added")
        }
        // All other endpoints: Use Bearer token from previous auth
        else {
            // Try to get the auth token that we received from the auth endpoint
            let token = cacheQueue.sync { self.authToken }
            
            if let token = token, !token.isEmpty {
                // We have a token from the gateway, use it
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                logDebug("Using Bearer token for request to \(endpointPath)")
            } else {
                // Fallback: This shouldn't happen in normal flow, but if we don't have a token,
                // try using the API key directly (for backward compatibility or error recovery)
                request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
                logDebug("Warning: No auth token available, falling back to X-API-Key for \(endpointPath)")
            }
        }
        
        // --- Handle Request Body ---
        var httpBodyData: Data? = nil
        if let requestBodyPayload = body, ["POST", "PUT", "PATCH"].contains(httpMethod.uppercased()) {
            
            if useEncryption {
                // Legacy encryption path (for WebSocket handshake, not HTTP requests)
                // This should rarely be used with the gateway
                httpBodyData = cacheQueue.sync { self.encryptBody(requestBodyPayload) }
                if httpBodyData == nil {
                    logError("Failed to encrypt request body for endpoint '\(finalUrl.path)'. Request will not be sent.")
                    return nil
                }
            } else {
                // Standard JSON serialization (normal case)
                do {
                    httpBodyData = try JSONSerialization.data(withJSONObject: requestBodyPayload, options: [])
                } catch {
                    logError("Failed to serialize JSON request body for endpoint '\(finalUrl.path)': \(error)")
                    return nil
                }
            }
        }
        request.httpBody = httpBodyData
        
        // Debug logging
        if debugLogsEnabled {
            var debugInfo = "Created Request: \(httpMethod) \(finalUrl.path)"
            if let query = finalUrl.query {
                debugInfo += " (Query: \(query))"
            }
            if endpointPath.contains("/api/sdk/auth") {
                debugInfo += " [Auth - No header]"
            } else if request.value(forHTTPHeaderField: "Authorization")?.starts(with: "Bearer") ?? false {
                debugInfo += " [Bearer token]"
            } else {
                debugInfo += " [X-API-Key fallback]"
            }
            print(debugInfo)
        }
        
        return request
    }
    
    /// A generic helper function to handle common aspects of network responses from `URLSession` tasks.
    ///
    /// This function checks for client-side errors, validates HTTP status codes, and attempts to extract response data.
    /// It logs errors encountered during these processes.
    ///
    /// - Parameters:
    ///   - data: The `Data` received from the network task, or `nil` if an error occurred or no data was returned.
    ///   - response: The `URLResponse` received from the network task, or `nil`.
    ///   - error: The `Error` object if the task failed, or `nil` if it succeeded at the transport layer.
    ///   - context: A descriptive string indicating the operation being performed (e.g., "syncing 'general_ui'"), used for logging.
    /// - Returns: The `Data` from the response if the request was successful (2xx status code) and data exists.
    ///            Returns empty `Data` for successful 404s in a "syncing" context (handled as "no content").
    ///            Returns `nil` if any critical error occurs (network error, invalid response type, or non-2xx/non-404 status code).
    internal func handleNetworkResponse(data: Data?, response: URLResponse?, error: Error?, context: String) -> Data? {
        // 1. Check for client-side (URLSession) errors.
        if let networkError = error {
            logError("Network error encountered while \(context): \(networkError.localizedDescription)")
            return nil
        }
        
        // 2. Ensure the response is an HTTPURLResponse.
        guard let httpResponse = response as? HTTPURLResponse else {
            logError("Invalid response type received while \(context). Expected HTTPURLResponse, got \(type(of: response)).")
            return nil
        }
        
        // 3. Handle specific status codes.
        //    - For "syncing" operations, a 404 (Not Found) is treated as a successful response indicating no content for that tab.
        if httpResponse.statusCode == 404 && context.lowercased().contains("syncing") {
            if debugLogsEnabled { print("ℹ️ Sync info for \(context): Resource not found (404). Treating as successful with no new data.") }
            return Data() // Return empty Data to signify "success, but no content".
        }
        
        //    - Check for other successful (2xx) status codes.
        guard (200...299).contains(httpResponse.statusCode) else {
            // Attempt to get more error details from the response body.
            let responseBodyString = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body available."
            logError("HTTP error encountered while \(context): Status Code \(httpResponse.statusCode). Body: \(responseBodyString)")
            return nil
        }
        
        // 4. Handle successful responses (2xx).
        //    If data is nil but status is 2xx (e.g., 204 No Content, or 200 OK with empty body), return empty Data.
        guard let responseData = data else {
            if debugLogsEnabled { print("ℹ️ Received successful response (Status \(httpResponse.statusCode)) with no data body while \(context).") }
            return Data()
        }
        
        return responseData // Return the actual data for successful responses with content.
    }
    
    
    // MARK: - Content Synchronization Logic
    
    /// Fetches the latest translations or color data for a specific screen name (tab) from the backend.
    ///
    /// This method requires the SDK to be configured. It constructs an authenticated request,
    /// sends it to the server, and upon receiving a successful response, parses the JSON data
    /// and updates the in-memory cache. The updated cache is then persisted to disk.
    /// Finally, it notifies any registered handlers that the translations for the screen have been updated.
    ///
    /// - Parameters:
    ///   - screenName: The name of the tab/screen to synchronize.
    ///   - completion: A closure called on the main thread with `true` if synchronization and cache update
    ///                 were successful, `false` otherwise.
    public func sync(screenName: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            
            // Check if already syncing
            if self.syncingScreens.contains(screenName) {
                if self.debugLogsEnabled {
                    print("ℹ️ Sync already in progress for '\(screenName)'")
                }
                completion(false)
                return
            }
            
            // Mark as syncing
            self.syncingScreens.insert(screenName)
            
            // Route to appropriate sync method
            if screenName == "__images__" {
                self.syncImages { success in
                    DispatchQueue.main.async {
                        self.syncingScreens.remove(screenName)
                        completion(success)
                    }
                }
            } else {
                self.syncTranslations(screenName: screenName) { success in
                    DispatchQueue.main.async {
                        self.syncingScreens.remove(screenName)
                        completion(success)
                    }
                }
            }
        }
    }
    
    private func syncColors(completion: @escaping (Bool) -> Void) {
        guard let config = getCurrentConfiguration() else {
            logError("Sync Colors failed: SDK is not configured.")
            DispatchQueue.main.async { completion(false) }
            return
        }
        
        guard let request = createAuthenticatedRequest(
            endpointPath: "/api/sdk/colors/\(config.projectId)",
            httpMethod: "GET",
            body: nil,
            useEncryption: false
        ) else {
            logError("Failed to create sync request for colors.")
            DispatchQueue.main.async { completion(false) }
            return
        }
        
        if debugLogsEnabled { print("🔄 Syncing colors...") }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self,
                  let responseData = self.handleNetworkResponse(data: data, response: response, error: error, context: "syncing colors") else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            if responseData.isEmpty {
                if self.debugLogsEnabled { print("ℹ️ No colors found") }
                DispatchQueue.main.async { completion(true) }
                return
            }
            
            struct ColorItem: Decodable {
                let key: String
                let value: String  // hex value
            }
            
            do {
                let colors = try JSONDecoder().decode([ColorItem].self, from: responseData)
                if self.debugLogsEnabled { print("✅ Fetched \(colors.count) colors") }
                
                self.cacheQueue.async(flags: .barrier) {
                    var newColorCache: [String: [String: String]] = [:]
                    for color in colors {
                        // Store colors with "color" key to maintain cache structure
                        newColorCache[color.key] = ["color": color.value]
                    }
                    self.cache["__colors__"] = newColorCache
                    self.saveCacheToDisk()
                    
                    DispatchQueue.main.async {
                        self.notifyUpdateHandlers(screenName: "__colors__", values: [:])
                        completion(true)
                    }
                }
            } catch {
                self.logError("Failed to decode colors: \(error)")
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }
    
    /// Fetches the list of all global image assets from the `/api/images/:projectId` endpoint.
    private func syncImages(completion: @escaping (Bool) -> Void) {
        guard let config = getCurrentConfiguration() else {
            logError("Sync Images failed: SDK is not configured.")
            DispatchQueue.main.async { completion(false) }
            return
        }
        
        guard let request = createAuthenticatedRequest(
            endpointPath: "/api/sdk/images/\(config.projectId)",
            httpMethod: "GET",
            body: nil,
            useEncryption: false
        ) else {
            logError("Failed to create sync request for images.")
            DispatchQueue.main.async { completion(false) }
            return
        }
        
        if debugLogsEnabled { print("🔄 Syncing global images...") }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self,
                  let responseData = self.handleNetworkResponse(data: data, response: response, error: error, context: "syncing images") else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            if responseData.isEmpty {
                if self.debugLogsEnabled { print("ℹ️ No images found") }
                DispatchQueue.main.async { completion(true) }
                return
            }
            
            struct ImageAsset: Decodable {
                let key: String
                let url: String
            }
            
            do {
                let imageAssets = try JSONDecoder().decode([ImageAsset].self, from: responseData)
                if self.debugLogsEnabled { print("✅ Fetched \(imageAssets.count) images") }
                
                self.cacheQueue.async(flags: .barrier) {
                    var newImageCache: [String: [String: String]] = [:]
                    for asset in imageAssets {
                        newImageCache[asset.key] = ["url": asset.url]
                    }
                    self.cache["__images__"] = newImageCache
                    self.saveCacheToDisk()
                    
                    let urlsToPrefetch = imageAssets.compactMap { URL(string: $0.url) }
                    self.prefetchImages(urls: urlsToPrefetch)
                    
                    DispatchQueue.main.async {
                        self.notifyUpdateHandlers(screenName: "__images__", values: [:])
                        completion(true)
                    }
                }
            } catch {
                self.logError("Failed to decode images: \(error)")
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }
    
    /// Fetches translations for a standard content tab or the `__colors__` tab.
    private func syncTranslations(screenName: String, completion: @escaping (Bool) -> Void) {
        guard let config = getCurrentConfiguration() else {
            logError("Sync failed for tab '\(screenName)': SDK is not configured.")
            DispatchQueue.main.async { completion(false) }
            return
        }
        let projectId = config.projectId
        
        // Match the JavaScript SDK exactly - use GET with Authorization header
        guard let request = createAuthenticatedRequest(
            endpointPath: "/api/sdk/translations/\(projectId)/\(screenName)",
            httpMethod: "GET",  // Changed from POST to GET to match JavaScript SDK
            body: nil,          // No body for GET request
            useEncryption: false
        ) else {
            logError("Failed to create sync request for tab '\(screenName)'.")
            DispatchQueue.main.async { completion(false) }
            return
        }
        
        if debugLogsEnabled {
            print("🔄 Syncing tab '\(screenName)'...")
            print("   Endpoint: GET /api/sdk/translations/\(projectId)/\(screenName)")
            print("   Using Authorization header (matching JavaScript SDK)")
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            if let error = error {
                self.logError("Translation sync error for '\(screenName)': \(error)")
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("🔄 Translation sync HTTP status for '\(screenName)': \(httpResponse.statusCode)")
            }
            
            guard let responseData = self.handleNetworkResponse(
                data: data,
                response: response,
                error: error,
                context: "syncing '\(screenName)'"
            ) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            if responseData.isEmpty {
                if self.debugLogsEnabled {
                    print("ℹ️ No content for tab '\(screenName)' (404 or empty response)")
                }
                DispatchQueue.main.async { completion(true) }
                return
            }
            
            do {
                // Parse response matching JavaScript SDK structure
                let jsonResponse = try JSONDecoder().decode(TranslationResponse.self, from: responseData)
                
                self.cacheQueue.async(flags: .barrier) {
                    var updatedValuesForCurrentLanguage: [String: String] = [:]
                    var newCacheDataForScreen: [String: [String: String]] = self.cache[screenName] ?? [:]
                    let activeLanguage = self.currentLanguage
                    
                    // Process keys array
                    for item in jsonResponse.keys {
                        newCacheDataForScreen[item.key] = item.values
                        
                        if let valueForCurrentLanguage = item.values[activeLanguage] {
                            updatedValuesForCurrentLanguage[item.key] = valueForCurrentLanguage
                        }
                    }
                    
                    self.cache[screenName] = newCacheDataForScreen
                    
                    if !self.knownProjectTabs.contains(screenName) {
                        self.knownProjectTabs.insert(screenName)
                        self.offlineTabList = Array(self.knownProjectTabs)
                        self.saveOfflineTabListToDisk()
                    }
                    
                    self.saveCacheToDisk()
                    
                    DispatchQueue.main.async {
                        self.notifyUpdateHandlers(screenName: screenName, values: updatedValuesForCurrentLanguage)
                        if self.debugLogsEnabled {
                            print("✅ Synced tab '\(screenName)' - \(jsonResponse.keys.count) keys")
                        }
                        completion(true)
                    }
                }
            } catch {
                self.logError("Failed to decode response for tab '\(screenName)': \(error)")
                if self.debugLogsEnabled,
                   let jsonString = String(data: responseData, encoding: .utf8) {
                    print("Raw response: \(jsonString.prefix(500))")
                }
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }
    
    /// Uses Kingfisher to download and cache an array of image URLs in the background.
    /// - Parameter urls: An array of `URL` objects to pre-fetch.
    private func prefetchImages(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if debugLogsEnabled { print("🖼️ Kingfisher: Starting pre-fetch for \(urls.count) images.") }
        
        let prefetcher = ImagePrefetcher(urls: urls) { skipped, failed, completed in
            if self.debugLogsEnabled {
                print("🖼️ Kingfisher: Pre-fetch finished. Completed: \(completed.count), Failed: \(failed.count), Skipped: \(skipped.count)")
                if !failed.isEmpty {
                    self.logError("Kingfisher: Failed to pre-fetch \(failed.count) resources.")
                }
            }
        }
        prefetcher.start()
    }
    
    /// Triggers a synchronization operation for all known project tabs and special tabs (like `__colors__`).
    ///
    /// This method is typically called:
    /// - When the app becomes active.
    /// - After a successful Socket.IO connection and handshake.
    ///
    /// It checks if the SDK is configured and if necessary secrets (for encryption) are available before proceeding.
    private func syncIfOutdated() {
        guard let config = getCurrentConfiguration() else {
            if debugLogsEnabled { print("ℹ️ Skipping syncIfOutdated: SDK is not configured.") }
            return
        }
        
        // Don't check for encryption - we're not using it
        let regularTabsToSync = cacheQueue.sync {
            Array(Set(self.cache.keys).union(self.knownProjectTabs))
                .filter { !$0.starts(with: "__") }
        }
        
        // Include colors in special tabs
        let specialTabsToSync = ["__colors__", "__images__"]
        let allTabsToSync = Set(regularTabsToSync + specialTabsToSync)
        
        if debugLogsEnabled && !allTabsToSync.isEmpty {
            print("🔄 Syncing all relevant tabs: \(allTabsToSync.joined(separator: ", "))")
        }
        
        for tabName in allTabsToSync {
            if tabName == "__colors__" {
                self.syncColors { _ in }
            } else {
                self.sync(screenName: tabName) { success in
                    if !success && self.debugLogsEnabled {
                        print("⚠️ Failed to sync tab '\(tabName)'")
                    }
                }
            }
        }
        
        let storesToSync = self.cacheQueue.sync { self.knownDataStoreIdentifiers }
        if self.debugLogsEnabled && !storesToSync.isEmpty {
            print("🔄 Syncing data stores: \(storesToSync.joined(separator: ", "))")
        }
        for storeIdentifier in storesToSync {
            self.syncStore(apiIdentifier: storeIdentifier) { _ in }
        }
    }
    
    
    // MARK: - Socket.IO Communication
    
    /// Establishes a connection with the Socket.IO server.
    ///
    /// This method should only be called after the SDK has been successfully configured via `configure()`,
    /// as it relies on the `socketIOURL` and potentially `projectSecret` (for legacy handshake)
    /// from the configuration.
    ///
    /// It handles creating a `SocketManager` and `SocketIOClient` instance, sets up event handlers,
    /// and initiates the connection. If already connected or connecting, it may attempt to send
    /// a handshake if not already acknowledged.
    public func connectSocket() {
        guard let config = getCurrentConfiguration() else {
            logError("Cannot connect socket: SDK is not configured.")
            return
        }
        // Legacy handshake requires projectSecret. Ensure it's available.
        guard !config.projectSecret.isEmpty else {
            logError("Cannot connect socket for legacy handshake: Project Secret is missing in configuration.")
            return
        }
        
        let projectId = config.projectId
        let socketConnectionUrl = self.socketIOUrl
        
        // Socket operations should be performed on the main thread.
        // A small delay can sometimes help if called very early in rapid succession.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            
            let currentSocketStatus = self.manager?.status ?? .notConnected
            
            // If already connected or in the process of connecting, avoid creating a new connection.
            guard currentSocketStatus != .connected && currentSocketStatus != .connecting else {
                if self.debugLogsEnabled { print("⚠️ Socket is already \(currentSocketStatus.description.lowercased()) or attempting to connect.") }
                // If connected but handshake hasn't been acknowledged, try sending it.
                // This handles scenarios where a connection might exist from a previous attempt.
                if currentSocketStatus == .connected && !self.cacheQueue.sync { self.handshakeAcknowledged } {
                    self.sendHandshake(projectId: projectId)
                }
                return
            }
            
            // Disconnect any existing manager before creating a new one to ensure a clean state.
            self.manager?.disconnect()
            
            // Configure the Socket.IO client.
            // These settings were found to be crucial for reliable connection in previous debugging.
            let socketClientConfig: SocketIOClientConfiguration = [
                .log(self.debugLogsEnabled), // Enable/disable Socket.IO library's internal logging.
                .compress,                   // Enable message compression.
                .reconnects(true),           // Allow automatic reconnections.
                .reconnectAttempts(-1),      // Retry indefinitely.
                .reconnectWait(3),           // Initial wait time before reconnect attempt (seconds).
                .reconnectWaitMax(10),       // Maximum wait time between reconnect attempts.
                .forceWebsockets(true),      // IMPORTANT: Use WebSockets only
                .secure(true),               // IMPORTANT: Explicitly state that WSS is a secure connection.
                .selfSigned(false),          // IMPORTANT: Set to false for publicly trusted certs (like Let's Encrypt).
                .path("/socket.io/")         // IMPORTANT: Explicitly set the Socket.IO connection path.
            ]
            
            if self.debugLogsEnabled { print("🔌 Creating new SocketManager for URL: \(socketConnectionUrl) with path: /socket.io/") }
            self.manager = SocketManager(socketURL: self.socketIOUrl, config: socketClientConfig)
            
            guard let currentManager = self.manager else {
                self.logError("Failed to initialize SocketManager. Socket connection aborted."); return
            }
            
            self.socket = currentManager.defaultSocket // Get the default socket client.
            
            if self.debugLogsEnabled { print("🔌 Attempting socket.connect()...") }
            self.setupSocketHandlers(projectId: projectId) // Register event listeners.
            self.socket?.connect()                         // Initiate the connection.
        }
    }
    
    /// Sets up the necessary event handlers (listeners) for the Socket.IO client.
    /// This includes handlers for connection, disconnection, errors, and custom server events.
    ///
    /// - Parameter projectId: The project ID, required for sending the handshake.
    private func setupSocketHandlers(projectId: String) {
        guard let currentActiveSocket = socket else {
            logError("setupSocketHandlers failed: SocketIOClient instance is nil.")
            return
        }
        
        if debugLogsEnabled {
            print("👂 Setting up socket event handlers. Current Socket ID (if connected): \(currentActiveSocket.sid ?? "N/A"), Namespace: \(currentActiveSocket.nsp)")
        }
        
        // --- Clear Old Handlers (Best Practice) ---
        // Remove any existing handlers to prevent duplicates if `setupSocketHandlers` is called multiple times.
        currentActiveSocket.off(clientEvent: .connect)
        currentActiveSocket.off("handshake_ack") // Custom event for handshake acknowledgement.
        currentActiveSocket.off("translationsUpdated") // Custom event for content updates.
        currentActiveSocket.off("dataStoreUpdated")
        currentActiveSocket.off(clientEvent: .disconnect)
        currentActiveSocket.off(clientEvent: .error)
        currentActiveSocket.off(clientEvent: .reconnect)
        currentActiveSocket.off(clientEvent: .reconnectAttempt)
        currentActiveSocket.off(clientEvent: .statusChange) // For observing connection status changes.
        
        // --- Universal Event Logger (for debugging all incoming events) ---
        currentActiveSocket.onAny { [weak self] event in
            if self?.debugLogsEnabled ?? false {
                print("📡 Socket Event (onAny): '\(event.event)', Items: \(event.items)")
            }
        }
        
        // --- Standard Socket.IO Client Events ---
        
        // Called when the socket successfully connects.
        currentActiveSocket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("🟢✅ Socket connected successfully! SID: \(self.socket?.sid ?? "N/A")") }
            // Reset handshake status on new connection and send handshake.
            self.cacheQueue.async { self.handshakeAcknowledged = false }
            self.sendHandshake(projectId: projectId) // Send the legacy handshake payload.
        }
        
        // Called when the socket disconnects.
        currentActiveSocket.on(clientEvent: .disconnect) { [weak self] data, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("🔌 Socket disconnected. Reason: \(data)") }
            // Reset handshake status on disconnect.
            self.cacheQueue.async { self.handshakeAcknowledged = false }
        }
        
        // Called when a socket error occurs.
        currentActiveSocket.on(clientEvent: .error) { [weak self] data, _ in
            guard let self = self else { return }
            // Attempt to cast error data to `Error` for more specific logging.
            if let error = data.first as? Error {
                self.logError("Socket error event: \(error.localizedDescription). Full data: \(data)")
            } else {
                self.logError("Socket error event with unknown data format: \(data)")
            }
        }
        
        // Called when the socket successfully reconnects after a disconnection.
        currentActiveSocket.on(clientEvent: .reconnect) { [weak self] data, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("🔁 Socket reconnected successfully. Data: \(data)") }
            // The '.connect' handler should fire again automatically, which will trigger a new handshake.
        }
        
        // Called when the client is attempting to reconnect.
        currentActiveSocket.on(clientEvent: .reconnectAttempt) { [weak self] data, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("🔁 Socket attempting to reconnect... Details: \(data)") }
            // Consider if `handshakeAcknowledged` should be reset here or only on full disconnect/connect.
        }
        
        // Called when the socket's status changes (e.g., connecting, connected, disconnected).
        currentActiveSocket.on(clientEvent: .statusChange) { [weak self] data, _ in
            guard let self = self else { return }
            // `data.first` might contain the new status. `self.socket?.status` is more reliable.
            if self.debugLogsEnabled { print("ℹ️ Socket status changed to: \(self.socket?.status.description ?? "Unknown")") }
        }
        
        // --- Custom Server-Sent Events ---
        
        // Handler for the 'handshake_ack' event from the server.
        currentActiveSocket.on("handshake_ack") { [weak self] data, ackEmitter in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("👋 Received 'handshake_ack' from server. Data: \(data)") }
            
            // TODO: Optionally validate the data received with the handshake_ack if it contains useful info.
            // For example: if let ackData = data.first as? [String: Any], ackData["status"] as? String == "ok"
            
            self.cacheQueue.async { self.handshakeAcknowledged = true } // Mark handshake as successful.
            if self.debugLogsEnabled { print("🤝 Handshake successfully acknowledged by the server.") }
            
            self.syncIfOutdated() // Perform a content sync after successful handshake.
        }
        
        // Handler for the 'translationsUpdated' event, indicating content changes on the server.
        currentActiveSocket.on("translationsUpdated") { [weak self] data, _ in
            guard let self = self else { return }
            if self.debugLogsEnabled { print("📡 Received 'translationsUpdated' event from server. Data: \(data)") }
            self.handleSocketTranslationUpdate(data: data) // Process the update.
        }
        
        currentActiveSocket.on("dataStoreUpdated") { [weak self] data, ack in
            guard let self = self,
                  let payload = data[0] as? [String: Any],
                  let storeApiIdentifier = payload["storeApiIdentifier"] as? String else {
                return
            }
            
            if self.debugLogsEnabled { print("📡 Received 'dataStoreUpdated' event for store: '\(storeApiIdentifier)'. Triggering sync.") }
            
            // --- ENHANCEMENT 3: The socket event now triggers a sync. ---
            // The sync function will, upon completion, post a global notification
            // that all Cure observable objects (including CureDataStore) listen to.
            self.syncStore(apiIdentifier: storeApiIdentifier) { success in
                // The update is now handled automatically by the CureDataStore object's subscription.
                // No need to manually call a specific handler here.
            }
        }
        
        if debugLogsEnabled { print("👂✅ Socket event handlers setup complete.") }
    }
    
    /// Sends the encrypted handshake message to the Socket.IO server.
    /// This is a legacy handshake mechanism using `projectSecret` for encryption.
    ///
    /// - Parameter projectId: The project ID to include in the handshake payload.
    private func sendHandshake(projectId: String) {
        var projectSecretForHandshake: String?
        // Safely read the projectSecret from the configuration.
        cacheQueue.sync { projectSecretForHandshake = self.configuration?.projectSecret }
        
        guard let secret = projectSecretForHandshake, !secret.isEmpty else {
            if debugLogsEnabled { print("❌ Cannot send legacy handshake: Project secret is not available in configuration.") }
            return
        }
        
        // --- Encrypt Handshake Payload (Legacy Method) ---
        // This encryption is performed synchronously on the cacheQueue to safely access/derive keys.
        let encryptedPayloadData: Data? = cacheQueue.sync {
            guard let secretUtf8Data = secret.data(using: .utf8) else {
                self.logError("Handshake encryption failed: Could not convert projectSecret to UTF-8 data."); return nil
            }
            // Derive the AES.GCM key from the project secret using SHA256.
            let handshakeEncryptionKey = SymmetricKey(data: SHA256.hash(data: secretUtf8Data))
            
            let handshakeBody: [String: String] = ["projectId": projectId] // The actual data to encrypt.
            guard let jsonDataToEncrypt = try? JSONSerialization.data(withJSONObject: handshakeBody) else {
                self.logError("Handshake encryption failed: Could not serialize handshake body to JSON."); return nil
            }
            
            do {
                // Perform AES.GCM encryption.
                let sealedBox = try AES.GCM.seal(jsonDataToEncrypt, using: handshakeEncryptionKey)
                
                // Prepare the payload structure expected by the backend for the encrypted handshake.
                let encryptedResultPayload: [String: String] = [
                    "iv": sealedBox.nonce.withUnsafeBytes { Data($0).base64EncodedString() }, // Initialization Vector (Nonce)
                    "ciphertext": sealedBox.ciphertext.base64EncodedString(),               // Encrypted Data
                    "tag": sealedBox.tag.base64EncodedString()                               // Authentication Tag
                ]
                return try JSONSerialization.data(withJSONObject: encryptedResultPayload)
            } catch {
                self.logError("Handshake encryption failed during AES.GCM sealing or final serialization: \(error)"); return nil
            }
        }
        
        guard let finalEncryptedData = encryptedPayloadData,
              var handshakePayloadDictionary = try? JSONSerialization.jsonObject(with: finalEncryptedData, options: []) as? [String: Any] else {
            if self.debugLogsEnabled { print("❌ Failed to prepare or serialize the final encrypted handshake payload for emission.") }; return
        }
        
        // Some backends might expect the plain `projectId` alongside the encrypted data block.
        handshakePayloadDictionary["projectId"] = projectId
        
        if self.debugLogsEnabled {
            print("🤝 Sending legacy handshake to server...")
            // Avoid logging the full encrypted content directly if it's sensitive.
            // Instead, log keys or structure for verification.
            print("   - Handshake Payload Keys: \(handshakePayloadDictionary.keys.joined(separator: ", "))")
        }
        
        // Emit the "handshake" event to the server. Socket emissions should be on the main thread.
        DispatchQueue.main.async {
            self.socket?.emit("handshake", handshakePayloadDictionary)
        }
    }
    
    /// Handles an incoming 'translationsUpdated' message from the Socket.IO server.
    /// This message indicates that content for one or all tabs has changed on the server.
    ///
    /// - Parameter data: The data array received with the socket event. Expected to contain a dictionary.
    private func handleSocketTranslationUpdate(data: [Any]) {
        guard let updateInfo = data.first as? [String: Any],
              let screenNameToUpdate = updateInfo["screenName"] as? String else {
            if self.debugLogsEnabled { print("⚠️ Invalid data format for 'translationsUpdated' socket event: \(data)") }
            return
        }
        
        if self.debugLogsEnabled { print("📡 Processing 'translationsUpdated' event for tab: '\(screenNameToUpdate)'") }
        
        if screenNameToUpdate.uppercased() == "__ALL__" {
            // If "__ALL__" is received, trigger a sync for all outdated tabs.
            self.syncIfOutdated()
        } else {
            // Sync only the specific tab mentioned in the update.
            self.sync(screenName: screenNameToUpdate) { success in
                if !success && self.debugLogsEnabled {
                    print("⚠️ Sync failed for tab '\(screenNameToUpdate)' triggered by socket update.")
                }
            }
        }
    }
    
    /// Attempts to connect the socket if the SDK is configured and necessary secrets are available.
    /// This function is typically called after `configure()` or by app lifecycle events (e.g., app becoming active).
    public func startListening() {
        guard let currentConfig = getCurrentConfiguration() else {
            if debugLogsEnabled { print("ℹ️ `startListening` called, but SDK is not configured. Socket connection deferred.") }
            return
        }
        
        // For legacy handshake, projectSecret is essential.
        guard !currentConfig.projectSecret.isEmpty else {
            if debugLogsEnabled { print("ℹ️ `startListening` called, but Project Secret is missing in the configuration. Cannot connect socket for legacy handshake.") }
            return
        }
        
        // Add safety check for socket URL
        guard let _ = self.socketIOUrl else {
            logError("Cannot start listening: Socket URL is not initialized.")
            return
        }
        
        // Proceed with connection attempt as configuration and necessary secrets are present.
        logDebug("`startListening` called: Configuration and projectSecret are present. Attempting socket connection...")
        print("🔗 Connecting to socket endpoint: \(self.socketIOUrl.absoluteString)")
        
        // Add try-catch around socket connection
        do {
            connectSocket() // `connectSocket` handles the actual connection logic using details from `currentConfig`.
        } catch {
            logError("Failed to connect socket: \(error)")
        }
    }
    
    /// Disconnects the Socket.IO client and releases related resources.
    public func stopListening() {
        DispatchQueue.main.async { [weak self] in // Ensure socket operations are on the main thread.
            guard let self = self else { return }
            
            self.manager?.disconnect() // Instruct the manager to disconnect all sockets.
            self.socket = nil          // Release the strong reference to the socket client.
            self.manager = nil         // Release the strong reference to the socket manager.
            
            // Reset handshake status on the cacheQueue.
            self.cacheQueue.async { self.handshakeAcknowledged = false }
            
            if self.debugLogsEnabled { print("🔌 Socket disconnect explicitly requested. Manager and socket resources released.") }
        }
    }
    
    /// Checks if the Socket.IO client is currently connected.
    /// - Returns: `true` if the socket status is `.connected`, `false` otherwise.
    public func isConnected() -> Bool {
        var currentStatus: SocketIOStatus = .notConnected
        // Accessing `manager.status` should ideally be thread-safe or done on the main thread
        // if the manager itself isn't internally synchronized for status checks.
        // Using `DispatchQueue.main.sync` if called from a background thread ensures safety.
        if Thread.isMainThread {
            currentStatus = manager?.status ?? .notConnected
        } else {
            DispatchQueue.main.sync {
                currentStatus = manager?.status ?? .notConnected
            }
        }
        return currentStatus == .connected
    }
    
    
    // MARK: - Persistence Layer (Cache, Tabs, Legacy Config)
    // These methods handle saving and loading SDK data to/from disk.
    // They are designed to be called from within `cacheQueue` for thread safety if modifying shared state,
    // or are internally thread-safe for read operations if needed.
    
    /// Saves the current in-memory content cache (`self.cache`) to `cache.json` on disk.
    /// **Note:** This method assumes it's being called from a context that already synchronizes
    /// access to `self.cache` (e.g., from within `cacheQueue.async(flags: .barrier)`).
    private func saveCacheToDisk() {
        // `self.cache` is accessed here. Ensure calling context is `cacheQueue`.
        let cacheDataToSave = self.cache
        do {
            let encodedData = try JSONEncoder().encode(cacheDataToSave)
            try encodedData.write(to: self.cacheFilePath, options: .atomic)
            // if debugLogsEnabled { print("💾 Content cache saved to disk at \(self.cacheFilePath.lastPathComponent).") }
        } catch {
            logError("Failed to save content cache to disk: \(error)")
        }
    }
    
    private func saveDataStoreListToDisk() {
        let listToSave = self.offlineDataStoreList
        do {
            let encodedData = try JSONEncoder().encode(listToSave)
            try encodedData.write(to: self.dataStoreListFilePath, options: .atomic)
        } catch {
            logError("Failed to save data store list to disk: \(error)")
        }
    }
    
    private func loadDataStoreListFromDisk() {
        guard FileManager.default.fileExists(atPath: self.dataStoreListFilePath.path) else { return }
        do {
            let data = try Data(contentsOf: self.dataStoreListFilePath)
            self.offlineDataStoreList = try JSONDecoder().decode([String].self, from: data)
            self.knownDataStoreIdentifiers = Set(self.offlineDataStoreList)
        } catch {
            logError("Failed to load or decode data store list from disk: \(error).")
        }
    }
    
    // In the "Persistence Layer" section, add these two new methods for saving and loading the data store cache:
    private func saveDataStoreCacheToDisk() {
        let cacheToSave = self.dataStoreCache
        do {
            let encodedData = try JSONEncoder().encode(cacheToSave)
            try encodedData.write(to: self.dataStoreCacheFilePath, options: .atomic)
        } catch {
            logError("Failed to save data store cache to disk: \(error)")
        }
    }
    
    private func loadDataStoreCacheFromDisk() {
        guard FileManager.default.fileExists(atPath: self.dataStoreCacheFilePath.path) else { return }
        do {
            let data = try Data(contentsOf: self.dataStoreCacheFilePath)
            self.dataStoreCache = try JSONDecoder().decode([String: [DataStoreItem]].self, from: data)
            if debugLogsEnabled { print("📦 Data Store cache loaded successfully.") }
        } catch {
            logError("Failed to load or decode data store cache from disk: \(error). Removing if problematic.")
            try? FileManager.default.removeItem(at: self.dataStoreCacheFilePath)
        }
    }
    
    /// Loads the content cache from `cache.json` on disk during SDK initialization.
    /// This method populates `self.cache` and then calls `loadOfflineTabListFromDisk`.
    /// This is called synchronously during `init()`, so direct modification of `self.cache` is safe here.
    private func loadCacheFromDisk() {
        guard FileManager.default.fileExists(atPath: self.cacheFilePath.path) else {
            if debugLogsEnabled { print("ℹ️ Cache file not found at \(self.cacheFilePath.lastPathComponent). Starting with an empty cache.") }
            return
        }
        
        do {
            let data = try Data(contentsOf: self.cacheFilePath)
            // Try to decode the data. If it fails, the cache might be corrupted.
            if let loadedCacheData = try? JSONDecoder().decode([String: [String: [String: String]]].self, from: data) {
                self.cache = loadedCacheData
                // if debugLogsEnabled { print("📦 Content cache loaded successfully from \(self.cacheFilePath.lastPathComponent).") }
            } else {
                // If decoding fails, log it and consider removing the corrupted file.
                if debugLogsEnabled { print("⚠️ Failed to decode cache file at \(self.cacheFilePath.lastPathComponent). The file might be corrupted. Removing it.") }
                try? FileManager.default.removeItem(at: self.cacheFilePath)
            }
            // Always attempt to load the tab list after trying to load the cache.
            loadOfflineTabListFromDisk()
        } catch {
            // Handle errors like file read permission issues.
            if debugLogsEnabled { print("❌ Failed to load cache file from \(self.cacheFilePath.lastPathComponent). Error: \(error). Removing if problematic.") }
            try? FileManager.default.removeItem(at: self.cacheFilePath) // Attempt to remove on other errors too.
        }
    }
    
    /// Saves the current list of known project tabs (`self.offlineTabList`) to `tabs.json` on disk.
    /// **Note:** Assumes calling context synchronizes access to `self.offlineTabList` (e.g., `cacheQueue`).
    private func saveOfflineTabListToDisk() {
        // `self.offlineTabList` is accessed. Ensure calling context is `cacheQueue`.
        let tabListToSave = self.offlineTabList
        do {
            let encodedData = try JSONEncoder().encode(tabListToSave)
            try encodedData.write(to: self.tabsFilePath, options: .atomic)
            // if debugLogsEnabled { print("💾 Known tabs list saved to disk at \(self.tabsFilePath.lastPathComponent).") }
        } catch {
            logError("Failed to save known tabs list to disk: \(error)")
        }
    }
    
    /// Loads the list of known project tabs from `tabs.json` during SDK initialization or cache load.
    /// This method populates `self.offlineTabList` and `self.knownProjectTabs`.
    /// Called synchronously during `init()` (via `loadCacheFromDisk`), direct modification is safe.
    private func loadOfflineTabListFromDisk() {
        guard FileManager.default.fileExists(atPath: self.tabsFilePath.path) else {
            // if debugLogsEnabled { print("ℹ️ Tabs file not found at \(self.tabsFilePath.lastPathComponent). Starting with no pre-loaded tabs.") }
            return
        }
        do {
            let data = try Data(contentsOf: self.tabsFilePath)
            self.offlineTabList = try JSONDecoder().decode([String].self, from: data)
            self.knownProjectTabs = Set(self.offlineTabList) // Synchronize the Set with the loaded Array.
            if debugLogsEnabled { print("📦 Offline tab list loaded from \(self.tabsFilePath.lastPathComponent): \(self.offlineTabList)") }
        } catch {
            if debugLogsEnabled { print("❌ Failed to load or decode known tabs list from \(self.tabsFilePath.lastPathComponent). Error: \(error). Removing if problematic.") }
            try? FileManager.default.removeItem(at: self.tabsFilePath)
        }
    }
    
    /// Saves legacy authentication configuration (e.g., token, project secret) to `config.json`.
    /// This is typically called after a successful legacy authentication.
    /// **Note:** Assumes this method might be called from a completion handler which itself is on `cacheQueue` or appropriately dispatched.
    ///
    /// - Parameter configData: A dictionary containing the configuration key-value pairs to save.
    /// - Returns: `true` if saving was successful, `false` otherwise.
    private func saveLegacyConfigToDisk(_ configData: [String: String]) -> Bool {
        do {
            // Ensure the "CMSCureSDK" directory exists.
            try FileManager.default.createDirectory(at: configFilePath.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let jsonData = try JSONSerialization.data(withJSONObject: configData, options: .prettyPrinted)
            try jsonData.write(to: self.configFilePath, options: .atomic)
            if self.debugLogsEnabled { print("💾 Saved legacy config data to \(self.configFilePath.lastPathComponent).") }
            return true
        } catch {
            logError("Failed to save legacy config data to disk: \(error)")
            return false
        }
    }
    
    /// Reads legacy authentication configuration from `config.json`.
    /// This is typically called during SDK initialization.
    ///
    /// - Returns: A dictionary with the loaded configuration, or `nil` if the file doesn't exist or an error occurs.
    private func readLegacyConfigFromDisk() -> [String: String]? {
        guard FileManager.default.fileExists(atPath: configFilePath.path) else { return nil }
        guard let fileData = try? Data(contentsOf: configFilePath),
              let jsonObject = try? JSONSerialization.jsonObject(with: fileData) as? [String: String] else {
            if debugLogsEnabled { print("⚠️ Could not read or parse legacy config file at \(configFilePath.lastPathComponent).") }
            return nil
        }
        // if debugLogsEnabled { print("📦 Legacy config loaded from \(configFilePath.lastPathComponent).") }
        return jsonObject
    }
    
    // MARK: - Application Lifecycle
    
    /// Observes the `UIApplication.didBecomeActiveNotification` to trigger actions when the app returns to the foreground.
    private func observeAppActiveNotification() {
#if canImport(UIKit) && !os(watchOS) // Ensure UIKit is available and not on watchOS.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
#endif
    }
    
    /// Selector called when the app becomes active.
    /// This typically triggers a socket connection attempt (if not already connected) and a content sync.
    @objc private func appDidBecomeActive() {
        if self.debugLogsEnabled { print("📲 App did become active. Checking socket status and syncing outdated content.") }
        // `startListening()` will check if SDK is configured and if socket needs connecting.
        // It's now called at the end of `configure` and also potentially here if we want to ensure connection on app active.
        // However, if relying on `configure`'s call, this might be redundant or just for `syncIfOutdated`.
        // Let's ensure `startListening` is robust enough to be called multiple times. (It checks status).
        // If `startListening` is primarily for initial setup, `syncIfOutdated` is the main goal here.
        
        // Re-evaluate connection if not connected:
        if !isConnected() {
            startListening() // Attempt to connect if not already.
        }
        syncIfOutdated() // Always check for outdated content on app active.
    }
    
    // MARK: - Legacy Encryption Helper
    
    /// Encrypts a dictionary payload using AES.GCM with the SDK's derived symmetric key.
    /// This is used for legacy backend endpoints that expect encrypted request bodies.
    ///
    /// **Important:** This method MUST be called from within `cacheQueue` to ensure thread-safe
    /// access to `self.symmetricKey`.
    ///
    /// - Parameter body: The dictionary to encrypt.
    /// - Returns: Encrypted `Data` in the format expected by the legacy backend, or `nil` if encryption fails.
    private func encryptBody(_ body: [String: Any]) -> Data? {
        // This assertion helps catch incorrect usage during development.
        // dispatchPrecondition(condition: .onQueue(cacheQueue)) // Uncomment if desired, but ensure it doesn't deadlock.
        
        guard let currentSymmetricKey = self.symmetricKey else {
            logError("Legacy body encryption failed: Symmetric key is not available/derived."); return nil
        }
        guard let jsonDataToEncrypt = try? JSONSerialization.data(withJSONObject: body) else {
            logError("Legacy body encryption failed: Could not serialize request body to JSON."); return nil
        }
        
        do {
            // Perform AES.GCM encryption.
            let sealedBox = try AES.GCM.seal(jsonDataToEncrypt, using: currentSymmetricKey)
            
            // Structure the encrypted components (IV, ciphertext, tag) as expected by the legacy backend.
            let encryptedPayloadStructure: [String: String] = [
                "iv": sealedBox.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
                "ciphertext": sealedBox.ciphertext.base64EncodedString(),
                "tag": sealedBox.tag.base64EncodedString()
            ]
            return try JSONSerialization.data(withJSONObject: encryptedPayloadStructure)
        } catch {
            logError("Legacy body encryption failed during AES.GCM sealing or final serialization: \(error)"); return nil
        }
    }
    
    // MARK: - Update Notification & Handling
    
    /// Registers a handler to be called when translations for a specific screen name (tab) are updated.
    ///
    /// When a handler is registered, it will be immediately called with the current cached translations
    /// for that screen if they exist or if the tab has been synced at least once.
    ///
    /// - Parameters:
    ///   - screenName: The name of the tab/screen to observe for updates.
    ///   - handler: A closure that takes a dictionary of `[String: String]` (key-value translations for the current language)
    ///              and is called on the main thread when updates occur.
    public func onTranslationsUpdated(for screenName: String, handler: @escaping ([String: String]) -> Void) {
        DispatchQueue.main.async { // Ensure handler registration and initial callback are on the main thread.
            self.translationUpdateHandlers[screenName] = handler

            // Immediately provide current cached values to the new handler.
            let currentLanguageKey = self.getLanguage() // Thread-safe language get.
            let currentValuesForScreen = self.getCachedTranslations(for: screenName, language: currentLanguageKey) // Thread-safe cache get.

            // Call handler if values exist or if we know this tab has been synced (even if empty).
            if !currentValuesForScreen.isEmpty || self.isTabSynced(screenName) {
                handler(currentValuesForScreen)
            }
        }
    }

    /// Registers the SDK's own handlers without interfering with integrator-provided handlers.
    /// Mirrors the semantics of `onTranslationsUpdated` so internal logic can reuse it safely.
    private func registerInternalTranslationHandler(for screenName: String, handler: @escaping ([String: String]) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.internalTranslationUpdateHandlers[screenName] = handler

            let currentLanguageKey = self.getLanguage()
            let currentValuesForScreen = self.getCachedTranslations(for: screenName, language: currentLanguageKey)
            if !currentValuesForScreen.isEmpty || self.isTabSynced(screenName) {
                handler(currentValuesForScreen)
            }
        }
    }
    
    /// Automatically subscribes to real-time updates for a screen accessed via translation() method.
    /// This method is called internally and provides seamless real-time behavior without breaking changes.
    ///
    /// **Key Features:**
    /// - Tracks accessed screens to avoid duplicate subscriptions
    /// - Sets up minimal overhead background sync if not already synced
    /// - Maintains performance by using intelligent subscription management
    /// - Thread-safe and non-blocking for the translation() method
    ///
    /// - Parameter screenName: The name of the screen/tab to auto-subscribe
    private func autoSubscribeToScreen(_ screenName: String) {
        // Check if auto real-time updates are enabled in configuration
        guard let config = getCurrentConfiguration(), config.enableAutoRealTimeUpdates else {
            return // Auto real-time updates disabled, use traditional behavior
        }
        
        // Check and update subscription status on main thread to avoid race conditions
        var shouldSubscribe = false
        var shouldSync = false
        
        // Use async to avoid blocking the translation() method
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Check if already subscribed
            if !self.autoSubscribedScreens.contains(screenName) {
                self.autoSubscribedScreens.insert(screenName)
                shouldSubscribe = true
            }
            
            // Check if needs syncing
            shouldSync = !self.isTabSynced(screenName)
            
            // Only proceed if this is the first time accessing this screen
            guard shouldSubscribe else { return }
            
            // Set up real-time subscription for this screen using an internal handler
            self.registerInternalTranslationHandler(for: screenName) { [weak self] updatedTranslations in
                self?.logDebug("Auto-subscription: Screen '\(screenName)' updated with \(updatedTranslations.count) translations")
            }
            
            // Ensure the screen data is synced if not already
            if shouldSync {
                self.sync(screenName: screenName) { success in
                    if success {
                        self.logDebug("Auto-subscription: Successfully synced screen '\(screenName)'")
                    } else {
                        self.logError("Auto-subscription: Failed to sync screen '\(screenName)'")
                    }
                }
            }
        }
    }
    
    /// Automatically subscribes to real-time updates for colors accessed via colorValue() method.
    /// This method is called internally and provides seamless real-time behavior without breaking changes.
    ///
    /// **Key Features:**
    /// - Tracks color access to avoid duplicate subscriptions
    /// - Sets up minimal overhead background sync if not already synced
    /// - Maintains performance by using intelligent subscription management
    /// - Thread-safe and non-blocking for the colorValue() method
    private func autoSubscribeToColors() {
        guard let config = getCurrentConfiguration(), config.enableAutoRealTimeUpdates else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var shouldSubscribe = false
            if !self.autoSubscribedColors {
                self.autoSubscribedColors = true
                shouldSubscribe = true
            }
            
            guard shouldSubscribe else { return }
            
            if self.internalTranslationUpdateHandlers["__colors__"] == nil {
                self.registerInternalTranslationHandler(for: "__colors__") { [weak self] updatedColors in
                    self?.logDebug("Auto-subscription: Colors updated with \(updatedColors.count) entries")
                }
            }
            
            if !self.isTabSynced("__colors__") {
                self.sync(screenName: "__colors__") { success in
                    if success {
                        self.logDebug("Auto-subscription: Successfully synced colors")
                    } else {
                        self.logError("Auto-subscription: Failed to sync colors")
                    }
                }
            }
        }
    }
    
    /// Automatically subscribes to real-time updates for global images accessed via imageURL() method.
    /// This method is called internally and provides seamless real-time behavior without breaking changes.
    ///
    /// **Key Features:**
    /// - Tracks global image access to avoid duplicate subscriptions
    /// - Sets up minimal overhead background sync if not already synced
    /// - Maintains performance by using intelligent subscription management
    /// - Thread-safe and non-blocking for the imageURL() method
    private func autoSubscribeToGlobalImages() {
        guard let config = getCurrentConfiguration(), config.enableAutoRealTimeUpdates else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var shouldSubscribe = false
            if !self.autoSubscribedGlobalImages {
                self.autoSubscribedGlobalImages = true
                shouldSubscribe = true
            }
            
            guard shouldSubscribe else { return }
            
            if self.internalTranslationUpdateHandlers["__images__"] == nil {
                self.registerInternalTranslationHandler(for: "__images__") { [weak self] updatedImages in
                    self?.logDebug("Auto-subscription: Global images updated with \(updatedImages.count) entries")
                }
            }
            
            if !self.isTabSynced("__images__") {
                self.sync(screenName: "__images__") { success in
                    if success {
                        self.logDebug("Auto-subscription: Successfully synced global images")
                    } else {
                        self.logError("Auto-subscription: Failed to sync global images")
                    }
                }
            }
        }
    }
    
    /// Automatically subscribes to real-time updates for data stores accessed via getStoreItems() method.
    /// This method is called internally and provides seamless real-time behavior without breaking changes.
    ///
    /// **Key Features:**
    /// - Tracks accessed data stores to avoid duplicate subscriptions
    /// - Sets up minimal overhead background sync if not already synced
    /// - Maintains performance by using intelligent subscription management
    /// - Thread-safe and non-blocking for the getStoreItems() method
    ///
    /// - Parameter apiIdentifier: The unique API identifier of the data store to auto-subscribe
    private func autoSubscribeToDataStore(_ apiIdentifier: String) {
        guard let config = getCurrentConfiguration(), config.enableAutoRealTimeUpdates else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var shouldSubscribe = false
            if !self.autoSubscribedDataStores.contains(apiIdentifier) {
                self.autoSubscribedDataStores.insert(apiIdentifier)
                shouldSubscribe = true
            }
            
            guard shouldSubscribe else { return }
            
            self.syncStore(apiIdentifier: apiIdentifier) { success in
                if success {
                    self.logDebug("Auto-subscription: Successfully synced data store '\(apiIdentifier)'")
                } else {
                    self.logError("Auto-subscription: Failed to sync data store '\(apiIdentifier)'")
                }
            }
        }
    }
    
    /// Posts a general `Notification.Name.translationsUpdated` notification.
    /// Also updates a shared `refreshToken` to trigger SwiftUI view updates via `CureTranslationBridge`.
    /// Must be called on the main thread.
    ///
    /// - Parameter screenName: The name of the screen/tab that was updated.
    private func postTranslationsUpdatedNotification(screenName: String) {
        // Ensure this method is always called on the main thread.
        dispatchPrecondition(condition: .onQueue(.main))
        
        let newRefreshToken = UUID() // Generate a new UUID to force SwiftUI updates.
        if debugLogsEnabled { print("📬 Posting `translationsUpdated` notification for tab '\(screenName)'. New Refresh Token: \(newRefreshToken)") }
        
        // Update the shared bridge for SwiftUI.
        CureTranslationBridge.shared.refreshToken = newRefreshToken
        
        // Post a traditional NotificationCenter notification.
        NotificationCenter.default.post(
            name: .translationsUpdated,
            object: nil, // Sender is nil, or could be `self`.
            userInfo: ["screenName": screenName] // Include the updated screen name.
        )

#if canImport(UIKit) && !os(watchOS)
        triggerLegacyUIKitContentRefresh(screenName: screenName)
#endif
    }
    
    /// Notifies all registered handlers for a given screen name and posts a general update notification.
    /// Must be called on the main thread.
    ///
    /// - Parameters:
    ///   - screenName: The name of the screen/tab whose translations were updated.
    ///   - values: The new dictionary of `[Key: Value]` translations for the current language.
    private func notifyUpdateHandlers(screenName: String, values: [String: String]) {
        // Ensure this method is always called on the main thread.
        dispatchPrecondition(condition: .onQueue(.main))
        
        if debugLogsEnabled { print("📬 Notifying registered handlers for tab '\(screenName)'. Values count: \(values.count)") }
        
        // Allow the SDK's internal observers to react first.
        self.internalTranslationUpdateHandlers[screenName]?(values)

        // Call the specific handler registered by the host application, if any.
        self.translationUpdateHandlers[screenName]?(values)
        
        // ALWAYS update the bridge to trigger SwiftUI updates
        CureTranslationBridge.shared.refreshToken = UUID()
        
        // Post the general notification for broader listeners
        NotificationCenter.default.post(
            name: .translationsUpdated,
            object: nil,
            userInfo: ["screenName": screenName]
        )

#if canImport(UIKit) && !os(watchOS)
        triggerLegacyUIKitContentRefresh(screenName: screenName)
#endif
    }
    
#if canImport(UIKit) && !os(watchOS)
    private func triggerLegacyUIKitContentRefresh(screenName: String) {
        if Thread.isMainThread {
            performLegacyUIKitContentRefresh(screenName: screenName)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performLegacyUIKitContentRefresh(screenName: screenName)
            }
        }
    }
    
    private func performLegacyUIKitContentRefresh(screenName: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        
        let sharedApplicationSelector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: sharedApplicationSelector),
              let unmanagedApplication = UIApplication.perform(sharedApplicationSelector),
              let application = unmanagedApplication.takeUnretainedValue() as? UIApplication else {
            if debugLogsEnabled {
                print("ℹ️ UIKit legacy refresh skipped: UIApplication.shared unavailable.")
            }
            return
        }
        
        let candidateWindows: [UIWindow]
        if #available(iOS 13.0, tvOS 13.0, *) {
            candidateWindows = application.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
        } else {
            candidateWindows = application.windows
        }
        
        if candidateWindows.isEmpty {
            if debugLogsEnabled {
                print("ℹ️ UIKit legacy refresh skipped: No active windows found.")
            }
            return
        }
        
        if debugLogsEnabled {
            print("📣 UIKit legacy refresh triggered for '\(screenName)' on \(candidateWindows.count) window(s).")
        }
        
        var visitedControllers = Set<ObjectIdentifier>()
        for window in candidateWindows {
            if window.isHidden { continue }
            if #available(iOS 13.0, tvOS 13.0, *) {
                if let scene = window.windowScene,
                   scene.activationState != .foregroundActive {
                    continue
                }
            }
            
            if let rootViewController = window.rootViewController {
                notifyLegacyUIKitControllers(from: rootViewController, visited: &visitedControllers)
            }
        }
    }
    
    private func notifyLegacyUIKitControllers(from viewController: UIViewController, visited: inout Set<ObjectIdentifier>) {
        let identifier = ObjectIdentifier(viewController)
        guard !visited.contains(identifier) else { return }
        visited.insert(identifier)
        
        let isVisible = viewController.isViewLoaded && (viewController.viewIfLoaded?.window != nil)
        if viewController.responds(to: legacyUIKitContentUpdateSelector), isVisible {
            if debugLogsEnabled {
                print("📣 Invoking cmsContentDidUpdate on \(String(describing: type(of: viewController)))")
            }
            _ = viewController.perform(legacyUIKitContentUpdateSelector)
        }
        
        for child in viewController.children {
            notifyLegacyUIKitControllers(from: child, visited: &visited)
        }
        
        if let presented = viewController.presentedViewController {
            notifyLegacyUIKitControllers(from: presented, visited: &visited)
        }
        
        if let navigationController = viewController as? UINavigationController {
            for controller in navigationController.viewControllers {
                notifyLegacyUIKitControllers(from: controller, visited: &visited)
            }
        }
        
        if let tabBarController = viewController as? UITabBarController,
           let controllers = tabBarController.viewControllers {
            for controller in controllers {
                notifyLegacyUIKitControllers(from: controller, visited: &visited)
            }
        }
        
        if let splitViewController = viewController as? UISplitViewController {
            for controller in splitViewController.viewControllers {
                notifyLegacyUIKitControllers(from: controller, visited: &visited)
            }
        }
    }
#endif
    
    
    // MARK: - Available Languages Fetching
    
    /// Fetches the list of available language codes from the cached authentication response.
    ///
    /// This method requires the SDK to be configured. It returns the languages that were received
    /// during the authentication process. If no languages were received, it returns ["en"] as a fallback.
    ///
    /// - Parameter completion: A closure called on the main thread with an array of language code strings (e.g., `["en", "fr"]`).
    ///                       The array will contain at least one language (defaulting to "en").
    public func availableLanguages(completion: @escaping ([String]) -> Void) {
        guard getCurrentConfiguration() != nil else {
            logError("Cannot fetch available languages: SDK is not configured.")
            DispatchQueue.main.async { completion(["en"]) }
            return
        }
        
        // Return cached available languages from authentication response
        let languages = cacheQueue.sync { 
            return self.availableLanguagesList 
        }
        
        DispatchQueue.main.async { 
            completion(languages.isEmpty ? ["en"] : languages) 
        }
    }
    
    /// Provides a list of languages inferred from the keys present in the local cache.
    /// This is used as a fallback if fetching the language list from the server fails.
    /// This method is thread-safe.
    // MARK: - Utility Methods & Logging
    
    /// Checks if a specific tab has any data currently stored in the cache.
    /// This can be used to determine if a tab has been synced at least once.
    /// This method is thread-safe.
    ///
    /// - Parameter tabName: The name of the tab/screen to check.
    /// - Returns: `true` if the tab exists in the cache and has content, `false` otherwise.
    public func isTabSynced(_ tabName: String) -> Bool {
        return cacheQueue.sync { // Thread-safe read from the cache.
            // A tab is considered synced if it exists as a key in the cache
            // and its corresponding dictionary of keys is not empty.
            guard let tabCacheContent = cache[tabName] else { return false }
            return !tabCacheContent.isEmpty
        }
    }
    
    /// Internal helper for logging error messages. Prepends an SDK-specific error tag.
    /// - Parameter message: The error message to log.
    internal func logError(_ message: String) {
        // Check `debugLogsEnabled` if errors should also be conditional, though usually errors are always logged.
        print("🆘 [CMSCureSDK Error] \(message)")
    }
    
    /// Internal helper for logging debug messages. Prepends an SDK-specific debug tag.
    /// Debug messages are only printed if `debugLogsEnabled` is `true` AND the build configuration is DEBUG.
    /// - Parameter message: The debug message to log.
    internal func logDebug(_ message: String) {
        // Only print debug logs if the flag is enabled.
        guard debugLogsEnabled else { return }
        // Additionally, you might only want these in actual DEBUG builds.
#if DEBUG
        print("🛠️ [CMSCureSDK Debug] \(message)")
#endif
    }
    
    // MARK: - Helper Structures (Decodables, etc.)
    
    /// A private helper structure for decoding the JSON response from the legacy authentication endpoint.
    private struct AuthResult_OriginalWithTabs: Decodable {
        let token: String?          // The authentication token.
        let userId: String?         // Optional user ID.
        let projectId: String?      // Project ID, for confirmation.
        let projectSecret: String?  // Project Secret, for confirmation or update.
        let tabs: [String]?         // An array of known tab names for the project.
        let stores: [String]?       // Data store identifiers
        let availableLanguages: [String]? // Available languages for the project
    }
    
    // MARK: - Deinitialization
    
    /// Cleans up SDK resources, such as removing notification observers, invalidating timers,
    /// and disconnecting the socket, when the SDK singleton instance is deallocated.
    deinit {
        NotificationCenter.default.removeObserver(self) // Remove all observers added by this instance.
        stopListening()                                 // Ensure socket is disconnected and resources are released.
        if debugLogsEnabled { print("✨ CMSCureSDK Deinitialized and resources cleaned up.") }
    }
}

private struct TranslationResponse: Decodable {
    struct TranslationItem: Decodable {
        let key: String
        let values: [String: String]
    }
    let keys: [TranslationItem]
}

// MARK: - SwiftUI Color Helper Extension

extension Color {
    /// Initializes a `SwiftUI.Color` from a hexadecimal string.
    ///
    /// Supports hex strings with or without a leading "#", and expects 6 hex characters (RRGGBB).
    ///
    /// - Parameter hex: The hexadecimal color string (e.g., "#FF5733", "FF5733").
    ///                  Returns `nil` if the hex string is invalid or cannot be parsed.
    public init?(hex: String?) { // Made public for easier use by apps if needed directly
        guard var hexSanitized = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        guard hexSanitized.count == 6 else { return nil } // Must be RRGGBB format.
        
        var rgbValue: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgbValue) else { return nil } // Parse hex to integer.
        
        // Extract Red, Green, Blue components and normalize to 0.0-1.0 range.
        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0
        
        self.init(red: red, green: green, blue: blue)
    }
}

// MARK: - Custom Notification Name

extension Notification.Name {
    /// Notification posted when translations are updated, allowing other parts of the app to react.
    /// The `userInfo` dictionary of the notification may contain a "screenName" key.
    public static let translationsUpdated = Notification.Name("CMSCureTranslationsUpdatedNotification")
}

// MARK: - Custom Error Enum

/// Defines common errors that can be thrown or encountered by the CMSCureSDK.
public enum CMSCureSDKError: Error, LocalizedError { // Made public and conforming to LocalizedError
    case notConfigured
    case missingInitialCredentials(String) // E.g., missing projectId, apiKey, or projectSecret during configure.
    case missingRequiredSecretsForOperation(String) // E.g., symmetric key not derived for encryption.
    case invalidURL(String)
    case invalidResponse // General invalid response from server.
    case decodingFailed(Error, rawData: Data?) // Include original decoding error and raw data.
    case syncFailed(tabName: String, underlyingError: Error?)
    case socketConnectionFailed(Error?)
    case socketDisconnected(reason: String?)
    case socketHandshakeFailed
    case encryptionFailed(Error?)
    case configurationError(String) // General configuration issues.
    case authenticationFailed(String?) // More specific auth failure.
    case networkError(Error) // Underlying URLSession error.
    case serverError(statusCode: Int, message: String?, data: Data?)
    
    public var errorDescription: String? {
        switch self {
            case .notConfigured:
                return "CMSCureSDK has not been configured. Please call CMSCureSDK.shared.configure() first."
            case .missingInitialCredentials(let detail):
                return "CMSCureSDK configuration failed: \(detail)."
            case .missingRequiredSecretsForOperation(let operation):
                return "CMSCureSDK operation '\(operation)' failed: Required secrets (e.g., symmetric key) are missing."
            case .invalidURL(let urlString):
                return "Invalid URL provided: \(urlString)."
            case .invalidResponse:
                return "Received an invalid or unexpected response from the server."
            case .decodingFailed(let error, let rawData):
                let dataHint = rawData.flatMap { String(data: $0, encoding: .utf8) } ?? "No raw data"
                return "Failed to decode server response. Error: \(error.localizedDescription). Raw data snippet: \(dataHint.prefix(100))."
            case .syncFailed(let tabName, let underlyingError):
                return "Synchronization failed for tab '\(tabName)'." + (underlyingError != nil ? " Details: \(underlyingError!.localizedDescription)" : "")
            case .socketConnectionFailed(let error):
                return "Socket.IO connection failed." + (error != nil ? " Error: \(error!.localizedDescription)" : "")
            case .socketDisconnected(let reason):
                return "Socket.IO connection was disconnected." + (reason != nil ? " Reason: \(reason!)" : "")
            case .socketHandshakeFailed:
                return "Socket.IO handshake with the server failed."
            case .encryptionFailed(let error):
                return "Data encryption or decryption failed." + (error != nil ? " Error: \(error!.localizedDescription)" : "")
            case .configurationError(let message):
                return "SDK Configuration Error: \(message)."
            case .authenticationFailed(let message):
                return "Authentication failed." + (message != nil ? " Details: \(message!)" : "")
            case .networkError(let error):
                return "A network error occurred: \(error.localizedDescription)."
            case .serverError(let statusCode, let message, _):
                return "Server returned an error: Status Code \(statusCode)." + (message != nil ? " Message: \(message!)" : "")
        }
    }
}

// MARK: - String Extension for SwiftUI Convenience

extension String {
    /// A private computed property that observes changes to the `CureTranslationBridge.refreshToken`.
    /// Accessing this property within a SwiftUI view (indirectly via `.cure(tab:)`) helps trigger view updates
    /// when translations change, because `refreshToken` is a `@Published` property.
    private var SwiftUIBridgeObserverTokenForString: UUID { CureTranslationBridge.shared.refreshToken }
    
    /// Retrieves the translation for the current string (used as a key) within a specified tab.
    /// This is a convenience method for use in SwiftUI views, automatically triggering updates when
    /// translations change via the `CureTranslationBridge`.
    ///
    /// - Parameter tab: The name of the tab/screen where the translation key is located.
    /// - Returns: The translated string for the current language, or an empty string if not found.
    ///
    /// Usage in SwiftUI:
    /// ```swift
    /// Text("my_greeting_key".cure(tab: "greetings_screen"))
    /// ```
    public func cure(tab: String) -> String {
        // By accessing `SwiftUIBridgeObserverTokenForString`, this computed property establishes a
        // dependency on `CureTranslationBridge.shared.refreshToken`. When `refreshToken` changes,
        // SwiftUI views using `.cure(tab:)` will be re-evaluated.
        _ = SwiftUIBridgeObserverTokenForString
        return Cure.shared.translation(for: self, inTab: tab)
    }
}

// MARK: - Observable Objects for SwiftUI Integration

/// A singleton bridge class used to trigger SwiftUI view updates when translations change.
///
/// SwiftUI views can observe the `refreshToken` property. When translations are updated
/// by the SDK, it changes `refreshToken`, causing dependent views to re-render.
internal final class CureTranslationBridge: ObservableObject { // Internal as its primary use is within SDK extensions
    /// Shared singleton instance of the bridge.
    static let shared = CureTranslationBridge()
    
    /// A `@Published` property that changes whenever translations are updated.
    /// SwiftUI views can observe this to refresh their content.
    @Published var refreshToken = UUID()
    
    private init() {} // Private initializer for singleton.
}

/// An `ObservableObject` wrapper for a single translated string, designed for easy use in SwiftUI.
///
/// It observes translation updates from the `CMSCureSDK` and automatically updates its `value` property,
/// triggering re-renders in SwiftUI views that use it.
///
/// Usage:
/// ```swift
/// struct MyView: View {
///     @StateObject var greeting = CureString("my_greeting_key", tab: "greetings_screen")
///
///     var body: some View {
///         Text(greeting.value)
///     }
/// }
/// ```
public final class CureString: ObservableObject {
    private let key: String
    private let tab: String
    private var cancellable: AnyCancellable? = nil // Stores the Combine subscription.
    
    /// The current translated string value. This property is `@Published`, so SwiftUI views
    /// will update when it changes.
    @Published public private(set) var value: String = ""
    
    /// Initializes a `CureString` object.
    /// - Parameters:
    ///   - key: The translation key.
    ///   - tab: The tab/screen name where the key is located.
    public init(_ key: String, tab: String) {
        self.key = key
        self.tab = tab
        // Set initial value from the cache.
        self.value = Cure.shared.translation(for: key, inTab: tab)
        
        // Subscribe to `refreshToken` changes from `CureTranslationBridge`.
        // When `refreshToken` changes, `updateValue()` is called on the main thread.
        cancellable = CureTranslationBridge.shared.$refreshToken
            .receive(on: DispatchQueue.main) // Ensure updates are on the main thread.
            .sink { [weak self] _ in
                self?.updateValue()
            }
    }
    
    /// Called when `CureTranslationBridge.refreshToken` changes.
    /// Fetches the latest translation and updates the `value` property if it has changed.
    private func updateValue() {
        let newValue = Cure.shared.translation(for: key, inTab: tab)
        if newValue != self.value { // Only update if the value has actually changed.
            self.value = newValue
        }
    }
}

/// An `ObservableObject` wrapper for a single color value (as `SwiftUI.Color`), designed for SwiftUI.
///
/// It observes updates from the `CMSCureSDK` (via `CureTranslationBridge`) and automatically
/// updates its `value` property when the underlying color hex string changes in the CMS.
///
/// Usage:
/// ```swift
/// struct MyView: View {
///     @StateObject var brandColor = CureColor("primary_brand_color")
///
///     var body: some View {
///         Rectangle().fill(brandColor.value ?? .gray) // Use a fallback color if nil.
///     }
/// }
/// ```
public final class CureColor: ObservableObject {
    private let key: String // The key for the color (e.g., "primary_background").
    private var cancellable: AnyCancellable? = nil
    
    /// The current `SwiftUI.Color` value. `@Published` for SwiftUI updates.
    /// This is optional because the color key might not exist or the hex string might be invalid.
    @Published public private(set) var value: Color?
    
    /// Initializes a `CureColor` object.
    /// - Parameter key: The global color key (expected to be in the `__colors__` tab).
    public init(_ key: String) {
        self.key = key
        // Set initial color value from the cache.
        self.value = Color(hex: Cure.shared.colorValue(for: key))
        
        // Subscribe to updates.
        cancellable = CureTranslationBridge.shared.$refreshToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateValue()
            }
    }
    
    /// Updates the color `value` by fetching the latest hex string from the SDK.
    private func updateValue() {
        let newColor = Color(hex: Cure.shared.colorValue(for: key))
        if newColor != self.value { // Only update if changed.
            self.value = newColor
        }
    }
}

/// An `ObservableObject` wrapper for an image URL, designed for SwiftUI.
///
/// It observes updates from `CMSCureSDK` and updates its `value` (the `URL`) when the
/// underlying image URL string changes in the CMS.
///
/// Usage:
/// ```swift
/// struct MyView: View {
///     @StateObject var logoImage = CureImage("logo_url_key", tab: "common_assets")
///
///     var body: some View {
///         if let imageUrl = logoImage.value {
///             AsyncImage(url: imageUrl) // Use with SwiftUI's AsyncImage or other image loaders.
///         } else {
///             Image(systemName: "photo") // Placeholder.
///         }
///     }
/// }
/// ```
public final class CureImage: ObservableObject {
    private let key: String?
    private let tab: String?
    private var cancellable: AnyCancellable? = nil
    
    /// The current `URL` for the image. `@Published` for SwiftUI updates.
    /// Optional because the key might not exist or the URL string might be invalid.
    @Published public private(set) var value: URL?
    
    /// Initializes a `CureImage` object.
    /// - Parameters:
    ///   - key: The key for the image URL.
    ///   - tab: The tab/screen name where the key is located.
    public init(_ key: String, tab: String) {
        self.key = key
        self.tab = tab
        // Determine initial value based on whether it's a global asset or not
        if tab == "__images__" {
            self.value = Cure.shared.imageURL(forKey: key)
        } else {
            self.value = Cure.shared.imageUrl(for: key, inTab: tab)
        }
        subscribeToUpdates()
    }
    
    /// Initializes a `CureImage` for a screen-independent, global image asset.
    public convenience init(assetKey: String) {
        // Use the special "__images__" tab to signify a global asset
        self.init(assetKey, tab: "__images__")
    }
    
    /// Subscribes to the central bridge to receive update notifications.
    private func subscribeToUpdates() {
        cancellable = CureTranslationBridge.shared.$refreshToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateValue()
            }
    }
    
    /// Updates the image `value` (URL) by fetching the latest URL string from the SDK.
    private func updateValue() {
        // Differentiate update logic based on whether it's a global asset or a legacy one
        if let tabName = self.tab, tabName == "__images__" {
            // Update logic for global image assets
            let newUrl = Cure.shared.imageURL(forKey: key ?? "default_image_url_not_set")
            if newUrl != self.value { self.value = newUrl }
        } else if let tabName = self.tab {
            // Backward compatible update for screen-dependent URLs
            let newUrl = Cure.shared.imageUrl(for: key ?? "default_image_url_not_set", inTab: tabName)
            if newUrl != self.value { self.value = newUrl }
        }
    }
    
}

public final class CureDataStore: ObservableObject {
    private let apiIdentifier: String
    private var cancellable: AnyCancellable?
    
    /// The array of items from the Data Store. This property is `@Published`, so SwiftUI
    /// views will automatically update when the array changes.
    @Published public private(set) var items: [DataStoreItem] = []
    
    /// Initializes a `CureDataStore` object.
    /// - Parameter apiIdentifier: The unique API identifier of the store to fetch and observe.
    public init(apiIdentifier: String) {
        self.apiIdentifier = apiIdentifier
        
        // Set initial value from the SDK's cache
        self.items = Cure.shared.getStoreItems(for: apiIdentifier)
        
        // Automatically trigger a sync when the object is created.
        Cure.shared.syncStore(apiIdentifier: apiIdentifier) { _ in
            // The sink subscription below will handle the update.
            // This closure can be used for logging if needed.
        }
        
        // Subscribe to the .cmscureDataStoreDidUpdate notification
        cancellable = CureTranslationBridge.shared.$refreshToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // When any content in the SDK updates, this object will re-check
                // its own data from the central cache.
                self?.updateItems()
            }
    }
    
    /// Fetches the latest items from the SDK's cache and updates the `items` property if changed.
    private func updateItems() {
        let newItems = Cure.shared.getStoreItems(for: self.apiIdentifier)
        
        // To prevent unnecessary UI updates, only update if the items have actually changed.
        // This requires DataStoreItem to conform to Equatable.
        if newItems != self.items {
            self.items = newItems
        }
    }
    
    /// Convenience accessor that converts the underlying `DataStoreItem` models into
    /// ergonomic `CureDataStoreRecord` wrappers. Useful when rendering lists directly.
    public var records: [CureDataStoreRecord] {
        return items.map { CureDataStoreRecord(item: $0) }
    }
}

/// Lightweight wrapper that exposes data store items with friendly accessors.
///
/// Each record keeps a reference to the original `DataStoreItem` while providing helpers to
/// grab typed values (including automatic localization) and iterate through raw dictionaries
/// without dealing with the lower-level `JSONValue` enum.
public struct CureDataStoreRecord: Identifiable {
    public let id: String
    public let createdAtISO: String
    public let updatedAtISO: String
    
    /// Access to the underlying codable representation in case the host app needs it.
    public let raw: DataStoreItem
    
    private let fields: [String: JSONValue]
    
    internal init(item: DataStoreItem) {
        self.id = item.id
        self.createdAtISO = item.createdAt
        self.updatedAtISO = item.updatedAt
        self.fields = item.data
        self.raw = item
    }
    
    /// Returns the ISO-8601 `createdAt` timestamp as a `Date` if parsing succeeds.
    public var createdAt: Date? {
        ISO8601DateFormatter().date(from: createdAtISO)
    }
    
    /// Returns the ISO-8601 `updatedAt` timestamp as a `Date` if parsing succeeds.
    public var updatedAt: Date? {
        ISO8601DateFormatter().date(from: updatedAtISO)
    }
    
    /// Provides a simple dictionary (with localized strings flattened) for quick iteration.
    public var dictionary: [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in fields {
            if let resolved = value.resolvedValue() {
                result[key] = resolved
            }
        }
        return result
    }
    
    /// Optionally supply a preferred language code when resolving localized fields.
    public func dictionary(preferredLanguage language: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in fields {
            if let resolved = value.resolvedValue(preferredLanguage: language) {
                result[key] = resolved
            }
        }
        return result
    }
    
    /// Random-access convenience for template-style usage.
    public subscript(key: String) -> Any? {
        return fields[key]?.resolvedValue()
    }
    
    /// Returns the field's `JSONValue` for advanced scenarios.
    public func jsonValue(_ key: String) -> JSONValue? {
        return fields[key]
    }
    
    /// Resolves the field as a localized string using the active CMSCure language.
    public func string(_ key: String) -> String? {
        return fields[key]?.localizedString
    }
    
    /// Resolves the field as a localized string using a custom language code.
    public func string(_ key: String, language: String) -> String? {
        return fields[key]?.resolvedValue(preferredLanguage: language) as? String
    }
    
    /// Resolves the field as an integer.
    public func int(_ key: String) -> Int? {
        return fields[key]?.intValue
    }
    
    /// Resolves the field as a boolean.
    public func bool(_ key: String) -> Bool? {
        return fields[key]?.boolValue
    }
    
    /// Resolves the field as a double (covers both integer and floating point JSON).
    public func double(_ key: String) -> Double? {
        if let double = fields[key]?.doubleValue {
            return double
        }
        if let int = fields[key]?.intValue {
            return Double(int)
        }
        return nil
    }
}

// MARK: - NEW: Public SDKImage View
// This is the new, recommended way to display images from the CMS.
public extension Cure {
    /// A ready-to-use, cache-enabled SwiftUI View for displaying images from CMSCure.
    ///
    /// This view internally uses Kingfisher to handle downloading, memory/disk caching,
    /// and displaying the image, providing robust offline support automatically.
    ///
    /// ## Usage
    /// ```swift
    /// if let url = Cure.shared.imageURL(forKey: "logo_primary") {
    ///     Cure.SDKImage(url: url)
    ///         .aspectRatio(contentMode: .fit)
    ///         .frame(height: 50)
    /// }
    /// ```
    struct SDKImage: View {
        private let url: URL?
        
        /// Initializes the view with a URL.
        /// - Parameter url: The URL of the image to display, typically retrieved from
        ///   `Cure.shared.imageURL(forKey:)` or `Cure.shared.imageUrl(for:inTab:)`.
        public init(url: URL?) {
            self.url = url
        }
        
        public var body: some View {
            // Internally, this view uses KFImage to leverage its powerful features.
            // The app developer does not need to know about or import Kingfisher.
            KFImage(url)
                .resizable() // Default to resizable
                .placeholder {
                    // Provide a default, sensible placeholder.
                    ZStack {
                        Color.gray.opacity(0.1)
                        ProgressView()
                    }
                }
                .fade(duration: 0.25) // Add a subtle fade-in transition.
        }
    }

    /// SwiftUI helper that automatically tracks a CMS-managed image key and renders it with caching.
    ///
    /// This view listens for real-time updates, so if the URL behind the provided key changes in the CMS,
    /// the rendered image updates automatically. Internally it uses `CureImage` for observation and
    /// Kingfisher for efficient memory/disk caching.
    struct ManagedImage: View {
        @StateObject private var imageModel: CureImage
        private let contentMode: SwiftUICore.ContentMode
        private let defaultImageName: String?

        /// Creates a managed image for an on-screen asset (tab-specific).
        /// - Parameters:
        ///   - key: The image key as configured in the CMS.
        ///   - tab: Optional tab/screen identifier if the image is scoped to a screen. Pass `nil`
        ///          to use the global image library.
        ///   - contentMode: How the rendered image should scale within its bounds. Defaults to `.fit`.
        ///   - defaultImageName: Optional local asset name used when the CMS image is unavailable.
        public init(
            key: String,
            tab: String = "__images__",
            contentMode: SwiftUICore.ContentMode = .fit,
            defaultImageName: String? = nil
        ) {
            _imageModel = StateObject(wrappedValue: CureImage(key, tab: tab))
            self.contentMode = contentMode
            self.defaultImageName = defaultImageName
        }

        public var body: some View {
            Group {
                if let url = imageModel.value {
                    configuredImage(for: url)
                } else {
                    fallbackContent()
                }
            }
        }

        @ViewBuilder
        private func configuredImage(for url: URL) -> some View {
            let base = KFImage(url)
                .resizable()
                .cancelOnDisappear(true)
                .cacheOriginalImage()
                .loadDiskFileSynchronously()
                .placeholder { placeholderContent(showProgress: true) }
                .fade(duration: 0.25)

            switch contentMode {
            case .fit:
                base.scaledToFit()
            case .fill:
                base.scaledToFill()
            @unknown default:
                base
            }
        }

        @ViewBuilder
        private func placeholderContent(showProgress: Bool = false) -> some View {
            if let name = defaultImageName, !name.isEmpty {
                fallbackImageView(named: name)
            } else {
                ZStack {
                    Color.gray.opacity(0.08)
                    if showProgress {
                        ProgressView()
                    }
                }
            }
        }

        @ViewBuilder
        private func fallbackContent() -> some View {
            if let name = defaultImageName, !name.isEmpty {
                fallbackImageView(named: name)
            } else {
                ZStack {
                    Color.gray.opacity(0.08)
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundColor(.gray)
                }
            }
        }

        @ViewBuilder
        private func fallbackImageView(named name: String) -> some View {
            let image = Image(name).resizable()
            switch contentMode {
            case .fit:
                image.scaledToFit()
            case .fill:
                image.scaledToFill()
            @unknown default:
                image
            }
        }
    }
}

// MARK: - SocketIOStatus Convenience Extension

extension SocketIOStatus {
    /// Provides a user-friendly string description for each `SocketIOStatus` case.
    internal var description: String { // Made internal as it's primarily for SDK's own logging.
        switch self {
            case .notConnected: return "Not Connected"
            case .disconnected: return "Disconnected"
            case .connecting:   return "Connecting"
            case .connected:    return "Connected"
        }
    }
}

public enum JSONValue: Codable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    // --- NEW CASE to handle localized strings ---
    case localizedObject([String: String])
    case null
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            // --- NEW: Handle decoding of the language dictionary ---
        } else if let value = try? container.decode([String: String].self) {
            self = .localizedObject(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
            case .string(let v): try container.encode(v)
            case .int(let v): try container.encode(v)
            case .double(let v): try container.encode(v)
            case .bool(let v): try container.encode(v)
                // --- NEW: Handle encoding of the language dictionary ---
            case .localizedObject(let v): try container.encode(v)
            case .null: try container.encodeNil()
        }
    }
}

public struct DataStoreItem: Codable, Equatable, Hashable, Identifiable {
    public let id: String
    public let data: [String: JSONValue]
    public let createdAt: String
    public let updatedAt: String
    private enum CodingKeys: String, CodingKey { case id = "_id", data, createdAt, updatedAt }
}

private struct DataStoreResponse: Codable { let items: [DataStoreItem] }


/// Helper extension to easily and safely extract typed values from the JSONValue enum.
public extension JSONValue {
    /// Returns the string value if the case is `.string`, otherwise nil.
    var stringValue: String? {
        if case .string(let val) = self { return val }
        return nil
    }
    
    /// Returns the boolean value if the case is `.bool`, otherwise nil.
    var boolValue: Bool? {
        if case .bool(let val) = self { return val }
        return nil
    }
    
    /// Returns the integer value if the case is `.int`, otherwise nil.
    var intValue: Int? {
        if case .int(let val) = self { return val }
        return nil
    }
    
    /// Returns the double value if the case is `.double`, otherwise nil.
    var doubleValue: Double? {
        if case .double(let val) = self { return val }
        return nil
    }
    
    /// Returns the string for the SDK's currently active language if the value is a
    /// localized object. Falls back to the default language or the first available
    /// language if the active one isn't present.
    var localizedString: String? {
        guard case .localizedObject(let dict) = self else {
            // If the field is not a localized object, it might be a regular string.
            // This provides backward compatibility.
            return self.stringValue
        }
        let currentLang = Cure.shared.getLanguage()
        // Prioritize current language, then English as a fallback, then any available language.
        return dict[currentLang] ?? dict["en"] ?? dict.values.first
    }
    
    /// Resolves the value to a plain Swift type. Localized dictionaries automatically pick the
    /// provided language (defaulting to the currently selected SDK language).
    /// - Parameter language: Optional language code override.
    /// - Returns: A Swift type (`String`, `Int`, `Double`, `Bool`) or `nil` for nulls/missing data.
    func resolvedValue(preferredLanguage language: String? = nil) -> Any? {
        switch self {
            case .string(let value):
                return value
            case .int(let value):
                return value
            case .double(let value):
                return value
            case .bool(let value):
                return value
            case .localizedObject(let dict):
                let preferredLanguage = language ?? Cure.shared.getLanguage()
                return dict[preferredLanguage] ?? dict["en"] ?? dict.values.first
            case .null:
                return nil
        }
    }
}
