import Foundation

/// What the swizzled `Bundle` methods ask before they fall back to the shipped
/// strings. Everything read here sits behind a lock, so a `LocalizeMe.start()`
/// on another thread cannot race a lookup.
enum Intercept {
    /// The OTA value for a `Bundle.main` lookup, or nil to use the shipped one.
    static func string(bundle: Bundle, key: String, value: String?, table: String?) -> String? {
        candidate(bundle: bundle, key: key, table: table)?.value
    }

    /// The OTA value for an attributed `Bundle.main` lookup, parsed the way
    /// Foundation parses shipped strings (inline Markdown, so `**bold**` is
    /// bold and not two asterisks), or nil to use the shipped one.
    ///
    /// The text is parsed here rather than handed to the original method as
    /// its `value:`: Foundation caches attributed results per key, and would
    /// keep answering with the first value it saw.
    static func attributed(bundle: Bundle, key: String, value: String?, table: String?) -> NSAttributedString? {
        guard let hit = candidate(bundle: bundle, key: key, table: table) else { return nil }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var attributed = (try? AttributedString(markdown: hit.value, options: options)) ?? AttributedString(hit.value)
        if let language = hit.client.language {
            attributed.languageIdentifier = language
        }
        return NSAttributedString(attributed)
    }

    /// Called with what the original implementation answered. A key that came
    /// back as itself, with no default value to explain it, is one nobody has.
    static func noteMiss(bundle: Bundle, key: String, value: String?, shipped: String) {
        guard shipped == key, (value ?? "").isEmpty, bundle === Bundle.main,
              let client = LocalizeMe.current else { return }
        client.noteMissing(key)
    }

    /// The client and its OTA value for `key`, when there is one the app may
    /// show: the lookup is on `Bundle.main`, interception is on, the live
    /// strings have the key, and its placeholders match the shipped string's.
    private static func candidate(bundle: Bundle, key: String, table: String?) -> (client: Client, value: String)? {
        guard bundle === Bundle.main,
              let client = LocalizeMe.current,
              client.configuration.interceptBundleLookups,
              let value = client.string(forKey: key),
              client.isSafe(key: key, table: table, ota: value)
        else { return nil }
        return (client, value)
    }
}
