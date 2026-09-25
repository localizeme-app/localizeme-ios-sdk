import Foundation

/// Turns string keys and table names into Swift identifiers.
enum Naming {
    /// A member name for a key: words split on anything that is not a letter
    /// or digit, joined in lower camel case, with placeholders left out.
    /// `home.title` → `homeTitle`, `Hello, %@!` → `hello`,
    /// `HOME_TITLE` → `homeTitle`, `404.body` → `_404Body`.
    static func memberName(for key: String) -> String {
        let words = self.words(in: withoutPlaceholders(key))
        guard !words.isEmpty else { return "key" + hash(key) }
        let shouting = !words.joined().contains { $0.isLowercase }
        let parts = shouting ? words.map { $0.lowercased() } : words
        let name = lowerFirst(parts[0]) + parts.dropFirst().map(upperFirst).joined()
        return safeIdentifier(name)
    }

    /// A type name for a table: `Onboarding` → `Onboarding`,
    /// `settings-screen` → `SettingsScreen`.
    static func typeName(for table: String) -> String {
        let words = self.words(in: table)
        guard !words.isEmpty else { return "Table" + hash(table) }
        return safeIdentifier(words.map(upperFirst).joined())
    }

    /// Whether `name` can be declared as is, for the configured type name.
    static func isPlainIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isHead(first) else { return false }
        return name.unicodeScalars.allSatisfy(isContinuation)
            && !reserved.contains(name) && !special.contains(name)
    }

    /// `name` with the adjustments that let it be declared: `_` before a
    /// leading digit, backticks around a keyword, and a trailing `_` for the
    /// few names backticks cannot rescue as a member (`self`, `init`, `Type`).
    static func safeIdentifier(_ name: String) -> String {
        var name = name
        if let first = name.unicodeScalars.first, !isHead(first) {
            name = "_" + name
        }
        if special.contains(name) { return name + "_" }
        if reserved.contains(name) { return "`\(name)`" }
        return name
    }

    /// `name` without the backticks `safeIdentifier` may have added, so a
    /// suffix can be appended to it.
    static func bare(_ name: String) -> String {
        name.hasPrefix("`") ? String(name.dropFirst().dropLast()) : name
    }

    // MARK: Words

    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar != "_", isContinuation(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                words.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }

    /// `URL` → `url`, `URLString` → `urlString`, `Title` → `title`.
    private static func lowerFirst(_ word: String) -> String {
        guard word.contains(where: { $0.isLowercase }) else { return word.lowercased() }
        let characters = Array(word)
        var run = 0
        while run < characters.count, characters[run].isUppercase { run += 1 }
        guard run > 0 else { return word }
        let lowered = run == 1 ? 1 : run - 1
        return String(characters[..<lowered]).lowercased() + String(characters[lowered...])
    }

    private static func upperFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// Placeholders say nothing about what a string is, so `%lld items`
    /// names `items`.
    private static func withoutPlaceholders(_ key: String) -> String {
        let range = NSRange(key.startIndex..., in: key)
        return placeholder.stringByReplacingMatches(in: key, range: range, withTemplate: " ")
    }

    private static let placeholder = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?(?:#@[^@]*@|[-+#0 ']*(?:\*|\d+)?(?:\.(?:\*|\d+))?(?:hh|h|ll|l|q|L|z|t|j)?[@A-Za-z%])"#
    )

    private static func isHead(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII ? (scalar.properties.isAlphabetic || scalar == "_") : scalar.properties.isXIDStart
    }

    private static func isContinuation(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            return scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_"
        }
        return scalar.properties.isXIDContinue
    }

    /// An FNV-1a hash, for keys with no letters or digits at all: stable, so
    /// adding another such key never renames this one.
    private static func hash(_ text: String) -> String {
        var value: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            value ^= UInt32(byte)
            value = value &* 0x0100_0193
        }
        return "_" + String(value, radix: 16)
    }

    /// Names a declaration can only take in backticks.
    private static let reserved: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
        "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public",
        "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue",
        "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw",
        "switch", "where", "while", "Any", "as", "await", "false", "is", "nil", "self", "Self", "super",
        "throws", "true", "try", "_",
    ]

    /// Names that stay awkward even in backticks: `L10n.Type` is the
    /// metatype, and `self`, `init` and friends mean something else after a dot.
    private static let special: Set<String> = [
        "self", "Self", "init", "deinit", "subscript", "super", "Type", "Protocol", "_",
    ]
}
