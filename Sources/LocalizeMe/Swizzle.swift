import Foundation
import ObjectiveC

/// Routes `Bundle.main`'s two public lookup methods through the OTA strings,
/// so `NSLocalizedString`, `Bundle.main.localizedString(forKey:value:table:)`,
/// `Bundle.main.localizedAttributedString(forKey:value:table:)` and the SwiftUI
/// views that take a `LocalizedStringKey` (`Text("key")`, `Text("key \(n)")`,
/// `Button("key")`, `Label`, `.navigationTitle`) pick them up without a code
/// change. SwiftUI formats the arguments itself from what the lookup returns.
///
/// Only public API is exchanged. `String(localized:)`, `LocalizedStringResource`,
/// `AttributedString(localized:)`, a `Text` given an explicit locale, other
/// bundles and `.stringsdict` plurals go through private Foundation entry
/// points and keep their shipped strings; `LocalizeMe.localizedString(forKey:)`
/// and `LocalizeMe.text(_:)` cover them.
enum Swizzle {
    private static let lock = NSLock()
    private static var installed = false
    private static var attributedInstalled = false

    /// `-[NSBundle localizedAttributedStringForKey:value:table:]` is refined for
    /// Swift, so `#selector` cannot name it; this is its documented selector.
    private static let attributedSelector = NSSelectorFromString("localizedAttributedStringForKey:value:table:")

    /// Exchanges the implementations, once per process. False when the plain
    /// method could not be found, in which case nothing is intercepted.
    static func install() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if installed { return true }
        guard
            let original = class_getInstanceMethod(Bundle.self, #selector(Bundle.localizedString(forKey:value:table:))),
            let replacement = class_getInstanceMethod(Bundle.self, #selector(Bundle.lz_localizedString(forKey:value:table:)))
        else {
            return false
        }
        method_exchangeImplementations(original, replacement)
        installed = true
        if let original = class_getInstanceMethod(Bundle.self, attributedSelector),
           let replacement = class_getInstanceMethod(
               Bundle.self, #selector(Bundle.lz_localizedAttributedString(forKey:value:table:))
           ) {
            method_exchangeImplementations(original, replacement)
            attributedInstalled = true
        }
        return true
    }

    /// The shipped string: what the original implementation answers, never an
    /// OTA value. After the exchange the original answers to the `lz_` selector.
    static func shippedString(bundle: Bundle, key: String, value: String?, table: String?) -> String {
        lock.lock()
        let exchanged = installed
        lock.unlock()
        return exchanged
            ? bundle.lz_localizedString(forKey: key, value: value, table: table)
            : bundle.localizedString(forKey: key, value: value, table: table)
    }

    /// The shipped attributed string, as `shippedString` for the attributed method.
    static func shippedAttributedString(bundle: Bundle, key: String, value: String?, table: String?) -> NSAttributedString {
        lock.lock()
        let exchanged = attributedInstalled
        lock.unlock()
        return exchanged
            ? bundle.lz_localizedAttributedString(forKey: key, value: value, table: table)
            : bundle.__localizedAttributedString(forKey: key, value: value, table: table)
    }
}

extension Bundle {
    @objc dynamic func lz_localizedString(forKey key: String, value: String?, table: String?) -> String {
        if let hit = Intercept.string(bundle: self, key: key, value: value, table: table) {
            return hit
        }
        // Implementations are exchanged, so this calls the original.
        let shipped = lz_localizedString(forKey: key, value: value, table: table)
        Intercept.noteMiss(bundle: self, key: key, value: value, shipped: shipped)
        return shipped
    }

    @objc dynamic func lz_localizedAttributedString(forKey key: String, value: String?, table: String?) -> NSAttributedString {
        if let hit = Intercept.attributed(bundle: self, key: key, value: value, table: table) {
            return hit
        }
        let shipped = lz_localizedAttributedString(forKey: key, value: value, table: table)
        Intercept.noteMiss(bundle: self, key: key, value: value, shipped: shipped.string)
        return shipped
    }
}
