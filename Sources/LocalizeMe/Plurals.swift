import Foundation

/// OTA plural forms, served so that Foundation still chooses the form.
///
/// A bundle carries a plural as one key per CLDR category, `<key>_one`,
/// `<key>_other` and so on, each the whole string for that category (the way
/// an Android `<plurals>` item is). Foundation only applies plural rules to a
/// string that a bundle loaded from a `.stringsdict`, and the entry points that
/// do so are private. So, with public API only:
///
/// 1. The app's compiled `.stringsdict` tables (string catalogs compile to
///    them) say which keys it ships as plurals, and how: the variable and its
///    value type.
/// 2. For each such key with OTA forms, a copy of the shipped entry is made
///    with the OTA forms, and the copies are written as `.stringsdict` files
///    into a bundle directory the SDK owns.
/// 3. Lookups of those keys answer with that bundle's
///    `localizedString(forKey:value:table:)`. The string it returns carries
///    Foundation's plural configuration, so `String.localizedStringWithFormat`,
///    SwiftUI and `String(format:locale:)` pick the form with Foundation's own
///    rules for the locale they format in.
///
/// A key is served only whole: when a category is missing, or a form takes
/// other arguments than the shipped strings, the shipped entry stays, never a
/// mix of the two. Entries with more than one plural variable, or with
/// placeholders outside their variable, keep their shipped strings too.
struct PluralTables {
    struct Entry {
        /// What the app's own lookup answers with: the shipped format key.
        let shippedFormat: String
        /// What a lookup of the OTA entry answers with.
        let format: String
    }

    /// The SDK's bundle with the OTA entries.
    let bundle: Bundle
    /// table → key → its formats.
    let entries: [String: [String: Entry]]

    func serves(_ key: String, table: String?) -> Bool {
        entries[table ?? Plurals.defaultTable]?[key] != nil
    }

    /// The table that serves `key` for a caller holding `format`, the string a
    /// lookup of `key` gave it: either the shipped plural or the OTA one.
    /// Accessors that do not know their table pass what they looked up.
    func table(forKey key: String, format: String) -> String? {
        entries.keys.sorted().first { table in
            guard let entry = entries[table]?[key] else { return false }
            return entry.shippedFormat == format || entry.format == format
        }
    }
}

enum Plurals {
    static let defaultTable = "Localizable"

    /// CLDR's categories, in the order `.stringsdict` files list them.
    static let categories = ["zero", "one", "two", "few", "many", "other"]

    /// One single-variable plural the app ships.
    struct Shipped: Equatable {
        let key: String
        /// The variable as the format key names it: `%#@value@`, `%2$#@value@`.
        let token: String
        /// The format key, the token plus any text around it.
        let format: String
        let variable: String
        let valueType: String?
        /// category → the whole string: the format key with the form in place
        /// of the token.
        let forms: [String: String]
    }

    // MARK: Building

    /// The OTA plurals for `strings` in `language`, as a loaded bundle, or nil
    /// when there are none to serve. `mismatch` is called with each key left
    /// to its shipped strings because of its placeholders.
    static func build(
        strings: [String: String], language: String, appBundle: Bundle, root: URL,
        log: (String) -> Void = { _ in }, mismatch: (String) -> Void = { _ in }
    ) -> PluralTables? {
        let bases = formBases(in: strings)
        guard !bases.isEmpty else { return nil }

        let rules = requiredCategories(language: language, root: root.appendingPathComponent("probe.bundle"))
        var files: [String: [String: Any]] = [:]
        var entries: [String: [String: PluralTables.Entry]] = [:]
        for (table, source) in shippedTables(appBundle: appBundle, language: language) {
            for (key, shipped) in shippedEntries(at: source.url) where bases.contains(key) {
                var forms: [String: String] = [:]
                for category in categories {
                    if let value = strings["\(key)_\(category)"] { forms[category] = value }
                }
                var required = rules
                if source.sameLanguage { required.formUnion(shipped.forms.keys) }
                let missing = required.subtracting(forms.keys)
                guard missing.isEmpty else {
                    log("plural \"\(key)\" has no \(missing.sorted().joined(separator: ", ")) form; showing the shipped one")
                    continue
                }
                // Each shipped form is formatted with the same arguments, so
                // any of their placeholder sets is known to be safe, and so is
                // none at all: "One item" where the source has "1 item".
                var safe = Set(shipped.forms.values.compactMap(FormatSpecifiers.signature))
                safe.insert([:])
                guard forms.values.allSatisfy({ FormatSpecifiers.signature($0).map(safe.contains) ?? false }) else {
                    mismatch(key)
                    continue
                }
                var rule: [String: Any] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType"]
                if let valueType = shipped.valueType { rule["NSStringFormatValueTypeKey"] = valueType }
                for (category, value) in forms { rule[category] = value }
                files[table, default: [:]][key] = ["NSStringLocalizedFormatKey": shipped.token, shipped.variable: rule]
                entries[table, default: [:]][key] = PluralTables.Entry(shippedFormat: shipped.format, format: shipped.token)
            }
        }
        guard !files.isEmpty else { return nil }

        do {
            let directory = try write(files, language: language, root: root.appendingPathComponent("tables"))
            guard let bundle = Bundle(path: directory.path) else { return nil }
            return PluralTables(bundle: bundle, entries: entries)
        } catch {
            log("could not write the plural tables: \(error)")
            return nil
        }
    }

    /// The keys that have at least one `<key>_<category>` form.
    static func formBases(in strings: [String: String]) -> Set<String> {
        var bases: Set<String> = []
        for key in strings.keys {
            for category in categories where key.hasSuffix("_\(category)") {
                bases.insert(String(key.dropLast(category.count + 1)))
            }
        }
        return bases
    }

    // MARK: The app's tables

    /// table name → its `.stringsdict` in the app, from the `.lproj` of
    /// `language` when the app ships one, else from the one the bundle itself
    /// would read, with whether that file is in `language`.
    static func shippedTables(appBundle: Bundle, language: String) -> [String: (url: URL, sameLanguage: Bool)] {
        var tables: [String: (url: URL, sameLanguage: Bool)] = [:]
        func add(_ urls: [URL]?) {
            for url in urls ?? [] {
                let folder = url.deletingLastPathComponent().lastPathComponent
                let localization = folder.hasSuffix(".lproj") ? String(folder.dropLast(6)) : nil
                let same = localization.map {
                    LanguageResolver.resolve(preferred: [language], available: [$0: []], override: nil) != nil
                } ?? false
                tables[url.deletingPathExtension().lastPathComponent] = (url, same)
            }
        }
        add(appBundle.urls(forResourcesWithExtension: "stringsdict", subdirectory: nil))
        var localizations: [String: [String]] = [:]
        for localization in appBundle.localizations where localization != "Base" { localizations[localization] = [] }
        if let own = LanguageResolver.resolve(preferred: [language], available: localizations, override: nil) {
            add(appBundle.urls(forResourcesWithExtension: "stringsdict", subdirectory: nil, localization: own))
        }
        return tables
    }

    private static let cacheLock = NSLock()
    private static var shippedCache: [String: [String: Shipped]] = [:]

    /// The single-variable plurals in a `.stringsdict` file. A shipped file
    /// does not change while the app runs, so each is read once.
    static func shippedEntries(at url: URL) -> [String: Shipped] {
        cacheLock.lock()
        if let cached = shippedCache[url.path] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let entries = (try? Data(contentsOf: url)).map(shippedEntries(in:)) ?? [:]
        cacheLock.lock()
        shippedCache[url.path] = entries
        cacheLock.unlock()
        return entries
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?#@([^@]*)@")

    static func shippedEntries(in data: Data) -> [String: Shipped] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return [:]
        }
        var result: [String: Shipped] = [:]
        for (key, value) in plist {
            if let entry = value as? [String: Any], let shipped = shipped(key: key, entry: entry) {
                result[key] = shipped
            }
        }
        return result
    }

    /// An entry the SDK can serve: one plural variable, with nothing in the
    /// format key around it that takes an argument.
    private static func shipped(key: String, entry: [String: Any]) -> Shipped? {
        guard let format = entry["NSStringLocalizedFormatKey"] as? String else { return nil }
        let whole = NSRange(format.startIndex..., in: format)
        let matches = tokenPattern.matches(in: format, range: whole)
        guard matches.count == 1, let match = matches.first,
              let tokenRange = Range(match.range, in: format),
              let nameRange = Range(match.range(at: 1), in: format)
        else { return nil }
        let token = String(format[tokenRange])
        let variable = String(format[nameRange])
        var outside = format
        outside.removeSubrange(tokenRange)
        guard FormatSpecifiers.signature(outside)?.isEmpty == true,
              let rule = entry[variable] as? [String: Any],
              rule["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType"
        else { return nil }

        var forms: [String: String] = [:]
        for category in categories {
            guard let form = rule[category] as? String else { continue }
            var composed = format
            composed.replaceSubrange(tokenRange, with: form)
            // A form with a variable of its own is a second variable.
            guard let signature = FormatSpecifiers.signature(composed), !signature.values.contains("#@") else {
                return nil
            }
            forms[category] = composed
        }
        guard forms["other"] != nil else { return nil }
        return Shipped(
            key: key, token: token, format: format, variable: variable,
            valueType: rule["NSStringFormatValueTypeKey"] as? String, forms: forms
        )
    }

    // MARK: Writing

    /// Writes the tables into `<root>/<hash>.bundle/<language>.lproj` and
    /// returns the bundle directory. The name is a hash of the content:
    /// `Bundle(path:)` and its string tables are cached per path for the life
    /// of the process, so a path must never get other content. Bundles other
    /// than this one and the one before it are removed; the one before may
    /// still be answering a lookup that started before the switch.
    static func write(_ files: [String: [String: Any]], language: String, root: URL) throws -> URL {
        let fileManager = FileManager.default
        var tables: [(name: String, data: Data)] = []
        var digest = Data("\(language)\n".utf8)
        for table in files.keys.sorted() {
            let data = try PropertyListSerialization.data(fromPropertyList: files[table]!, format: .xml, options: 0)
            tables.append((table, data))
            // The plist writer's key order is not guaranteed; sorted JSON is.
            digest.append(Data("\(table)\n".utf8))
            digest.append(try JSONSerialization.data(withJSONObject: files[table]!, options: [.sortedKeys]))
        }
        let name = String(Hashing.sha256Hex(digest).prefix(32)) + ".bundle"
        let directory = root.appendingPathComponent(name, isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            excludeFromBackup(root.deletingLastPathComponent())
            let temporary = root.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
            let lproj = temporary.appendingPathComponent("\(language).lproj", isDirectory: true)
            try fileManager.createDirectory(at: lproj, withIntermediateDirectories: true)
            for table in tables {
                try table.data.write(to: lproj.appendingPathComponent("\(table.name).stringsdict"))
            }
            do {
                try fileManager.moveItem(at: temporary, to: directory)
            } catch {
                // Another client wrote the same content first.
                try? fileManager.removeItem(at: temporary)
                guard fileManager.fileExists(atPath: directory.path) else { throw error }
            }
        }

        let marker = root.appendingPathComponent("current")
        let previous = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        if previous != name {
            try? Data(name.utf8).write(to: marker, options: .atomic)
        }
        let keep: Set<String> = [name, previous, "current"]
        for item in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] where !keep.contains(item) {
            try? fileManager.removeItem(at: root.appendingPathComponent(item))
        }
        return directory
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Foundation's rules

    private static var categoryCache: [String: Set<String>] = [:]

    /// The categories a plural in `language` must have: `other`, which
    /// Foundation falls back to, and every category Foundation's own rules
    /// choose for a whole number in that language. They are read from
    /// Foundation itself, by formatting numbers with a probe entry that has
    /// every category, so the SDK and the formatting can never disagree.
    ///
    /// Zero is left out of the numbers: a `.stringsdict` `zero` form wins for
    /// 0 in every language, so 0 says nothing about the language. Categories
    /// only fractions take (Lithuanian `many`, Russian `other`) are not
    /// required, as the variable is nearly always an integer.
    static func requiredCategories(language: String, root: URL) -> Set<String> {
        cacheLock.lock()
        if let cached = categoryCache[language] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var result: Set<String> = ["other"]
        if let probe = probeFormat(root: root) {
            let locale = Locale(identifier: language)
            for n in Array(1...200) + [1_000, 10_000, 100_000, 1_000_000] {
                let category = String(format: probe, locale: locale, n)
                if categories.contains(category) { result.insert(category) }
            }
        } else {
            return result
        }
        cacheLock.lock()
        categoryCache[language] = result
        cacheLock.unlock()
        return result
    }

    /// The probe entry, loaded from a bundle written once under `root`.
    private static func probeFormat(root: URL) -> String? {
        let format = "%#@n@"
        let fileManager = FileManager.default
        let file = root.appendingPathComponent("Base.lproj/Localizable.stringsdict")
        if !fileManager.fileExists(atPath: file.path) {
            var rule: [String: Any] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "ld"]
            for category in categories { rule[category] = category }
            let plist: [String: Any] = ["probe": ["NSStringLocalizedFormatKey": format, "n": rule]]
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                return nil
            }
        }
        guard let bundle = Bundle(path: root.path) else { return nil }
        let probe = Swizzle.shippedString(bundle: bundle, key: "probe", value: nil, table: nil)
        return probe == format ? probe : nil
    }
}
