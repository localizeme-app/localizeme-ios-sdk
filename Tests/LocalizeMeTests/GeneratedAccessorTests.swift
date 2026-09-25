import Foundation
import Testing
@testable import LocalizeMe

/// `L10n` here is what the LocalizeMeStrings plugin generated for this
/// target's own tables: `Resources/en.lproj` and `Fixtures/Onboarding.xcstrings`.
/// Part of `ClientTests` because they share the process-wide facade.
extension ClientTests {
    @Test func generatedAccessorsFallBackToTheShippedStrings() {
        #expect(L10n.homeTitle == "Home")
        #expect(L10n.greeting("Ana") == "Hello Ana")
        #expect(L10n.discount == "20% off")
        #expect(L10n.files("Docs", 3) == "Docs has 3 files")
        #expect(L10n.swapped("B", "A") == "A before B")
        #expect(L10n.itemsCount(1) == "1 item")
        #expect(L10n.itemsCount(3) == "3 items")
        // The catalog is copied rather than compiled, so the bundle has no
        // values for it and a lookup answers with the key, as it would for
        // any missing string.
        #expect(L10n.Onboarding.welcome == "welcome")
        #expect(L10n.Onboarding.skip == "Skip")
    }

    @Test func generatedAccessorsReturnTheOTAStrings() async {
        server.strings["de"]!["greeting"] = "Hallo %@"
        server.strings["de"]!["discount"] = "20% Rabatt"
        server.strings["de"]!["files"] = "%1$@ hat %2$lld Dateien"
        server.strings["de"]!["swapped"] = "%1$@ nach %2$@"
        server.strings["de"]!["welcome"] = "Willkommen!"
        await install(makeClient())
        #expect(L10n.homeTitle == "Startseite")
        #expect(L10n.greeting("Ana") == "Hallo Ana")
        // Shown as written: a plain string is never formatted, so its % needs
        // no escaping and does not have to match the shipped one.
        #expect(L10n.discount == "20% Rabatt")
        #expect(L10n.files("Docs", 3) == "Docs hat 3 Dateien")
        #expect(L10n.swapped("B", "A") == "B nach A")
        // Tables share one set of keys in the dashboard.
        #expect(L10n.Onboarding.welcome == "Willkommen!")
    }

    @Test func aGeneratedFunctionRefusesAnOTAValueWithOtherPlaceholders() async {
        server.strings["de"]!["greeting"] = "Hallo %lld"
        server.strings["de"]!["files"] = "%2$lld Dateien"
        await install(makeClient())
        #expect(L10n.greeting("Ana") == "Hello Ana")
        #expect(L10n.files("Docs", 3) == "Docs has 3 files")
    }

    @Test func pluralRulesSurviveTheSwizzledLookup() async {
        // A plural string carries its rules on the NSString Foundation hands
        // back; the exchanged lookup must pass that object through untouched.
        server.strings["de"]!["items.count"] = "%lld Artikel"
        await install(makeClient(intercept: true))
        #expect(L10n.itemsCount(1) == "1 item")
        #expect(L10n.itemsCount(3) == "3 items")
    }
}
