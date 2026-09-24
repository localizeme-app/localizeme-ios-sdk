import Foundation
import Testing
@testable import LocalizeMe
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

/// The interception surface. Part of `ClientTests` because the swizzle and the
/// facade are process-wide, so these must not run alongside the other tests.
extension ClientTests {
    @Test func plainLookupsReturnTheOTAValue() async {
        await install(makeClient(intercept: true))
        #expect(NSLocalizedString("greeting %lld", comment: "") == "Hallo %lld")
        #expect(Bundle.main.localizedString(forKey: "greeting %lld", value: nil, table: nil) == "Hallo %lld")
        #expect(String(format: NSLocalizedString("greeting %lld", comment: ""), 7) == "Hallo 7")
        // A default value does not stand in the way of an OTA hit.
        #expect(NSLocalizedString("home.title", value: "Home", comment: "") == "Startseite")
    }

    @Test func attributedLookupsReturnTheOTAValueParsedAsMarkdown() async throws {
        await install(makeClient(intercept: true))
        let plain = AttributedString(Bundle.main.__localizedAttributedString(forKey: "home.title", value: nil, table: nil))
        #expect(String(plain.characters) == "Startseite")
        #expect(plain.runs.first?.languageIdentifier == "de")

        let markdown = AttributedString(Bundle.main.__localizedAttributedString(forKey: "md", value: nil, table: nil))
        #expect(String(markdown.characters) == "Startseite")
        let bold = try #require(markdown.runs.first)
        #expect(String(markdown.characters[bold.range]) == "Start")
        #expect(bold.inlinePresentationIntent == .stronglyEmphasized)
        #expect(markdown.runs.count == 2)
        // The shipped attributed string is still reachable and untouched.
        #expect(Swizzle.shippedAttributedString(bundle: .main, key: "md", value: nil, table: nil).string == "md")
    }

    @Test func aPlaceholderMismatchFallsBackToTheShippedStringOnEveryPath() async {
        let client = makeClient(intercept: true)
        await install(client)
        #expect(NSLocalizedString("bad %lld", comment: "") == "bad %lld")
        #expect(Bundle.main.__localizedAttributedString(forKey: "bad %lld", value: nil, table: nil).string == "bad %lld")
        #expect(LocalizeMe.localizedString(forKey: "bad %lld") == "bad %lld")
        #expect(LocalizeMe.localizedString(forKey: "bad %lld", arguments: 7) == "bad 7")
        #expect(LocalizeMe.string("bad %lld", fallback: "bad %lld") == "bad %lld")
        // The raw value is still there for apps that know what they are doing.
        #expect(LocalizeMe.string("bad %lld") == "%@")
        // Reported once for the key, however often it was asked for.
        let (errors, _) = client.reporter.drain()
        #expect(errors == [["type": "format_mismatch", "message": "bad %lld"]])
    }

    @Test func theHelpersAnswerWhereTheSwizzleCannotReach() async {
        await install(makeClient(intercept: true))
        #expect(LocalizeMe.localizedString(forKey: "home.title") == "Startseite")
        #expect(LocalizeMe.localizedString(forKey: "nobody.has.this") == "nobody.has.this")
        #expect(LocalizeMe.localizedString(forKey: "greeting %lld", arguments: 7) == "Hallo 7")
        #if canImport(SwiftUI)
        #expect(LocalizeMe.text("home.title") == Text(verbatim: "Startseite"))
        // Verbatim: no Markdown.
        #expect(LocalizeMe.text("md") == Text(verbatim: "**Start**seite"))
        #endif
    }

    @Test func interceptionOffLeavesBundleAloneButNotTheHelpers() async {
        await install(makeClient(intercept: false))
        #expect(NSLocalizedString("home.title", comment: "") == "home.title")
        #expect(Bundle.main.__localizedAttributedString(forKey: "home.title", value: nil, table: nil).string == "home.title")
        #expect(LocalizeMe.localizedString(forKey: "home.title") == "Startseite")
        #expect(LocalizeMe.string("home.title") == "Startseite")
    }

    @Test func missingKeysAreReportedOnlyWhenTheyLookLikeKeys() async {
        let client = makeClient(intercept: true, reportMissingKeys: true)
        await install(client)
        #expect(NSLocalizedString("nobody.has.this", comment: "") == "nobody.has.this")
        #expect(Bundle.main.__localizedAttributedString(forKey: "also.missing", value: nil, table: nil).string == "also.missing")
        // A sentence is a view's own text, not a key.
        #expect(NSLocalizedString("Hello, world!", comment: "") == "Hello, world!")
        // A default value means the key is not missing.
        #expect(NSLocalizedString("settings.title", value: "Settings", comment: "") == "Settings")
        // Other bundles are not the app's strings.
        #expect(Bundle(for: ClientTests.self).localizedString(forKey: "other.bundle", value: nil, table: nil) == "other.bundle")
        let (_, missing) = client.reporter.drain()
        #expect(missing.compactMap { $0["key"] }.sorted() == ["also.missing", "nobody.has.this"])
        #expect(missing.allSatisfy { $0["language"] == "de" })
    }

    @Test func nothingIsReportedMissingWithoutALiveLanguage() async {
        let client = makeClient(languages: ["fi"], intercept: true, reportMissingKeys: true)
        await install(client)
        #expect(client.language == nil)
        #expect(NSLocalizedString("nobody.has.this", comment: "") == "nobody.has.this")
        #expect(client.reporter.isEmpty)
    }
}

#if canImport(SwiftUI) && os(macOS)
extension ClientTests {
    /// The proof that SwiftUI's own lookups reach the swizzle. AppKit needs a
    /// window server, so this runs only with `LOCALIZEME_UI_TESTS=1 ./test.sh`.
    /// Rendered widths stand in for the text: `Text` never exposes its string.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALIZEME_UI_TESTS"] == "1"))
    @MainActor func swiftUIViewsShowTheOTAValue() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        await install(makeClient(intercept: true))

        func width<V: View>(_ view: V) -> CGFloat {
            let host = NSHostingView(rootView: view.fixedSize())
            host.frame = NSRect(x: 0, y: 0, width: 4000, height: 200)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        func same<A: View, B: View>(_ a: A, _ b: B) -> Bool {
            abs(width(a) - width(b)) < 0.5
        }

        // The references must be told apart for the comparisons to mean anything.
        #expect(!same(Text(verbatim: "Startseite"), Text(verbatim: "home.title")))
        #expect(!same(Text(verbatim: "Hallo 7"), Text(verbatim: "greeting 7")))

        #expect(same(Text("home.title"), Text(verbatim: "Startseite")))
        #expect(same(Text("greeting \(7)"), Text(verbatim: "Hallo 7")))
        #expect(same(Button("home.title") {}, Button(action: {}) { Text(verbatim: "Startseite") }))
        #expect(same(Label("home.title", systemImage: "house"), Label { Text(verbatim: "Startseite") } icon: { Image(systemName: "house") }))
        // Placeholders that do not match: the shipped text, formatted by SwiftUI.
        #expect(same(Text("bad \(7)"), Text(verbatim: "bad 7")))
        // Markdown is parsed like Foundation parses a shipped string.
        #expect(same(Text("md"), Text("**Start**seite")))
        #expect(!same(Text("md"), Text(verbatim: "Startseite")))
        // An explicit locale takes a private entry point and keeps the shipped text.
        #expect(same(Text("home.title").environment(\.locale, Locale(identifier: "de")), Text(verbatim: "home.title")))
        // The helper works everywhere.
        #expect(same(LocalizeMe.text("home.title"), Text(verbatim: "Startseite")))
    }
}
#endif
