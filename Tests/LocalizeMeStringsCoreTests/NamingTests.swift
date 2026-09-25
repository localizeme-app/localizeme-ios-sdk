import Testing
@testable import LocalizeMeStringsCore

struct NamingTests {
    @Test(arguments: [
        ("home.title", "homeTitle"),
        ("button_title", "buttonTitle"),
        ("Home Title", "homeTitle"),
        ("HOME_TITLE", "homeTitle"),
        ("homeTitle", "homeTitle"),
        ("URLString", "urlString"),
        ("settings.userID", "settingsUserID"),
        ("Hello, %@!", "hello"),
        ("%lld items", "items"),
        ("%1$@ sent %2$lld photos", "sentPhotos"),
        ("You have %#@count@", "youHave"),
        ("404.body", "_404Body"),
        ("default", "`default`"),
        ("self", "self_"),
        ("init", "init_"),
        ("Größe", "größe"),
    ])
    func memberNames(key: String, expected: String) {
        #expect(Naming.memberName(for: key) == expected)
    }

    @Test func aKeyWithNoWordsGetsAStableHashedName() {
        let name = Naming.memberName(for: "👋")
        #expect(name.hasPrefix("key_"))
        #expect(name == Naming.memberName(for: "👋"))
        #expect(name != Naming.memberName(for: "🎉"))
    }

    @Test(arguments: [
        ("Onboarding", "Onboarding"),
        ("settings-screen", "SettingsScreen"),
        ("Type", "Type_"),
        ("2fa", "_2fa"),
    ])
    func typeNames(table: String, expected: String) {
        #expect(Naming.typeName(for: table) == expected)
    }

    @Test func plainIdentifiersForTheConfiguredTypeName() {
        #expect(Naming.isPlainIdentifier("L10n"))
        #expect(Naming.isPlainIdentifier("Strings"))
        #expect(!Naming.isPlainIdentifier("1Strings"))
        #expect(!Naming.isPlainIdentifier("my-strings"))
        #expect(!Naming.isPlainIdentifier("Self"))
    }
}
