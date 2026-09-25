import Foundation

/// One key of a string table, in the language the app is written in.
struct StringEntry: Equatable {
    var key: String
    /// What the app formats at run time: the source-language value, or the
    /// key itself when the table has no value for it (Xcode's extracted
    /// strings, whose key is the English text).
    var format: String
    /// What the doc comment shows: `format` with rule variables spelled out
    /// (`%#@items@` → `%lld items`).
    var preview: String
    var comment: String?
    /// For `%#@name@` rules: the specifier each one formats (`lld`) and, in a
    /// string catalog, the argument it takes.
    var variables: [String: Variable] = [:]

    struct Variable: Equatable {
        var specifier: String
        var position: Int?
    }

    init(key: String, format: String, comment: String? = nil) {
        self.key = key
        self.format = format
        self.preview = format
        self.comment = comment
    }
}

struct StringTable: Equatable {
    var name: String
    var entries: [String: StringEntry]
    /// A file the table came from, for pointing warnings at it.
    var file: String?
}

struct Warning: Equatable, CustomStringConvertible {
    var file: String?
    var message: String

    /// The form Xcode and SwiftPM show as a build warning.
    var description: String {
        (file.map { "\($0): " } ?? "") + "warning: " + message
    }
}

enum Catalog {
    /// Tables that belong to the system, not to the app's code.
    static let skippedTables: Set<String> = ["InfoPlist", "AppShortcuts"]

    static func isTable(_ url: URL) -> Bool {
        ["xcstrings", "strings", "stringsdict"].contains(url.pathExtension)
            && !skippedTables.contains(url.deletingPathExtension().lastPathComponent)
    }

    /// Reads every table file, one table per file name. A key's value comes
    /// from the string catalog when there is one, else from the best language
    /// among the `.lproj` folders: `sourceLanguage`, then an unlocalized file,
    /// `Base`, `en`, and the rest alphabetically. Every key found in any
    /// language gets an accessor.
    static func read(_ urls: [URL], sourceLanguage: String?) -> (tables: [StringTable], warnings: [Warning]) {
        var warnings: [Warning] = []
        var byTable: [String: [URL]] = [:]
        for url in urls.sorted(by: { $0.path < $1.path }) where isTable(url) {
            byTable[url.deletingPathExtension().lastPathComponent, default: []].append(url)
        }

        var tables: [StringTable] = []
        for (name, files) in byTable {
            var entries: [String: StringEntry] = [:]
            let legacy = files.filter { $0.pathExtension != "xcstrings" }
                .sorted { rank($0, sourceLanguage) < rank($1, sourceLanguage) }
            for url in files where url.pathExtension == "xcstrings" {
                do {
                    for entry in try xcstrings(Data(contentsOf: url)) where entries[entry.key] == nil {
                        entries[entry.key] = entry
                    }
                } catch {
                    warnings.append(Warning(file: url.path, message: "not a readable string catalog, skipped: \(error.localizedDescription)"))
                }
            }
            for url in legacy {
                do {
                    let data = try Data(contentsOf: url)
                    let found = url.pathExtension == "stringsdict"
                        ? try stringsdict(data)
                        : try strings(data).map { StringEntry(key: $0.key, format: $0.value) }
                    for entry in found where entries[entry.key] == nil {
                        entries[entry.key] = entry
                    }
                } catch {
                    warnings.append(Warning(file: url.path, message: "not a readable strings file, skipped: \(error.localizedDescription)"))
                }
            }
            tables.append(StringTable(name: name, entries: entries, file: files.first?.path))
        }
        return (tables.sorted { $0.name < $1.name }, warnings)
    }

    /// Orders the legacy files of one table: the preferred language first, and
    /// within a language the `.stringsdict`, which wins at run time too.
    private static func rank(_ url: URL, _ sourceLanguage: String?) -> String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        let language = folder.hasSuffix(".lproj") ? String(folder.dropLast(6)) : nil
        let order: String
        if let language, language == sourceLanguage {
            order = "0"
        } else if let language {
            order = language == "Base" ? "2" : language == "en" ? "3" : "4" + language
        } else {
            order = "1"
        }
        return order + "\u{0}" + (url.pathExtension == "stringsdict" ? "0" : "1")
    }

    // MARK: Formats

    /// A string catalog (`.xcstrings`, JSON).
    static func xcstrings(_ data: Data) throws -> [StringEntry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError("the top level is not an object")
        }
        let source = root["sourceLanguage"] as? String ?? "en"
        let strings = root["strings"] as? [String: Any] ?? [:]
        return strings.map { key, raw in
            let item = raw as? [String: Any] ?? [:]
            var entry = StringEntry(key: key, format: key, comment: item["comment"] as? String)
            let localizations = item["localizations"] as? [String: Any]
            guard let unit = localizations?[source] as? [String: Any] else { return entry }
            if let value = (unit["stringUnit"] as? [String: Any])?["value"] as? String {
                entry.format = value
            } else if let variations = unit["variations"] as? [String: Any], let value = representative(variations) {
                entry.format = value
            }
            entry.preview = entry.format
            for (name, raw) in unit["substitutions"] as? [String: Any] ?? [:] {
                let substitution = raw as? [String: Any] ?? [:]
                let specifier = substitution["formatSpecifier"] as? String ?? "lld"
                entry.variables[name] = .init(specifier: specifier, position: substitution["argNum"] as? Int)
                if let variations = substitution["variations"] as? [String: Any], let form = representative(variations) {
                    // Inside a substitution the argument is written `%arg`.
                    entry.preview = spellOut(name, in: entry.preview, as: form.replacingOccurrences(of: "%arg", with: "%" + specifier))
                }
            }
            return entry
        }
    }

    /// A `.strings` file: the old-style property list of `"key" = "value";`.
    static func strings(_ data: Data) throws -> [String: String] {
        if let text = String(data: data, encoding: .utf8), isBlank(text) { return [:] }
        guard let table = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            throw CatalogError("not a table of strings")
        }
        return table
    }

    /// A `.stringsdict` file: one rule set per key.
    static func stringsdict(_ data: Data) throws -> [StringEntry] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CatalogError("not a dictionary")
        }
        return root.compactMap { key, raw in
            guard let rules = raw as? [String: Any] else { return nil }
            if let widths = rules["NSStringVariableWidthRuleType"] as? [String: String] {
                // Width variants: the widest one stands for the key.
                let widest = widths.max { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
                return widest.map { StringEntry(key: key, format: $0.value) }
            }
            guard let format = rules["NSStringLocalizedFormatKey"] as? String else { return nil }
            var entry = StringEntry(key: key, format: format)
            for (name, raw) in rules where name != "NSStringLocalizedFormatKey" {
                guard let rule = raw as? [String: Any] else { continue }
                entry.variables[name] = .init(specifier: rule["NSStringFormatValueTypeKey"] as? String ?? "lld")
                if let other = (rule["other"] ?? rule["many"] ?? rule["one"]) as? String {
                    entry.preview = spellOut(name, in: entry.preview, as: other)
                }
            }
            return entry
        }
    }

    /// Picks the variant that stands for the rest: `other`, else the first.
    private static func representative(_ variations: [String: Any]) -> String? {
        for kind in variations.keys.sorted() {
            guard let cases = variations[kind] as? [String: Any] else { continue }
            let chosen = cases["other"] ?? cases.keys.sorted().first.flatMap { cases[$0] }
            guard let node = chosen as? [String: Any] else { continue }
            if let value = (node["stringUnit"] as? [String: Any])?["value"] as? String { return value }
            if let nested = node["variations"] as? [String: Any], let value = representative(nested) { return value }
        }
        return nil
    }

    /// Replaces the `%#@name@` placeholders in `text` with `form`.
    private static func spellOut(_ name: String, in text: String, as form: String) -> String {
        let pattern = "%(?:\\d+\\$)?#@" + NSRegularExpression.escapedPattern(for: name) + "@"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(
            in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: form)
        )
    }

    /// A file with nothing but comments and whitespace, which the property
    /// list reader refuses although it is a valid, empty table.
    private static func isBlank(_ text: String) -> Bool {
        var rest = Substring(text)
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            if rest.hasPrefix("//") {
                rest = rest.drop { !$0.isNewline }
            } else if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return false }
                rest = rest[end.upperBound...]
            } else {
                return rest.isEmpty
            }
        }
    }
}

struct CatalogError: Error, LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
