import Foundation
import Testing
@testable import LocalizeMe

/// One language's plural forms as the dashboard holds them, and which
/// category Foundation's rules give a few numbers in that language.
struct PluralCase: Sendable, CustomTestStringConvertible {
    let language: String
    let forms: [String: String]
    let numbers: [(Int, String)]
    /// What `Plurals.requiredCategories` reads from Foundation.
    let required: Set<String>

    var testDescription: String { language }

    static let all: [PluralCase] = [
        PluralCase(
            language: "en",
            forms: ["one": "%lld file", "other": "%lld files"],
            numbers: [(0, "other"), (1, "one"), (2, "other"), (21, "other")],
            required: ["one", "other"]
        ),
        PluralCase(
            language: "de",
            forms: ["one": "%lld Datei", "other": "%lld Dateien"],
            numbers: [(1, "one"), (7, "other")],
            required: ["one", "other"]
        ),
        PluralCase(
            language: "lt",
            // `many` is for fractions; Lithuanian files still carry it.
            forms: ["one": "%lld failas", "few": "%lld failai", "many": "%lld failo", "other": "%lld failų"],
            numbers: [(1, "one"), (21, "one"), (2, "few"), (9, "few"), (10, "other"), (11, "other"), (101, "one")],
            required: ["one", "few", "other"]
        ),
        PluralCase(
            language: "ru",
            forms: ["one": "%lld файл", "few": "%lld файла", "many": "%lld файлов", "other": "%lld файла"],
            numbers: [(1, "one"), (21, "one"), (3, "few"), (5, "many"), (11, "many"), (100, "many")],
            required: ["one", "few", "many", "other"]
        ),
        PluralCase(
            language: "ar",
            // Forms without the number are fine: nothing is formatted into them.
            forms: [
                "zero": "لا ملفات", "one": "ملف واحد", "two": "ملفان",
                "few": "%lld ملفات", "many": "%lld ملفًا", "other": "%lld ملف",
            ],
            numbers: [(0, "zero"), (1, "one"), (2, "two"), (3, "few"), (11, "many"), (100, "other")],
            required: ["one", "two", "few", "many", "other"]
        ),
    ]
}

/// OTA plurals. Part of `ClientTests` because the facade and the swizzle are
/// process-wide. The app here is a bundle written per test, standing in for
/// `Bundle.main`, which a test runner cannot ship strings in.
extension ClientTests {
    /// A `.stringsdict` entry.
    func pluralEntry(
        _ forms: [String: String], format: String = "%#@value@", variable: String = "value", valueType: String = "lld"
    ) -> [String: Any] {
        var rule: [String: Any] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": valueType]
        rule.merge(forms) { $1 }
        return ["NSStringLocalizedFormatKey": format, variable: rule]
    }

    /// Shipped forms that name their category, so a test can tell which one
    /// Foundation picked, and that they are not the OTA ones.
    func shippedForms(_ categories: some Sequence<String>) -> [String: String] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0, "shipped \($0): %lld") })
    }

    /// An app bundle: language → key → `.stringsdict` entry.
    func makeAppBundle(_ localizations: [String: [String: [String: Any]]], table: String = "Localizable") throws -> Bundle {
        let directory = root.appendingPathComponent("apps/\(UUID().uuidString).bundle")
        for (language, entries) in localizations {
            let lproj = directory.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
            try data.write(to: lproj.appendingPathComponent("\(table).stringsdict"))
        }
        return try #require(Bundle(path: directory.path))
    }

    func format(_ format: String, _ language: String, _ n: Int) -> String {
        String(format: format, locale: Locale(identifier: language), n)
    }

    func reportedErrors() -> [[String: String]] {
        server.reports.flatMap { $0["errors"] as? [[String: String]] ?? [] }
    }

    @Test(arguments: PluralCase.all)
    func otaPluralFormsAreChosenByFoundationsRules(_ plural: PluralCase) async throws {
        let app = try makeAppBundle([plural.language: ["files": pluralEntry(shippedForms(plural.forms.keys))]])
        server.strings[plural.language] = Dictionary(uniqueKeysWithValues: plural.forms.map { ("files_\($0.key)", $0.value) })
        let client = makeClient(languages: [plural.language], intercept: true, appBundle: app)
        await install(client)
        #expect(client.language == plural.language)

        #expect(Plurals.requiredCategories(language: plural.language, root: client.pluralRoot.appendingPathComponent("probe.bundle")) == plural.required)
        let ota = app.localizedString(forKey: "files", value: nil, table: nil)
        let helper = LocalizeMe.localizedString(forKey: "files")
        for (n, category) in plural.numbers {
            let expected = format(plural.forms[category]!, plural.language, n)
            #expect(format(ota, plural.language, n) == expected, "\(n)")
            #expect(format(helper, plural.language, n) == expected, "\(n)")
        }
        // The app's own strings are still there underneath.
        let shipped = Swizzle.shippedString(bundle: app, key: "files", value: nil, table: nil)
        #expect(format(shipped, plural.language, 1) == format("shipped one: %lld", plural.language, 1))
    }

    @Test func aMissingFormKeepsTheWholeShippedEntry() async throws {
        // One app per language, so the shipped lookup reads that language.
        let app = try makeAppBundle(["lt": ["files": pluralEntry(shippedForms(["one", "few", "many", "other"]))]])
        let englishApp = try makeAppBundle(["en": ["files": pluralEntry(shippedForms(["zero", "one", "other"]))]])
        // No `few`, which Lithuanian needs for 2-9.
        server.strings["lt"] = ["files_one": "%lld failas", "files_many": "%lld failo", "files_other": "%lld failų"]
        // No `zero`, which this app ships for English, so asks for.
        server.strings["en"] = ["files_one": "%lld file", "files_other": "%lld files"]

        let lithuanian = makeClient(languages: ["lt"], intercept: true, appBundle: app)
        await install(lithuanian)
        let lt = app.localizedString(forKey: "files", value: nil, table: nil)
        // Not even the forms that are there: never a mix.
        #expect(format(lt, "lt", 1) == "shipped one: 1")
        #expect(format(lt, "lt", 2) == "shipped few: 2")
        #expect(LocalizeMe.localizedString(forKey: "files", arguments: 1) == "shipped one: 1")

        let english = makeClient(languages: ["en"], intercept: true, appBundle: englishApp)
        await install(english)
        let en = englishApp.localizedString(forKey: "files", value: nil, table: nil)
        #expect(format(en, "en", 0) == "shipped zero: 0")
        #expect(format(en, "en", 2) == "shipped other: 2")
    }

    @Test func aLanguageTheAppDoesNotShipNeedsItsOwnCategories() async throws {
        // Shipped in English only; the OTA strings bring Lithuanian.
        let app = try makeAppBundle(["en": ["files": pluralEntry(shippedForms(["one", "other"]))]])
        server.strings["lt"] = ["files_one": "%lld failas", "files_few": "%lld failai", "files_other": "%lld failų"]
        await install(makeClient(languages: ["lt"], intercept: true, appBundle: app))
        let lt = app.localizedString(forKey: "files", value: nil, table: nil)
        #expect(format(lt, "lt", 1) == "1 failas")
        #expect(format(lt, "lt", 2) == "2 failai")
        #expect(format(lt, "lt", 10) == "10 failų")

        // English needs only one and other, but Lithuanian needs few too.
        server.strings["lt"] = ["files_one": "%lld failas", "files_other": "%lld failų"]
        server.version = 2
        let client = makeClient(applyImmediately: true, languages: ["lt"], intercept: true, appBundle: app)
        await install(client)
        #expect(client.version == 2)
        let shipped = app.localizedString(forKey: "files", value: nil, table: nil)
        #expect(format(shipped, "lt", 2) == "shipped other: 2")
    }

    @Test func aFormWithOtherPlaceholdersKeepsTheShippedEntry() async throws {
        let app = try makeAppBundle(["de": ["files": pluralEntry(shippedForms(["one", "other"]))]])
        server.strings["de"] = ["files_one": "%@ Datei", "files_other": "%lld Dateien"]
        let client = makeClient(intercept: true, appBundle: app)
        await install(client)
        let de = app.localizedString(forKey: "files", value: nil, table: nil)
        #expect(format(de, "de", 1) == "shipped one: 1")
        #expect(format(de, "de", 3) == "shipped other: 3")
        #expect(LocalizeMe.localizedString(forKey: "files", arguments: 3) == "shipped other: 3")
        await settle()
        #expect(reportedErrors().filter { $0["type"] == "format_mismatch" } == [["type": "format_mismatch", "message": "files"]])
    }

    @Test func entriesWithSeveralVariablesOrArgumentsAroundOneKeepTheShippedStrings() async throws {
        let files = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
                     "one": "%1$lld file", "other": "%1$lld files"]
        let folders = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
                       "one": "%2$lld folder", "other": "%2$lld folders"]
        let app = try makeAppBundle(["de": [
            "folder": ["NSStringLocalizedFormatKey": "%1$#@files@ in %2$#@folders@", "files": files, "folders": folders],
            "owner": pluralEntry(["one": "%2$lld file", "other": "%2$lld files"], format: "%1$@: %2$#@value@"),
        ]])
        server.strings["de"] = [
            "folder_one": "%1$lld Datei", "folder_other": "%1$lld Dateien",
            "owner_one": "%1$@: %2$lld Datei", "owner_other": "%1$@: %2$lld Dateien",
        ]
        let client = makeClient(intercept: true, appBundle: app)
        await install(client)
        let folder = app.localizedString(forKey: "folder", value: nil, table: nil)
        #expect(String(format: folder, locale: Locale(identifier: "de"), 1, 3) == "1 file in 3 folders")
        let owner = app.localizedString(forKey: "owner", value: nil, table: nil)
        #expect(String(format: owner, locale: Locale(identifier: "de"), "Ana", 3) == "Ana: 3 files")
    }

    @Test func wholeStringFormsServeTheShapesXcodeCompilesCatalogsTo() async throws {
        let app = try makeAppBundle(["de": [
            // A whole-string variation with another argument.
            "owner %@ files %lld": pluralEntry(["one": "%1$@ has %2$lld file", "other": "%1$@ has %2$lld files"], format: "%2$#@value@"),
            // A substitution with text around it.
            "inbox": pluralEntry(["one": "%1$lld message", "other": "%1$lld messages"], format: "You have %1$#@msgs@", variable: "msgs"),
        ]])
        server.strings["de"] = [
            "owner %@ files %lld_one": "%1$@ hat %2$lld Datei", "owner %@ files %lld_other": "%1$@ hat %2$lld Dateien",
            "inbox_one": "Du hast eine Nachricht", "inbox_other": "Du hast %1$lld Nachrichten",
        ]
        await install(makeClient(intercept: true, appBundle: app))
        let owner = app.localizedString(forKey: "owner %@ files %lld", value: nil, table: nil)
        #expect(String(format: owner, locale: Locale(identifier: "de"), "Ana", 1) == "Ana hat 1 Datei")
        #expect(String(format: owner, locale: Locale(identifier: "de"), "Ana", 4) == "Ana hat 4 Dateien")
        let inbox = app.localizedString(forKey: "inbox", value: nil, table: nil)
        #expect(format(inbox, "de", 1) == "Du hast eine Nachricht")
        #expect(format(inbox, "de", 5) == "Du hast 5 Nachrichten")
    }

    @Test func otherTablesAreServedUnderTheirOwnName() async throws {
        let app = try makeAppBundle(["de": ["files": pluralEntry(shippedForms(["one", "other"]))]], table: "Cart")
        server.strings["de"] = ["files_one": "%lld Datei", "files_other": "%lld Dateien"]
        await install(makeClient(intercept: true, appBundle: app))
        #expect(format(app.localizedString(forKey: "files", value: nil, table: "Cart"), "de", 3) == "3 Dateien")
        #expect(LocalizeMe.localizedString(forKey: "files", table: "Cart", arguments: 3) == "3 Dateien")
        // The default table has no such plural.
        #expect(app.localizedString(forKey: "files", value: nil, table: nil) == "files")
    }

    @Test func typedAccessorsAndHelpersServeTheOTAPluralWithOrWithoutInterception() async throws {
        // `Bundle.module` holds this target's en.lproj/Localizable.stringsdict,
        // which L10n.itemsCount was generated from.
        server.strings["de"]!["items.count_one"] = "%lld Datei"
        server.strings["de"]!["items.count_other"] = "%lld Dateien"
        for intercept in [true, false] {
            await install(makeClient(intercept: intercept, appBundle: .module))
            // Generated accessors and the helper format for Locale.current,
            // which is English here: one and other.
            #expect(L10n.itemsCount(1) == "1 Datei")
            #expect(L10n.itemsCount(3) == "3 Dateien")
            #expect(LocalizeMe.localizedString(forKey: "items.count", arguments: 3) == "3 Dateien")
            let lookup = Bundle.module.localizedString(forKey: "items.count", value: nil, table: nil)
            #expect(format(lookup, "de", 3) == (intercept ? "3 Dateien" : "3 items"))
        }
    }

    @Test func aNewVersionGetsNewTablesAndOldOnesAreRemoved() async throws {
        let app = try makeAppBundle(["de": ["files": pluralEntry(shippedForms(["one", "other"]))]])
        let client = makeClient(applyImmediately: true, intercept: true, appBundle: app)
        for version in 1...4 {
            server.version = version
            server.strings["de"] = ["files_one": "%lld Datei v\(version)", "files_other": "%lld Dateien v\(version)"]
            if version == 1 { await install(client) } else { await check(client) }
            let de = app.localizedString(forKey: "files", value: nil, table: nil)
            #expect(format(de, "de", 3) == "3 Dateien v\(version)")
        }
        let tables = client.pluralRoot.appendingPathComponent("tables")
        let bundles = try FileManager.default.contentsOfDirectory(atPath: tables.path).filter { $0.hasSuffix(".bundle") }
        // This version's and the one before it.
        #expect(bundles.count == 2)
    }

    @Test func plainStringsWithoutFormsWriteNothing() async throws {
        let app = try makeAppBundle(["de": ["files": pluralEntry(shippedForms(["one", "other"]))]])
        let client = makeClient(intercept: true, appBundle: app)
        await install(client)
        #expect(client.pluralString(forKey: "files", table: nil) == nil)
        #expect(!FileManager.default.fileExists(atPath: client.pluralRoot.path))
    }
}
