# CMSCureSDK for iOS

[![Swift Package Manager compatible](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Platform](https://img.shields.io/badge/platform-iOS%2013%2B-blue.svg)](https://developer.apple.com/ios/)
[![Release](https://img.shields.io/github/v/release/cmscure/ios-sdk.svg?label=version&logo=github)](https://github.com/cmscure/ios-sdk/releases/tag/1.0.6)
[![License](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE.md)

**CMSCureSDK** provides a seamless way to integrate your iOS application with the CMSCure platform. Manage and deliver dynamic content, translations, colors, and image assets to your app with **enhanced automatic real-time updates** and powerful offline caching capabilities.

> **🚀 New:** All core methods now automatically enable real-time updates while maintaining 100% backward compatibility - no code changes required!
> - `translation(for:inTab:)` - Auto real-time translations
> - `colorValue(for:)` - Auto real-time colors  
> - `imageURL(forKey:)` - Auto real-time global images
> - `getStoreItems(for:)` - Auto real-time data stores

## Features

* **Easy Configuration:** Simple setup with your project credentials.
* **Enhanced Core Methods:** All core methods now automatically enable real-time updates while maintaining 100% backward compatibility - no code changes required!
  - `translation(for:inTab:)` - Enhanced translations with auto real-time updates
  - `colorValue(for:)` - Enhanced colors with auto real-time updates  
  - `imageURL(forKey:)` - Enhanced global images with auto real-time updates
  - `getStoreItems(for:)` - Enhanced data stores with auto real-time updates
* **Content Management:** Fetch and display translations, global color schemes, and image URLs managed in CMSCure.
* **Global Image Assets:** Manage a central library of images, independent of specific app screens.
* **Automatic Image Caching:** Seamlessly caches all remote images (both global assets and those in translation fields) for robust offline support and performance, powered by Kingfisher.
* **Smart Real-time Updates:** Utilizes Socket.IO to receive live content updates with intelligent auto-subscription for accessed screens, ensuring your app's content is always current.
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
3.  For "Dependency Rule," choose "Up to Next Major Version" and input `1.0.6`.
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
            // enableAutoRealTimeUpdates: true (default - enables automatic real-time updates)
            // enableAutoRealTimeUpdates: false (for traditional behavior without auto real-time)
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

**🚀 Enhanced with Automatic Real-time Updates!**

Retrieve a translated string for a given key within a specific "tab". The `translation(for:inTab:)` method now **automatically enables real-time updates** while maintaining 100% backward compatibility.

```swift
// Same method call, now with automatic real-time updates!
let pageTitle = Cure.shared.translation(for: "welcome_title", inTab: "home_screen")

// This automatically:
// ✅ Returns immediate cached value
// ✅ Sets up real-time subscription in background  
// ✅ Syncs data if not already synced
// ✅ Receives live updates from CMSCure dashboard
```

**What's Enhanced:**
- **Zero Code Changes:** Existing code automatically gains real-time updates
- **Smart Subscription:** Auto-subscribes to real-time updates for accessed screens
- **Performance Optimized:** Background processing doesn't block your method calls
- **Backward Compatible:** Can be disabled via configuration if needed

**Utility Methods:**
```swift
// Check if auto real-time updates are enabled
let isEnabled = Cure.shared.isAutoRealTimeUpdatesEnabled()

// View which screens are auto-subscribed to translations
let autoScreens = Cure.shared.getAutoSubscribedScreens()

// Check if colors are auto-subscribed
let colorsSubscribed = Cure.shared.isColorsAutoSubscribed()

// Check if global images are auto-subscribed  
let imagesSubscribed = Cure.shared.isGlobalImagesAutoSubscribed()

// View which data stores are auto-subscribed
let autoStores = Cure.shared.getAutoSubscribedDataStores()
```

### Fetching Colors

**🚀 Enhanced with Automatic Real-time Updates!**

Retrieve a global color hex string (e.g., `"#FF5733"`). The `colorValue(for:)` method now **automatically enables real-time updates** while maintaining 100% backward compatibility.

```swift
// Same method call, now with automatic real-time updates!
let primaryColorHex: String? = Cure.shared.colorValue(for: "primary_brand_color")

// This automatically:
// ✅ Returns immediate cached value
// ✅ Sets up real-time subscription for colors in background  
// ✅ Syncs color data if not already synced
// ✅ Receives live color updates from CMSCure dashboard
```

### Fetching Image URLs

The SDK now supports two ways to manage images, both with automatic caching.

**1. Global Image Assets (Recommended) - 🚀 Enhanced with Auto Real-time Updates!**
Fetch a URL from your central image library using its key. The `imageURL(forKey:)` method now **automatically enables real-time updates** while maintaining 100% backward compatibility.

```swift
// Same method call, now with automatic real-time updates!
let logoURL: URL? = Cure.shared.imageURL(forKey: "logo_primary")

// This automatically:
// ✅ Returns immediate cached URL
// ✅ Sets up real-time subscription for global images in background  
// ✅ Syncs image data if not already synced
// ✅ Receives live image URL updates from CMSCure dashboard
```

**2. Screen-Dependent Image URLs (Legacy) - 🚀 Already Enhanced!**
Fetch an image URL that is stored as a value within a specific translations tab. This method uses `translation()` internally, so it **automatically has real-time updates**!

```swift
// This method automatically has real-time updates via enhanced translation() method!
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

## Real-time Updates

### Automatic Real-time Behavior (New!)

The `translation(for:inTab:)` method now provides **automatic real-time updates** with zero configuration needed:

```swift
class ViewController: UIViewController {
    @IBOutlet weak var titleLabel: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // This now automatically receives real-time updates from CMSCure dashboard!
        titleLabel.text = Cure.shared.translation(for: "title", inTab: "home")
        
        // No additional setup required - real-time updates happen automatically
    }
}
```

### Manual Real-time Updates (Advanced)

For cases requiring custom update handling, you can still use manual subscriptions:

```swift
// Subscribe to real-time updates for a specific screen
Cure.shared.onTranslationsUpdated(for: "home_screen") { updatedTranslations in
    // Handle the updated translations dictionary
    // updatedTranslations contains all key-value pairs for current language
    DispatchQueue.main.async {
        self.updateUI(with: updatedTranslations)
    }
}
```

### Configuration Options

```swift
// Enable auto real-time updates (default behavior)
Cure.shared.configure(
    projectId: "YOUR_PROJECT_ID",
    apiKey: "YOUR_API_KEY", 
    projectSecret: "YOUR_PROJECT_SECRET",
    enableAutoRealTimeUpdates: true  // Default: true
)

// Disable auto real-time updates (traditional behavior)
Cure.shared.configure(
    projectId: "YOUR_PROJECT_ID",
    apiKey: "YOUR_API_KEY", 
    projectSecret: "YOUR_PROJECT_SECRET",
    enableAutoRealTimeUpdates: false  // Use manual subscriptions only
)
```

### Fetching Data Store Items

**🚀 Enhanced with Automatic Real-time Updates!**

Retrieve all items for a specific data store. The `getStoreItems(for:)` method now **automatically enables real-time updates** while maintaining 100% backward compatibility.

```swift
// Same method call, now with automatic real-time updates!
let products = Cure.shared.getStoreItems(for: "products")

// This automatically:
// ✅ Returns immediate cached items array
// ✅ Sets up real-time subscription for this data store in background  
// ✅ Syncs store data if not already synced
// ✅ Receives live data store updates from CMSCure dashboard

// Use the items
for product in products {
    let name = product.data["name"]?.localizedString ?? "N/A"
    let price = product.data["price"]?.doubleValue ?? 0.0
    print("Product: \(name), Price: $\(price)")
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

## Migration Guide

### Enhanced Core Methods

**For Existing Projects:**
- ✅ **No Code Changes Required** - All existing method calls automatically gain real-time updates:
  - `translation(for:inTab:)` - Enhanced translations with auto real-time updates
  - `colorValue(for:)` - Enhanced colors with auto real-time updates  
  - `imageURL(forKey:)` - Enhanced global images with auto real-time updates
  - `getStoreItems(for:)` - Enhanced data stores with auto real-time updates
- ✅ **Backward Compatible** - All existing functionality works exactly the same
- ✅ **Opt-out Available** - Set `enableAutoRealTimeUpdates: false` if you prefer traditional behavior

**For New Projects:**
- ✅ **Use as Normal** - Just call any core method and enjoy automatic real-time updates
- ✅ **Enhanced UX** - Your users will see live content updates from the CMSCure dashboard
- ✅ **Easy Implementation** - No need to manually set up real-time subscriptions

**Performance Notes:**
- Auto-subscription happens only once per accessed resource with minimal overhead
- Background processing doesn't block your method calls  
- Smart caching prevents duplicate subscriptions and unnecessary API calls
- Intelligent resource management for colors, images, translations, and data stores

For detailed examples and advanced configuration, see [ENHANCED_TRANSLATION_GUIDE.md](ENHANCED_TRANSLATION_GUIDE.md).

## License

CMSCureSDK is released under the **MIT** License. See `LICENSE.md` for details.
