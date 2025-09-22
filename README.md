# CMSCureSDK for iOS

[![Swift Package Manager compatible](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Platform](https://img.shields.io/badge/platform-iOS%2013%2B-blue.svg)](https://developer.apple.com/ios/)
[![Release](https://img.shields.io/github/v/release/cmscure/ios-sdk.svg?label=version&logo=github)](https://github.com/cmscure/ios-sdk/releases/tag/1.0.5)
[![License](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE.md)

**CMSCureSDK** provides a seamless way to integrate your iOS application with the CMSCure platform. Manage and deliver dynamic content, translations, colors, and image assets to your app with real-time updates and powerful offline caching capabilities.

## Features

* **Easy Configuration:** Simple setup with your project credentials.
* **Content Management:** Fetch and display translations, global color schemes, and image URLs managed in CMSCure.
* **Global Image Assets:** Manage a central library of images, independent of specific app screens.
* **Automatic Image Caching:** Seamlessly caches all remote images (both global assets and those in translation fields) for robust offline support and performance, powered by Kingfisher.
* **Real-time Updates:** Utilizes Socket.IO to receive live content updates, ensuring your app's content is always current.
* **Offline Caching:** Persists all fetched text and color content to disk, ensuring availability when the device is offline.
* **Language Management:** Easily switch between multiple languages supported by your CMS content, with automatic content refreshing.
* **SwiftUI Integration:** Provides convenient property wrappers (`CureString`, `CureColor`, `CureImage`) and a string extension for effortless use and automatic UI updates in SwiftUI views.
* **Thread Safety:** Built with thread safety in mind for robust and predictable performance.

## Requirements

* iOS 14.0+
* Xcode 16.0+
* Swift 5.5+
* An active CMSCure project and associated credentials.

## Installation

CMSCureSDK is available through the Swift Package Manager.

1.  In Xcode, open your project and navigate to **File > Add Packages...**
2.  In the package URL search bar, enter:
    ```
    [https://github.com/cmscure/ios-sdk.git](https://github.com/cmscure/ios-sdk.git)
    ```
3.  For "Dependency Rule," choose "Up to Next Major Version" and input `1.0.3`.
4.  Click "Add Package." The SDK and its required dependency (Kingfisher) will be added to your project.
5.  Select the `CMSCureSDK` library product and add it to your desired target(s).

## Configuration

Before using any SDK features, you **must** configure the shared instance. This is typically done once when your app launches.

**For SwiftUI apps (in your `@main App` struct):**
```swift
import SwiftUI
import CMSCureSDK

@main
struct YourAppNameApp: App {
    init() {
        Cure.shared.configure(
            projectId: "YOUR_PROJECT_ID",
            apiKey: "YOUR_API_KEY",
            projectSecret: "YOUR_PROJECT_SECRET"
        )
        // Optional: Enable debug logs during development
        #if DEBUG
        Cure.shared.debugLogsEnabled = true
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

## Core Usage

### Language Management

**Set Current Language:**
```swift
Cure.shared.setLanguage("fr")
```

**Fetch Available Languages:**
```swift
Cure.shared.availableLanguages { languageCodes in
    // languageCodes will be an array like ["en", "fr", "es"]
    print("Available languages: \(languageCodes)")
}
```

### Fetching Translations

Retrieve a translated string for a given key within a specific "tab".
```swift
let pageTitle = Cure.shared.translation(for: "welcome_title", inTab: "home_screen")
```

### Fetching Colors

Retrieve a global color hex string (e.g., `"#FF5733"`).
```swift
let primaryColorHex: String? = Cure.shared.colorValue(for: "primary_brand_color")
```

### Fetching Image URLs

The SDK now supports two ways to manage images, both with automatic caching.

**1. Global Image Assets (Recommended)**
Fetch a URL from your central image library using its key. This is the preferred method for reusable images like logos, icons, and banners.

```swift
let logoURL: URL? = Cure.shared.imageURL(forKey: "logo_primary")
```

**2. Screen-Dependent Image URLs (Legacy)**
Fetch an image URL that is stored as a value within a specific translations tab.

```swift
let bannerURL: URL? = Cure.shared.imageUrl(for: "hero_banner_image", inTab: "home_screen_assets")
```

### Displaying Images for Offline Support

To ensure images are cached and available offline, you **must use `KFImage` from the Kingfisher library** to display them. The SDK automatically pre-fetches and caches images in the background, and `KFImage` knows how to read from that cache.

```swift
import Kingfisher // Make sure to import Kingfisher in your view files

// In your SwiftUI view...
if let url = Cure.shared.imageURL(forKey: "logo_primary") {
    KFImage(url)
        .resizable()
        .placeholder { ProgressView() } // Optional placeholder
        .aspectRatio(contentMode: .fit)
}
```

### SwiftUI Integration

Use our reactive property wrappers for automatic UI updates.

**`CureString(key, tab:)`**
```swift
@StateObject var pageTitle = CureString("screen_title", tab: "settings_page")

Text(pageTitle.value.isEmpty ? "Settings" : pageTitle.value)
```

**`CureColor(key)`**
```swift
@StateObject var appThemeBackground = CureColor("app_background_main")

Text("Hello").background(appThemeBackground.value ?? .clear)
```

**`CureImage`**
The `CureImage` property wrapper now supports both global and screen-dependent images.

* **For Global Image Assets (Recommended):**
    ```swift
    @StateObject var logo = CureImage(assetKey: "logo_primary")
    
    var body: some View {
        KFImage(logo.value) // Use KFImage for display
    }
    ```

* **For Screen-Dependent Image URLs (Legacy):**
    ```swift
    @StateObject var heroBanner = CureImage("hero_banner_main", tab: "home_assets")
    
    var body: some View {
        KFImage(heroBanner.value)
    }
    ```
**`CureDataStore`**
Use `CureDataStore` wrapper to fetch and observe an entire collection of structured data

```swift
@StateObject private var productStore = CureDataStore(apiIdentifier: "products")

//... in your view body
List(productStore.items) { product in
    // Access localized and non-localized fields
    Text(product.data["name"]?.localizedString ?? "N/A")
    Text("Price: \\(product.data["price"]?.doubleValue ?? 0.0)")
}
```

### `String.cure(tab:)` Extension
For direct, reactive translation access within SwiftUI `Text` views.
```swift
Text("main_greeting".cure(tab: "home_screen_text"))
```

## License

CMSCureSDK is released under the **MIT** License. See `LICENSE.md` for details.
