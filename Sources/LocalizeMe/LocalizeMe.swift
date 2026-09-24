import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Over-the-air translations from LocalizeMe.
///
/// ```swift
/// LocalizeMe.start(sdkKey: "lzs_…")   // from the project's Mobile SDK tab
/// ```
///
/// After that, `NSLocalizedString`, `Bundle.main.localizedString(forKey:value:table:)`,
/// `Bundle.main.localizedAttributedString(forKey:value:table:)` and the SwiftUI
/// views that take a `LocalizedStringKey` (`Text("key")`, `Text("key \(n)")`,
/// `Button("key")`, `Label`, `.navigationTitle`) return the latest approved
/// strings for the language the app is showing, falling back to what the app
/// shipped with.
///
/// Not intercepted, because they use private Foundation entry points and the
/// SDK only touches public API: `String(localized:)`, `LocalizedStringResource`
/// and `Text(LocalizedStringResource)`, `AttributedString(localized:)`, a
/// `Text` that sets `.environment(\.locale, …)`, strings in other bundles
/// (including `Bundle.module`) and `.stringsdict` plural rules. Use
/// `localizedString(forKey:table:)` or `text(_:table:)` there.
///
/// An OTA value whose placeholders differ from the shipped string's is never
/// shown. The SDK checks for changes on launch and when the app returns to
/// the foreground, and applies them on the next launch unless
/// `applyImmediately` is set or `applyNow()` is called.
public enum LocalizeMe {
    private static let lock = NSLock()
    private static var client: Client?

    /// Start with just a key and the defaults.
    public static func start(sdkKey: String) {
        start(LocalizeMeConfiguration(sdkKey: sdkKey))
    }

    public static func start(_ configuration: LocalizeMeConfiguration) {
        let client = Client(configuration: configuration)
        install(client)
    }

    /// Called on the main thread whenever a new version arrives, with its
    /// version number. With `applyImmediately` off, the strings are staged;
    /// call `applyNow()` from here to swap them in and re-render.
    public static var onUpdate: ((Int) -> Void)? {
        didSet { current?.onUpdate = onUpdate }
    }

    /// Check for new strings now, ignoring the minimum interval.
    public static func check(completion: ((Result<LocalizeMeCheckOutcome, LocalizeMeError>) -> Void)? = nil) {
        guard let client = current else {
            completion?(.failure(LocalizeMeError(kind: .notStarted, message: "call LocalizeMe.start first")))
            return
        }
        client.check(force: true, completion: completion)
    }

    /// Swap a staged version in without waiting for the next launch. Returns
    /// once the new strings are live, so the caller can re-render right after;
    /// true when something changed. Does not call `onUpdate`.
    @discardableResult
    public static func applyNow() -> Bool {
        current?.applyNow() ?? false
    }

    /// Whether a newer version is downloaded and waiting.
    public static var hasStagedUpdate: Bool {
        current?.hasStagedUpdate ?? false
    }

    /// Show this language instead of the one the app is showing. `nil` follows
    /// the app again.
    public static func setLanguage(_ code: String?) {
        current?.setLanguage(code)
    }

    // MARK: Lookups

    /// The string to show for `key`: the approved OTA value when there is one
    /// whose placeholders match the shipped string's, otherwise the shipped
    /// string from `Bundle.main`, as `NSLocalizedString` returns it. For the
    /// call sites the interception does not reach: `String(localized:)`,
    /// `LocalizedStringResource`, `AttributedString(localized:)`, a `Text`
    /// with an explicit locale, other bundles and `.stringsdict` plurals.
    public static func localizedString(forKey key: String, table: String? = nil) -> String {
        if let client = current, let ota = client.string(forKey: key), client.isSafe(key: key, table: table, ota: ota) {
            return ota
        }
        return Swizzle.shippedString(bundle: .main, key: key, value: nil, table: table)
    }

    /// `localizedString(forKey:table:)` with `arguments` formatted in, the way
    /// `String(format:locale:arguments:)` does it for the current locale.
    public static func localizedString(forKey key: String, table: String? = nil, arguments: CVarArg...) -> String {
        String(format: localizedString(forKey: key, table: table), locale: Locale.current, arguments: arguments)
    }

    #if canImport(SwiftUI)
    /// A `Text` showing `localizedString(forKey:table:)` verbatim, for the
    /// places where `Text("key")` is not intercepted.
    public static func text(_ key: String, table: String? = nil) -> SwiftUI.Text {
        Text(verbatim: localizedString(forKey: key, table: table))
    }
    #endif

    /// The raw OTA value for a key, or `nil` when the app should use its own.
    /// Not checked against any shipped string: format it only with the
    /// arguments the dashboard's value takes.
    public static func string(_ key: String) -> String? {
        current?.string(forKey: key)
    }

    /// The OTA value for a key, or `fallback`, which also wins when the OTA
    /// value's placeholders differ from its own.
    public static func string(_ key: String, fallback: String) -> String {
        guard let ota = current?.string(forKey: key), FormatSpecifiers.compatible(ota, fallback) else {
            return fallback
        }
        return ota
    }

    /// The version of the strings in use, 0 before anything has been downloaded.
    public static var version: Int {
        current?.version ?? 0
    }

    /// The language the live strings are in, if any.
    public static var language: String? {
        current?.language
    }

    // MARK: Internal

    static var current: Client? {
        lock.lock(); defer { lock.unlock() }
        return client
    }

    static func install(_ client: Client) {
        client.onUpdate = onUpdate
        lock.lock()
        self.client = client
        lock.unlock()
        client.start()
    }

    static func reset() {
        lock.lock()
        client = nil
        lock.unlock()
    }
}
