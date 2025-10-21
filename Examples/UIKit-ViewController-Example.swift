import UIKit
import CMSCureSDK

// MARK: - Simple Legacy Approach (Backward Compatible) ✅ RECOMMENDED

/// ✅ EASIEST APPROACH - Perfect for existing customers!
/// Just implement cmsContentDidUpdate() - the SDK handles everything automatically.
/// Works for ALL content types: translations, colors, images, and data stores.
class SimpleViewController: UIViewController {

    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var heroImageView: UIImageView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Initial content load
        updateContentFromCMS()
        
        // ✅ That's it! No need to register for notifications.
        // The SDK will automatically call cmsContentDidUpdate() when ANY content updates
    }
    
    func updateContentFromCMS() {
        // Get translations, colors, images - all will trigger cmsContentDidUpdate() on updates
        let firstName = Cure.shared.translation(for: "f_name", inTab: "test")
        let primaryColor = Cure.shared.colorValue(for: "primary_color")
        
        // Load image with Kingfisher
        if let imageUrl = Cure.shared.imageURL(forKey: "vc_hero_image") {
            heroImageView.kf.setImage(with: imageUrl)
            // Updates automatically when image changes in CMS! 🎉
        }
        
        print("First Name: \(firstName)")
        print("Primary Color: \(primaryColor)")
        
        // Update UI
        titleLabel.text = firstName
        // ... update other UI elements
    }
    
    /// ✅ LEGACY SUPPORT: This method is automatically called by the SDK
    /// whenever ANY content updates (translations, colors, images, data stores)
    @objc func cmsContentDidUpdate() {
        print("🔄 Content updated from CMS!")
        self.updateContentFromCMS()
    }
}

// MARK: - Modern Approach Using NotificationCenter

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 🔔 IMPORTANT: Register for translation updates notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(translationsDidUpdate(_:)),
            name: .translationsUpdated,  // ✅ Use the correct notification name
            object: nil
        )
        
        // Initial content load
        updateContentFromCMS()
    }
    
    func updateContentFromCMS() {
        // 📱 Get translation - this will automatically subscribe to real-time updates
        let firstName = Cure.shared.translation(for: "f_name", inTab: "test")
        print("First Name: \(firstName)")
        
        // Update your UI here
        // e.g., nameLabel.text = firstName
    }
    
    // ✅ This is the correct method signature for the notification observer
    @objc func translationsDidUpdate(_ notification: Notification) {
        // Optional: Check which screen was updated
        if let screenName = notification.userInfo?["screenName"] as? String {
            print("🔄 Translations updated for screen: \(screenName)")
        }
        
        // Refresh your UI with the new content
        self.updateContentFromCMS()
    }
    
    deinit {
        // Clean up the observer when view controller is deallocated
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Alternative Approach Using Handler

class ViewControllerWithHandler: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 🎯 Alternative: Use the handler-based approach for specific screens
        Cure.shared.onTranslationsUpdated(for: "test") { [weak self] updatedValues in
            print("🔄 Test screen updated with values: \(updatedValues)")
            self?.updateContentFromCMS()
        }
        
        // Initial content load
        updateContentFromCMS()
    }
    
    func updateContentFromCMS() {
        let firstName = Cure.shared.translation(for: "f_name", inTab: "test")
        print("First Name: \(firstName)")
        // Update UI...
    }
}
