# CMSCureSDK for iOS

[![Swift Package Manager compatible](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Platform](https://img.shields.io/badge/platform-iOS%2013%2B-blue.svg)](https://developer.apple.com/ios/)
[![Release](https://img.shields.io/github/v/release/cmscure/ios-sdk.svg?label=version&logo=github)](https://github.com/cmscure/ios-sdk/releases/tag/1.0.2)
[![License](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE.md)

**CMSCureSDK** provides a seamless way to integrate your iOS application with the CMSCure platform. Manage and deliver dynamic content, translations, colors, and image URLs to your app with real-time updates and offline caching capabilities.

## Features

* **Easy Configuration:** Simple setup with your project credentials.
* **Content Management:** Fetch and display translations, global color schemes, and image URLs managed in CMSCure.
* **Real-time Updates:** Utilizes Socket.IO to receive live content updates, ensuring your app's content is always current.
* **Offline Caching:** Persists fetched content to disk, ensuring availability even when the device is offline.
* **Language Management:** Easily switch between multiple languages supported by your CMS content, with automatic content refreshing.
* **SwiftUI Integration:** Provides convenient property wrappers (`CureString`, `CureColor`, `CureImage`) and a string extension for effortless use and automatic UI updates in SwiftUI views.
* **Thread Safety:** Built with thread safety in mind for robust and predictable performance.

## Requirements

* iOS 13.0+
* Xcode 13.0+ (or as required by the Swift version and dependencies)
* Swift 5.5+ (or as required by dependencies)
* An active CMSCure project and associated credentials (Project ID, API Key, Project Secret).

## Installation

CMSCureSDK is available through the Swift Package Manager. To install it into your Xcode project:

1.  In Xcode, open your project and navigate to **File > Add Packages...**
2.  In the "Search or Enter Package URL" search bar, enter the SDK's GitHub repository URL:
    ```
    [https://github.com/cmscure/ios-sdk.git](https://github.com/cmscure/ios-sdk.git)
    ```
3.  For "Dependency Rule," choose "Up to Next Major Version" (or your preferred rule) and input `1.0.2` (or the latest desired version).
4.  Click "Add Package."
5.  Select the `CMSCureSDK` library product and add it to your desired target(s).

## Configuration

Before using any SDK features, you **must** configure the shared instance. This is typically done once when your app launches.

**For SwiftUI apps (in your `@main App` struct):**
```swift
import SwiftUI
import CMSCureSDK // Don't forget to import the SDK

@main
struct YourAppNameApp: App {
    init() {
        // Configure CMSCureSDK shared instance
        Cure.shared.configure(
            projectId: "YOUR_PROJECT_ID",    // Replace with your actual Project ID
            apiKey: "YOUR_API_KEY",          // Replace with your actual API Key
            projectSecret: "YOUR_PROJECT_SECRET" // Replace with your actual Project Secret
        )

        // Note: The SDK uses default production URLs for its server and socket connections.
        // These are not currently configurable via this 'configure' method.

        // Optional: Enable debug logs during development (defaults to true in the SDK)
        Cure.shared.debugLogsEnabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView() // Your main view
        }
    }
}
```

**For UIKit apps (in `AppDelegate.swift`):**
```swift
import UIKit
import CMSCureSDK // Don't forget to import the SDK

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        Cure.shared.configure(
            projectId: "YOUR_PROJECT_ID",
            apiKey: "YOUR_API_KEY",
            projectSecret: "YOUR_PROJECT_SECRET"
        )
        Cure.shared.debugLogsEnabled = true
        
        return true
    }
    // ... other AppDelegate methods
}
```

**Parameters for `configure()`:**

* `projectId` (String): Your unique Project ID from the CMSCure dashboard.
* `apiKey` (String): Your secret API Key from CMSCure, used for authenticating API requests.
* `projectSecret` (String): Your Project Secret from CMSCure, used for internal SDK operations.

## Core Usage

### Accessing the SDK Singleton

A convenience typealias `Cure` is provided for easy access to the shared SDK instance:

```swift
import CMSCureSDK

// Access via Cure.shared
Cure.shared.setLanguage("en")
```

### Language Management

**Set Current Language:**
Updates the active language, persists the preference, and triggers content syncs and UI updates for reactive components.

```swift
Cure.shared.setLanguage("fr") {
    print("Language switch to French initiated. SDK will sync and UI should update.")
}
```

**Get Current Language:**
Returns the currently active language code (e.g., "en", "fr").
```swift
let currentLang = Cure.shared.getLanguage()
```

**Fetch Available Languages:**
Asynchronously retrieves a list of language codes supported by your project.
```swift
Cure.shared.availableLanguages { languageCodes in
    // languageCodes will be an array like ["en", "fr", "es"]
    print("Available languages from CMS: \(languageCodes)")
    // Update your UI (e.g., a language picker)
}
```

### Fetching Translations

Retrieve a translated string for a given key within a specific "tab" (a logical grouping of content, often per screen). If a translation isn't found, an empty string is returned.

```swift
let pageTitle = Cure.shared.translation(for: "welcome_title", inTab: "home_screen")
let buttonText = Cure.shared.translation(for: "submit_button", inTab: "user_form")
```

### Fetching Colors

Retrieve a global color hex string (e.g., `"#FF5733"`). Colors are managed in a special tab named `__colors__` in your CMS. Returns `nil` if the color key is not found.

```swift
let primaryColorHex: String? = Cure.shared.colorValue(for: "primary_brand_color")

// The SDK provides a convenience initializer for SwiftUI:
// let swiftUIColor = Color(hex: primaryColorHex) ?? .gray
// For UIKit, you'll need to parse the hex string into a UIColor.
```

### Fetching Image URLs

Retrieve an image `URL` for a given key and tab. Returns `nil` if the key isn't found or its value isn't a valid URL.

```swift
let logoURL: URL? = Cure.shared.imageUrl(for: "app_logo", inTab: "common_assets")

if let url = logoURL {
    // Use this URL to load the image with SwiftUI's AsyncImage or other libraries.
}
```

### Real-time Updates (Socket.IO)

The SDK automatically manages its Socket.IO connection for real-time content updates after successful configuration.

**Check Connection Status:**
```swift
if Cure.shared.isConnected() {
    print("Socket is connected to CMSCure.")
} else {
    print("Socket is not currently connected.")
}
```
When the server pushes an update, the SDK automatically fetches new data and updates its cache. Reactive UI components (`CureString`, `CureColor`, `CureImage`) will update automatically. For manual UI management (e.g., UIKit), you can listen to notifications.

### Responding to Content Updates (for UIKit / Manual Handling)

For manual UI updates (e.g., in UIKit), you can:

**1. Use Specific Tab Handlers (Legacy):**
Register a closure for updates to a specific tab.
```swift
// In your ViewController or relevant class
func setupContentUpdates() {
    Cure.shared.onTranslationsUpdated(for: "profile_screen") { [weak self] updatedTranslations in
        // updatedTranslations is [String: String] for the current language in "profile_screen"
        DispatchQueue.main.async { // Ensure UI updates are on the main thread
            self?.nameLabel.text = updatedTranslations["profile_name_label"] ?? "Name"
            // ... update other UI elements ...
        }
    }
}
```

**2. Observe General Notification (Recommended for UIKit):**
Listen for `Notification.Name.translationsUpdated`. The notification's `userInfo` dictionary may contain a `"screenName"` key.
```swift
// In your ViewController
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleCMSContentUpdate(_:)),
    name: .translationsUpdated, // SDK's public notification name
    object: nil
)

@objc func handleCMSContentUpdate(_ notification: Notification) {
    let relevantTab = "profile_screen" // The tab this VC cares about
    var needsRefresh = false

    if let userInfo = notification.userInfo, let updatedScreenName = userInfo["screenName"] as? String {
        if updatedScreenName == relevantTab || updatedScreenName.uppercased() == "__ALL__" {
            needsRefresh = true
        }
    } else {
        // If no screenName, assume it's a general update that might affect this screen
        needsRefresh = true
    }

    if needsRefresh {
        print("CMS content updated, refreshing UI for \(relevantTab).")
        DispatchQueue.main.async {
            // self.loadAndDisplayContentForProfileScreen() // Your method to reload data
        }
    }
}

// Don't forget to remove the observer in deinit
deinit {
    NotificationCenter.default.removeObserver(self, name: .translationsUpdated, object: nil)
}
```

## SwiftUI Integration

CMSCureSDK is designed for modern SwiftUI development with reactive property wrappers and extensions.

### `@StateObject var myText = CureString(key, tab:)`
Observes a single string value. Your `Text` views will automatically update.
```swift
import SwiftUI
import CMSCureSDK

struct MyDynamicLabelView: View {
    @StateObject var pageTitle = CureString("screen_title", tab: "settings_page")

    var body: some View {
        Text(pageTitle.value.isEmpty ? "Settings" : pageTitle.value) // Use .value
            .font(.headline)
    }
}
```

### `@StateObject var myColor = CureColor(key)`
Observes a global color (from the `__colors__` tab). The `value` property is a `SwiftUI.Color?`.
```swift
import SwiftUI
import CMSCureSDK

struct MyColoredView: View {
    @StateObject var appThemeBackground = CureColor("app_background_main")
    @StateObject var primaryUITextColor = CureColor("text_color_primary")

    var body: some View {
        Text("Hello, Themed World!".cure(tab: "general_text")) // String extension example
            .padding()
            .background(appThemeBackground.value ?? .clear) // Provide a fallback color
            .foregroundColor(primaryUITextColor.value ?? .primary)
    }
}
```

### `@StateObject var myImage = CureImage(key, tab:)`
Observes an image URL. The `value` property is a `URL?`, ideal for `AsyncImage`.
```swift
import SwiftUI
import CMSCureSDK

struct MyDynamicImageView: View {
    @StateObject var heroBanner = CureImage("hero_banner_main", tab: "home_assets")

    var body: some View {
        Group {
            if let imageUrl = heroBanner.value {
                AsyncImage(url: imageUrl) { imagePhase in
                    if let image = imagePhase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else if imagePhase.error != nil {
                        Image(systemName: "person.crop.circle.badge.exclamationmark") // Error placeholder
                            .foregroundColor(.gray)
                    } else {
                        ProgressView() // Loading placeholder
                    }
                }
            } else {
                Image(systemName: "photo.on.rectangle.angled").opacity(0.3) // No URL placeholder
            }
        }
        .frame(height: 200)
    }
}
```

### `String.cure(tab:)` Extension
For direct, reactive translation access within SwiftUI `Text` views. This automatically updates when translations change.
```swift
import SwiftUI
import CMSCureSDK

struct MySimpleTextView: View {
    var body: some View {
        VStack {
            Text("main_greeting".cure(tab: "home_screen_text"))
                .font(.title)
            Text("action_button_proceed".cure(tab: "common_buttons"))
                .padding()
        }
    }
}
```

## Cache Management

**Clear All Cached Data:**
Resets the SDK, removing all locally stored data (translations, colors, known tabs, internal SDK config) and its runtime configuration. `Cure.shared.configure(...)` will need to be called again to make the SDK operational.
```swift
Cure.shared.clearCache()
```

**Check if a Tab Has Been Synced:**
Determines if a tab has any data in the local cache, which implies it has likely been synced at least once.
```swift
if Cure.shared.isTabSynced("user_profile_data") {
    print("User profile data tab has cached content.")
}
```

## Error Handling

The SDK defines a `public enum CMSCureSDKError: Error, LocalizedError`. While many operations handle errors internally and log them (if `debugLogsEnabled` is true), you can refer to this enum in the SDK source code for specific error cases if you need to implement custom error handling logic.

## Debugging

Enable detailed console logs from the SDK for diagnosing issues:
```swift
Cure.shared.debugLogsEnabled = true
```
This property defaults to `true` within the SDK. It is highly recommended to set this to `false` for your production/release builds to avoid excessive console output.

## Contributing

(Details about how to contribute to the SDK - e.g., pull requests, issue reporting guidelines, coding standards.)

## License

CMSCureSDK is released under the **MIT** License. See `LICENSE.md` for details.

---

We hope CMSCureSDK helps you build amazing, dynamic iOS applications! If you have any questions or feedback, please [open an issue on GitHub](https://github.com/cmscure/ios-sdk/issues).
