import Foundation
import Testing
@testable import LocalizeMe

@Suite struct LanguageResolverTests {
    func resolve(_ preferred: [String], _ available: [String: [String]], override: String? = nil) -> String? {
        LanguageResolver.resolve(preferred: preferred, available: available, override: override)
    }

    @Test func exactMatchWinsOverBase() {
        #expect(resolve(["pt-BR"], ["pt": [], "pt-BR": []]) == "pt-BR")
    }

    @Test func fallsBackToBaseLanguage() {
        #expect(resolve(["pt-BR", "en"], ["pt": [], "en": []]) == "pt")
    }

    @Test func nextPreferredLanguageWhenFirstIsUnpublished() {
        #expect(resolve(["fi", "de-DE"], ["en": [], "de": []]) == "de")
    }

    @Test func underscoresAndCaseDoNotMatter() {
        #expect(resolve(["ZH_hant"], ["zh-Hant": []]) == "zh-Hant")
        #expect(resolve(["pt_BR"], ["pt-br": []]) == "pt-br")
    }

    @Test func overrideWins() {
        #expect(resolve(["en"], ["en": [], "lt": []], override: "lt") == "lt")
    }

    @Test func unpublishedOverrideFallsBackToTheDevice() {
        #expect(resolve(["de"], ["de": [], "en": []], override: "fi") == "de")
    }

    @Test func nothingMatches() {
        // Apple's matcher answers "en" here; that is its fallback, not a match.
        #expect(resolve(["fi"], ["en": []]) == nil)
        #expect(resolve(["fi"], ["en": [], "de": []]) == nil)
        #expect(resolve([], ["en": []]) == nil)
        #expect(resolve(["en"], [:]) == nil)
    }

    @Test func alternativeCodesResolveToTheirLanguage() {
        let available = ["no": ["nb", "nb-NO"], "en": []]
        #expect(resolve(["nb-NO", "en"], available) == "no")
        #expect(resolve(["nb", "en"], available) == "no")
        #expect(resolve(["en"], available, override: "nb") == "no")
        // Apple relates nb to no on its own; the codes matter for aliases it
        // does not know, such as a project serving Swiss German speakers German.
        #expect(resolve(["nb-NO", "en"], ["no": [], "en": []]) == "no")
        #expect(resolve(["gsw-CH", "en"], ["de": ["gsw"], "en": []]) == "de")
        #expect(resolve(["gsw-CH", "en"], ["de": [], "en": []]) == "en")
    }

    @Test func subtagsAreDroppedOneAtATime() {
        #expect(resolve(["zh-Hant-TW"], ["zh-Hant": [], "zh": []]) == "zh-Hant")
        #expect(resolve(["zh-Hant-TW"], ["zh": []]) == "zh")
        #expect(resolve(["zh-TW"], ["zh-Hans": [], "zh-Hant": []]) == "zh-Hant")
        // Another script of the same language is not a match.
        #expect(resolve(["zh-Hant"], ["zh-Hans": []]) == nil)
    }

    @Test func theRenderedLocalizationLeadsTheDeviceList() {
        // A Swiss device prefers German, but the binary only renders French.
        #expect(resolve(["fr", "de-CH", "fr-CH"], ["de": [], "fr": []]) == "fr")
        #expect(resolve(["de-CH", "fr-CH"], ["de": [], "fr": []]) == "de")
    }
}

@Suite struct FormatSpecifiersTests {
    @Test func readsPositionsAndKinds() {
        #expect(FormatSpecifiers.signature("Hallo %lld") == [1: "i"])
        #expect(FormatSpecifiers.signature("%@ has %d items (%.1f%%)") == [1: "@", 2: "i", 3: "f"])
        #expect(FormatSpecifiers.signature("%2$@ %1$@") == [1: "@", 2: "@"])
        #expect(FormatSpecifiers.signature("%*d") == [1: "i", 2: "i"])
        #expect(FormatSpecifiers.signature("%.*f") == [1: "i", 2: "f"])
        #expect(FormatSpecifiers.signature("%1$*2$d") == [1: "i", 2: "i"])
        #expect(FormatSpecifiers.signature("%#@count@ left") == [1: "#@"])
        #expect(FormatSpecifiers.signature("%'d %-5s %+.3e %#x %zu %C %S %p") == [
            1: "i", 2: "s", 3: "f", 4: "i", 5: "i", 6: "c", 7: "s", 8: "p",
        ])
        #expect(FormatSpecifiers.signature("plain") == [:])
        #expect(FormatSpecifiers.signature("100%%") == [:])
        #expect(FormatSpecifiers.signature("") == [:])
    }

    @Test func refusesWhatItCannotRead() {
        #expect(FormatSpecifiers.signature("%n") == nil)
        #expect(FormatSpecifiers.signature("%y") == nil)
        // A % that ends the string is text, not a placeholder.
        #expect(FormatSpecifiers.signature("100%") == [:])
        #expect(FormatSpecifiers.signature("%#@count") == nil)
        // One slot, two kinds.
        #expect(FormatSpecifiers.signature("%1$d %1$@") == nil)
    }

    @Test func compatibility() {
        // Reordering positional arguments is fine.
        #expect(FormatSpecifiers.compatible("%2$@ hat %1$d", "%d items for %@"))
        // Reordering unpositioned ones is not.
        #expect(!FormatSpecifiers.compatible("%@ hat %d", "%d items for %@"))
        // Length modifiers do not matter.
        #expect(FormatSpecifiers.compatible("%ld Dinge", "%d things"))
        #expect(!FormatSpecifiers.compatible("%@", "bad %lld"))
        #expect(!FormatSpecifiers.compatible("Hallo", "Hallo %@"))
        // A % that ends the string is text on both sides.
        #expect(FormatSpecifiers.compatible("Sparen Sie 20%", "Save 20%"))
        #expect(!FormatSpecifiers.compatible("%d%", "Save 20%"))
        #expect(!FormatSpecifiers.compatible("Hallo %@", "Hallo"))
        #expect(!FormatSpecifiers.compatible("%n", "%n"))
        #expect(FormatSpecifiers.compatible("Startseite", "Home"))
    }

    @Test func identifierLikeKeys() {
        #expect(FormatSpecifiers.looksLikeIdentifier("home.title"))
        #expect(FormatSpecifiers.looksLikeIdentifier("Settings_Title-2"))
        #expect(FormatSpecifiers.looksLikeIdentifier(String(repeating: "a", count: 128)))
        #expect(!FormatSpecifiers.looksLikeIdentifier(String(repeating: "a", count: 129)))
        #expect(!FormatSpecifiers.looksLikeIdentifier(""))
        #expect(!FormatSpecifiers.looksLikeIdentifier("Hello, world!"))
        #expect(!FormatSpecifiers.looksLikeIdentifier("greeting %lld"))
        #expect(!FormatSpecifiers.looksLikeIdentifier("Straße"))
    }
}

@Suite final class StoreTests {
    let store: Store

    init() {
        store = Store(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    deinit {
        store.wipe()
    }

    @Test func snapshotRoundTrip() throws {
        #expect(store.loadSnapshot(named: "current") == nil)
        let snapshot = Snapshot(version: 7, sourceLanguage: "en", bundles: ["de": "abc"], codes: ["de": ["de-DE"]])
        try store.saveSnapshot(snapshot, named: "current")
        #expect(store.loadSnapshot(named: "current") == snapshot)
        // Overwriting goes through the replace path.
        try store.saveSnapshot(Snapshot(version: 8, sourceLanguage: nil, bundles: [:], codes: [:]), named: "current")
        #expect(store.loadSnapshot(named: "current")?.version == 8)
        store.removeSnapshot(named: "current")
        #expect(store.loadSnapshot(named: "current") == nil)
    }

    @Test func manifestRoundTrip() throws {
        #expect(store.loadManifest() == nil)
        let json = """
        {"version": 3, "platform": "ios", "source_language": "en", "languages": {
          "no": {"url": "https://api.test/b/no.json", "sha256": "abc", "size": 10, "strings": 1, "codes": ["nb", "nb-NO"]},
          "en": {"url": "https://api.test/b/en.json", "sha256": "def", "size": 10, "strings": 1}
        }}
        """
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        #expect(manifest.languages["no"]?.codes == ["nb", "nb-NO"])
        #expect(manifest.languages["en"]?.codes == nil)
        #expect(manifest.codesByLanguage == ["no": ["nb", "nb-NO"], "en": []])
        try store.saveManifest(manifest)
        #expect(store.loadManifest() == manifest)
    }

    @Test func bundlesArePrunedByHash() throws {
        let body = #"{"v":1,"project":1,"platform":"ios","lang":"de","strings":{"a":"b"}}"#.data(using: .utf8)!
        try store.saveBundle(body, sha256: "keep")
        try store.saveBundle(body, sha256: "drop")
        #expect(store.loadBundle(sha256: "keep")?.strings == ["a": "b"])
        store.pruneBundles(keeping: ["keep"])
        #expect(store.hasBundle(sha256: "keep"))
        #expect(!store.hasBundle(sha256: "drop"))
    }

    @Test func etagRoundTrip() {
        #expect(store.manifestETag == nil)
        store.saveManifestETag("\"abc\"")
        #expect(store.manifestETag == "\"abc\"")
        store.saveManifestETag(nil)
        #expect(store.manifestETag == nil)
    }
}

@Suite struct ReporterTests {
    @Test func errorsAreDeduplicatedByTypePerLaunch() {
        let reporter = Reporter()
        reporter.recordError(LocalizeMeError(kind: .network, message: "one"))
        reporter.recordError(LocalizeMeError(kind: .network, message: "two"))
        reporter.recordError(LocalizeMeError(kind: .storage, message: "three"))
        let (errors, _) = reporter.drain()
        #expect(errors.map { $0["type"] } == ["network", "storage"])
        #expect(reporter.isEmpty)
    }

    @Test func formatMismatchesAreDeduplicatedPerKey() {
        let reporter = Reporter()
        reporter.recordError(LocalizeMeError(kind: .formatMismatch, message: "a %d"))
        reporter.recordError(LocalizeMeError(kind: .formatMismatch, message: "a %d"))
        reporter.recordError(LocalizeMeError(kind: .formatMismatch, message: "b %@"))
        let (errors, _) = reporter.drain()
        #expect(errors.map { $0["message"] } == ["a %d", "b %@"])
    }

    @Test func missingKeysAreDeduplicatedAndCapped() {
        let reporter = Reporter()
        reporter.recordMissingKey("a", language: "de")
        reporter.recordMissingKey("a", language: "de")
        reporter.recordMissingKey("a", language: "en")
        for i in 0..<500 { reporter.recordMissingKey("k\(i)", language: nil) }
        let (_, missing) = reporter.drain()
        #expect(missing.count == Reporter.maxMissingKeysPerLaunch)
        #expect(missing.filter { $0["key"] == "a" }.count == 2)
    }

    @Test func restorePutsFailedReportsBack() {
        let reporter = Reporter()
        reporter.recordError(LocalizeMeError(kind: .network, message: "x"))
        let (errors, missing) = reporter.drain()
        #expect(reporter.isEmpty)
        reporter.restore(errors: errors, missingKeys: missing)
        #expect(!reporter.isEmpty)
    }
}

@Suite struct HashingTests {
    @Test func sha256() {
        #expect(
            Hashing.sha256Hex("abc".data(using: .utf8)!)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
