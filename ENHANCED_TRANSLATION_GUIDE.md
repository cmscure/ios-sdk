# CMSCure iOS SDK - Enhanced Translation Method

## Overview

The `translation(for:inTab:)` method has been enhanced with **automatic real-time updates** while maintaining **100% backward compatibility**. Existing code continues to work unchanged, but now automatically receives real-time updates.

## Key Benefits

✅ **Zero Breaking Changes** - Exact same method signature
✅ **Automatic Real-time Updates** - No additional code needed
✅ **Performance Optimized** - Intelligent subscription management
✅ **Backward Compatible** - Can be disabled if needed
✅ **Easy to Use** - Works with existing implementations

## How It Works

### Before (Traditional Behavior)
```swift
// Traditional static translation - no real-time updates
let title = CMSCureSDK.shared.translation(for: "title", inTab: "home")
// This would only show cached value, no real-time updates
```

### After (Enhanced with Auto Real-time)
```swift
// Same exact code, but now with automatic real-time updates!
let title = CMSCureSDK.shared.translation(for: "title", inTab: "home")
// This automatically:
// 1. Returns immediate cached value
// 2. Sets up real-time subscription in background
// 3. Syncs data if not already synced
// 4. Receives live updates from CMSCure dashboard
```

## Configuration Options

### Default Behavior (Recommended)
```swift
// Auto real-time updates enabled by default
CMSCureSDK.shared.configure(
    projectId: "your_project_id",
    apiKey: "your_api_key", 
    projectSecret: "your_project_secret"
)
```

### Disable Auto Real-time Updates
```swift
// For apps that need traditional behavior
CMSCureSDK.shared.configure(
    projectId: "your_project_id",
    apiKey: "your_api_key", 
    projectSecret: "your_project_secret",
    enableAutoRealTimeUpdates: false
)
```

## Usage Examples

### Basic Usage (No Code Changes)
```swift
class ViewController: UIViewController {
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var subtitleLabel: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        updateLabels()
    }
    
    private func updateLabels() {
        // These now automatically receive real-time updates!
        titleLabel.text = CMSCureSDK.shared.translation(for: "title", inTab: "home")
        subtitleLabel.text = CMSCureSDK.shared.translation(for: "subtitle", inTab: "home")
    }
}
```

### Advanced Usage with Manual Real-time (Still Supported)
```swift
class AdvancedViewController: UIViewController {
    @IBOutlet weak var titleLabel: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Option 1: Use enhanced translation() - automatic real-time
        titleLabel.text = CMSCureSDK.shared.translation(for: "title", inTab: "home")
        
        // Option 2: Use manual real-time (if you need custom handling)
        CMSCureSDK.shared.onTranslationsUpdated(for: "home") { [weak self] translations in
            self?.titleLabel.text = translations["title"] ?? ""
        }
    }
}
```

### SwiftUI Integration
```swift
struct ContentView: View {
    var body: some View {
        VStack {
            // These automatically receive real-time updates
            Text(CMSCureSDK.shared.translation(for: "welcome", inTab: "home"))
                .font(.title)
            
            Text(CMSCureSDK.shared.translation(for: "subtitle", inTab: "home"))
                .font(.subtitle)
        }
    }
}
```

## Utility Methods

### Check Auto Real-time Status
```swift
if CMSCureSDK.shared.isAutoRealTimeUpdatesEnabled() {
    print("Auto real-time updates are enabled")
}
```

### View Auto-subscribed Screens
```swift
let autoScreens = CMSCureSDK.shared.getAutoSubscribedScreens()
print("Auto-subscribed screens: \\(autoScreens)")
```

## Migration Guide

### For New Projects
No changes needed! Just use `translation(for:inTab:)` as usual and enjoy automatic real-time updates.

### For Existing Projects
1. **No Code Changes Required** - Your existing code will automatically gain real-time updates
2. **Optional Configuration** - Add `enableAutoRealTimeUpdates: false` if you prefer traditional behavior
3. **Remove Manual Subscriptions** - You can optionally remove manual `onTranslationsUpdated` calls for screens where you only need the translation value

### Performance Considerations
- **Minimal Overhead** - Auto-subscription only happens once per screen
- **Background Processing** - Real-time setup doesn't block the translation() method
- **Smart Caching** - Avoids duplicate subscriptions and unnecessary API calls
- **Thread-Safe** - All operations are properly synchronized

## Best Practices

1. **Use translation() for Simple Cases** - Perfect for labels, buttons, static text
2. **Use onTranslationsUpdated() for Complex Logic** - When you need custom update handling
3. **Enable Auto Real-time by Default** - Provides best user experience
4. **Monitor Auto-subscribed Screens** - Use utility methods for debugging

## Troubleshooting

### Q: My translations aren't updating in real-time
A: Check that `enableAutoRealTimeUpdates` is `true` (default) in your configuration

### Q: I want to disable auto real-time for specific screens
A: Set `enableAutoRealTimeUpdates: false` and use manual `onTranslationsUpdated()` for screens that need real-time

### Q: How do I know which screens are auto-subscribed?
A: Use `CMSCureSDK.shared.getAutoSubscribedScreens()` to see the list

## Technical Details

The enhancement works by:
1. **Detecting Screen Access** - When `translation()` is called, the screen is marked for auto-subscription
2. **Background Subscription** - A minimal real-time handler is set up asynchronously
3. **Intelligent Sync** - Ensures screen data is synced if not already available
4. **Cache Updates** - Real-time updates automatically refresh the cache used by `translation()`

This provides seamless real-time behavior without any breaking changes to existing code.
