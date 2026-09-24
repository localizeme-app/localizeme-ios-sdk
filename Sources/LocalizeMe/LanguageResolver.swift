import Foundation

/// Picks which published language a device should show.
///
/// Published languages come with every code they answer to (`no` is also `nb`
/// and `nb-NO`). Apple's own matcher, `Bundle.preferredLocalizations(from:forPreferences:)`,
/// chooses among those codes the way the OS chooses an `.lproj`, so the SDK
/// and the app agree on the language. The matcher always answers something,
/// even when nothing fits, so a hit only counts when it is the same language
/// as the preference (and the same script, when both name one). When it has
/// nothing, subtags are dropped one at a time: `zh-Hant-TW`, `zh-Hant`, `zh`.
enum LanguageResolver {
    /// - Parameters:
    ///   - preferred: languages in order of preference, most preferred first.
    ///   - available: published language code → the other codes it answers to.
    ///   - override: a language the app asked for; used when it is published,
    ///     otherwise the device's preferences decide.
    /// - Returns: the published language's own code.
    static func resolve(preferred: [String], available: [String: [String]], override: String?) -> String? {
        guard !available.isEmpty else { return nil }
        // Every spelling, normalized, back to the published code it belongs
        // to. A published code wins over another language claiming it as an
        // alias.
        var canonical: [String: String] = [:]
        var spellings: [String] = []
        for code in available.keys {
            canonical[normalize(code)] = code
            spellings.append(code)
        }
        for (code, aliases) in available {
            for alias in aliases where canonical[normalize(alias)] == nil {
                canonical[normalize(alias)] = code
                spellings.append(alias)
            }
        }
        spellings.sort()

        func match(_ code: String) -> String? {
            if let hit = Bundle.preferredLocalizations(from: spellings, forPreferences: [code]).first,
               sameLanguage(hit, code), let published = canonical[normalize(hit)] {
                return published
            }
            var parts = normalize(code).split(separator: "-").map(String.init)
            while !parts.isEmpty {
                if let published = canonical[parts.joined(separator: "-")] { return published }
                parts.removeLast()
            }
            return nil
        }

        if let override, let hit = match(override) { return hit }
        for code in preferred {
            if let hit = match(code) { return hit }
        }
        return nil
    }

    /// `pt-BR` and `pt_BR` are the same language; case does not matter either.
    static func normalize(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// Whether the matcher's answer is really about the preference and not its
    /// fallback: the same language, and not another script of it.
    private static func sameLanguage(_ hit: String, _ preference: String) -> Bool {
        let a = Locale(identifier: hit)
        let b = Locale(identifier: preference)
        guard let languageA = a.languageCode, let languageB = b.languageCode, languageA == languageB else {
            return false
        }
        if let scriptA = a.scriptCode, let scriptB = b.scriptCode, scriptA != scriptB {
            return false
        }
        return true
    }
}
