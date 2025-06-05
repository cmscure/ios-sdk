# CMSCureSDK for iOS

[![Swift Package Manager compatible](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Platform](https://img.shields.io/badge/platform-iOS%2013%2B-blue.svg)](https://developer.apple.com/ios/)
[![Release](https://img.shields.io/github/v/release/cmscure/ios-sdk.svg)](https://github.com/cmscure/ios-sdk/releases/tag/1.0.1)
[![License](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE.md) **CMSCureSDK** provides a seamless way to integrate your iOS application with the CMSCure platform. Manage and deliver dynamic content, translations, colors, and image URLs to your app with real-time updates and offline caching capabilities.

## Features

* **Easy Configuration:** Simple setup with your project credentials.
* **Content Management:** Fetch and display translations, global color schemes, and image URLs managed in CMSCure.
* **Real-time Updates:** Utilizes Socket.IO to receive live content updates without needing an app restart.
* **Offline Caching:** Persists fetched content to disk, ensuring availability even when offline.
* **Language Management:** Easily switch between multiple languages supported by your CMS content.
* **SwiftUI Integration:** Provides convenient property wrappers (`CureString`, `CureColor`, `CureImage`) and helpers for effortless use in SwiftUI views.
* **Thread Safety:** Built with thread safety in mind for robust performance.
* **Legacy Support:** Includes mechanisms for legacy encryption and authentication flows if required by your backend.

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
3.  For "Dependency Rule," choose "Up to Next Major Version" and input `0.1.0` (or your desired version).
4.  Click "Add Package."
5.  Select the `CMSCureSDK` library product and add it to your desired target(s).

## Configuration

Before using any SDK features, you **must** configure the shared instance, typically in your `AppDelegate.swift` or `SceneDelegate.swift` during app launch.

```swift
import CMSCureSDK // Don't forget to import the SDK

// In your AppDelegate.swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    // ... other setup ...

    Cure.shared.configure(
        projectId: "YOUR_PROJECT_ID",
        apiKey: "YOUR_API_KEY",
        projectSecret: "YOUR_PROJECT_SECRET",
        // Optional: Specify custom server URLs if not using the defaults
        // serverUrlString: "[https://your.custom.server.com](https://your.custom.server.com)",
        // socketIOURLString: "wss://your.custom.socketserver.com"
    )

    // Optional: Enable debug logs during development (defaults to true)
    Cure.shared.debugLogsEnabled = true

    return true
}
```

**Parameters for `configure()`:**

* `projectId` (String): Your unique Project ID from the CMSCure dashboard.
* `apiKey` (String): Your secret API Key from CMSCure, used for authenticating API requests.
* `projectSecret` (String): Your Project Secret from CMSCure, used for legacy encryption and Socket.IO handshake.
* `serverUrlString` (String, Optional): The base URL for your CMSCure backend API. Defaults to `https://app.cmscure.com`.
* `socketIOURLString` (String, Optional): The URL for your CMSCure Socket.IO server. Defaults to `wss://app.cmscure.com`.

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
This updates the active language, persists the preference, and triggers content syncs and UI updates.

```swift
Cure.shared.setLanguage("fr") {
    print("Language successfully switched to French and content updated.")
}
```

**Get Current Language:**

```swift
let currentLang = Cure.shared.getLanguage() // e.g., "fr"
```

**Fetch Available Languages:**
Useful for building a language selection UI.

```swift
Cure.shared.availableLanguages { languageCodes in
    // languageCodes will be an array like ["en", "fr", "es"]
    print("Available languages: \(languageCodes)")
    // Update your UI with these language codes
}
```

### Fetching Translations

Retrieve a translated string for a given key within a specific "tab" (often representing a screen or a content group).

```swift
// For UIKit or general Swift code:
let pageTitle = Cure.shared.translation(for: "welcome_title", inTab: "home_screen")
let buttonText = Cure.shared.translation(for: "submit_button", inTab: "user_form")

// If a translation is not found, an empty string is returned.
```

### Fetching Colors

Retrieve a global color hex string. Colors are typically managed in a special tab (e.g., `__colors__`).

```swift
let primaryColorHex: String? = Cure.shared.colorValue(for: "primary_brand_color") // e.g., "#FF5733"

// An extension `Color(hex: String?)` is provided for easy conversion to SwiftUI.Color.
```

### Fetching Image URLs

Retrieve an image URL for a given key and tab.

```swift
let logoURL: URL? = Cure.shared.imageUrl(for: "app_logo", inTab: "common_assets")

if let url = logoURL {
    // Use this URL to load the image (e.g., with SwiftUI's AsyncImage or other libraries).
}
```

### Real-time Updates (Socket.IO)

The SDK automatically manages its Socket.IO connection after successful configuration.

**Check Connection Status:**

```swift
if Cure.shared.isConnected() {
    print("Socket is connected.")
} else {
    print("Socket is not connected.")
}
```

**Manual Connection Control (Usually not needed):**

```swift
// To explicitly attempt a connection:
// Cure.shared.startListening() // Called automatically after configure and on app active if needed.

// To explicitly disconnect:
// Cure.shared.stopListening()
```
When the server pushes an update, the SDK automatically fetches new data, updates its cache, and notifies UI components.

### Responding to Translation Updates (Callbacks)

For manual UI updates (e.g., in UIKit), register a handler:

```swift
// In your ViewController or relevant class
func setupContentUpdates() {
    Cure.shared.onTranslationsUpdated(for: "profile_screen") { [weak self] updatedTranslations in
        // updatedTranslations is [String: String] for the current language
        self?.nameLabel.text = updatedTranslations["profile_name_label"] ?? "Name"
        // ... update other UI elements ...
        print("Profile screen content updated!")
    }
}
```
The handler is called immediately with cached data upon registration and then for subsequent updates.

## SwiftUI Integration

CMSCureSDK offers property wrappers and extensions for seamless integration with SwiftUI.

### `String.cure(tab:)`

Access translations directly in your SwiftUI views.

```swift
import SwiftUI
import CMSCureSDK

struct MyTextView: View {
    var body: some View {
        VStack {
            Text("greeting_key".cure(tab: "home_screen"))
                .font(.title)
            Text("welcome_message".cure(tab: "home_screen"))
                .padding()
        }
    }
}
```

### `@StateObject var myText = CureString(key, tab:)`

For observing a single string value.

```swift
import SwiftUI
import CMSCureSDK

struct MyDynamicLabelView: View {
    @StateObject var dynamicTitle = CureString("page_title", tab: "settings_screen")

    var body: some View {
        Text(dynamicTitle.value)
            .font(.headline)
    }
}
```

### `@StateObject var myColor = CureColor(key)`

Access global colors that update your UI automatically.

```swift
import SwiftUI
import CMSCureSDK

struct MyColoredView: View {
    @StateObject var backgroundColor = CureColor("app_background")
    @StateObject var textColor = CureColor("primary_text_color")

    var body: some View {
        Text("Hello, Themed World!".cure(tab: "general"))
            .padding()
            .background(backgroundColor.value ?? .gray) // Use a fallback
            .foregroundColor(textColor.value ?? .black)
    }
}
```

### `@StateObject var myImage = CureImage(key, tab:)`

Access image URLs dynamically.

```swift
import SwiftUI
import CMSCureSDK

struct MyImageView: View {
    @StateObject var headerImage = CureImage("header_banner_url", tab: "home_assets")

    var body: some View {
        Group {
            if let imageUrl = headerImage.value {
                AsyncImage(url: imageUrl) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    ProgressView()
                }
            } else {
                Image(systemName: "photo").resizable().aspectRatio(contentMode: .fit).opacity(0.3)
            }
        }
        .frame(height: 200)
    }
}
```

## Cache Management

**Clear All Cached Data:**
This resets the SDK, removing all local data and runtime configuration. `configure()` will be needed again.

```swift
Cure.shared.clearCache()
```

**Check if a Tab is Synced:**

```swift
if Cure.shared.isTabSynced("user_preferences") {
    print("User preferences tab has been synced previously.")
}
```

## Error Handling

The SDK defines a `CMSCureSDKError` enum (conforming to `LocalizedError`) for errors. Many operations handle errors internally, but you can catch them for custom logic.

```swift
// See CMSCureSDKError enum in the source code for all cases and descriptions.
// Example:
// public enum CMSCureSDKError: Error, LocalizedError {
//     case notConfigured
//     case missingInitialCredentials(String)
//     // ... and many more
// }
```

## Debugging

Enable detailed console logs from the SDK by setting `Cure.shared.debugLogsEnabled = true` (this is the default). This is useful for diagnosing connection issues, sync problems, or cache behavior. Set to `false` for production releases.

## Contributing

## License

CMSCureSDK is released under the [YOUR_LICENSE_TYPE] License. See `LICENSE.md` for details.

---

We hope CMSCureSDK helps you build amazing, dynamic iOS applications! If you have any questions or feedback, please [open an issue](https://github.com/cmscure/ios-sdk/issues).
