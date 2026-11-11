import Foundation

/// What the swizzled `Bundle` methods ask before they fall back to the shipped
/// strings. Everything read here sits behind a lock, so a `LocalizeMe.start()`
/// on another thread cannot race a lookup.
enum Intercept {
    /// The OTA value for a `Bundle.main` lookup, or nil to use the shipped one.
    static func string(bundle: Bundle, key: String, value: String?, table: String?) -> String? {
        guard let client = client(for: bundle) else { return nil }
        if let plural = client.pluralString(forKey: key, table: table) { return plural }
        return candidate(client: client, key: key, table: table)?.value
    }

    /// The OTA value for an attributed `Bundle.main` lookup, parsed the way
    /// Foundation parses shipped strings (inline Markdown, so `**bold**` is
    /// bold and not two asterisks), or nil to use the shipped one.
    ///
    /// The text is parsed here rather than handed to the original method as
    /// its `value:`: Foundation caches attributed results per key, and would
    /// keep answering with the first value it saw.
    static func attributed(bundle: Bundle, key: String, value: String?, table: String?) -> NSAttributedString? {
        guard let client = client(for: bundle) else { return nil }
        // Foundation builds a plural's attributed string itself, rules and all.
        if let plural = client.pluralAttributedString(forKey: key, table: table) { return plural }
        guard let hit = candidate(client: client, key: key, table: table) else { return nil }
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
        guard shipped == key, (value ?? "").isEmpty,
              let client = LocalizeMe.current, bundle === client.appBundle else { return }
        client.noteMissing(key)
    }

    /// The client, when it answers lookups on `bundle`: the app's bundle
    /// (`Bundle.main`) with interception on.
    private static func client(for bundle: Bundle) -> Client? {
        guard let client = LocalizeMe.current, bundle === client.appBundle,
              client.configuration.interceptBundleLookups else { return nil }
        return client
    }

    /// The client and its OTA value for `key`, when there is one the app may
    /// show: the live strings have the key, and its placeholders match the
    /// shipped string's.
    private static func candidate(client: Client, key: String, table: String?) -> (client: Client, value: String)? {
        guard let value = client.string(forKey: key),
              client.isSafe(key: key, table: table, ota: value)
        else { return nil }
        return (client, value)
    }
}
