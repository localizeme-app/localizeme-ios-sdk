import Foundation
import Testing
@testable import LocalizeMe

/// A fake LocalizeMe API: one manifest version at a time, with real hashes.
final class FakeServer {
    var version = 1
    var strings: [String: [String: String]] = [
        "en": ["home.title": "Home", "greeting %lld": "Hello %lld"],
        "de": ["home.title": "Startseite", "greeting %lld": "Hallo %lld", "bad %lld": "%@", "md": "**Start**seite"],
    ]
    /// The other codes a language answers to, sent as the manifest's `codes`.
    var codes: [String: [String]] = [:]
    var reports: [[String: Any]] = []
    var unauthorized = false
    var corruptBundles = false
    var manifestRequests = 0
    var bundleRequests = 0
    private let lock = NSLock()

    func bundleData(_ lang: String) -> Data {
        let payload: [String: Any] = ["v": 1, "project": 1, "platform": "ios", "lang": lang, "strings": strings[lang] ?? [:]]
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    var etag: String { "\"p1-ios-r\(version)\"" }

    func handle(_ request: URLRequest) -> MockURLProtocol.Response {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        if unauthorized {
            return .init(status: 401, body: #"{"success":false,"message":"Invalid SDK key"}"#.data(using: .utf8)!)
        }
        if path.hasSuffix("/ota/v1/manifest") {
            manifestRequests += 1
            if request.value(forHTTPHeaderField: "If-None-Match") == etag {
                return .init(status: 304, headers: ["ETag": etag])
            }
            var languages: [String: Any] = [:]
            for lang in strings.keys {
                let data = bundleData(lang)
                var entry: [String: Any] = [
                    "url": "https://api.test/ota/v1/bundles/1/ios/\(lang)/\(Hashing.sha256Hex(data)).json",
                    "sha256": Hashing.sha256Hex(data),
                    "size": data.count,
                    "strings": strings[lang]!.count,
                ]
                if let codes = codes[lang] { entry["codes"] = codes }
                languages[lang] = entry
            }
            let body: [String: Any] = ["success": true, "message": "ok", "data": [
                "version": version, "platform": "ios", "source_language": "en", "languages": languages,
            ]]
            return .init(status: 200, headers: ["ETag": etag], body: try! JSONSerialization.data(withJSONObject: body))
        }
        if path.contains("/ota/v1/bundles/") {
            bundleRequests += 1
            let lang = path.split(separator: "/")[5]
            var data = bundleData(String(lang))
            if corruptBundles { data.append(0x20) }
            return .init(status: 200, body: data)
        }
        if path.hasSuffix("/ota/v1/report") {
            if let body = request.bodyData, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                reports.append(json)
            }
            return .init(status: 200, body: #"{"success":true,"data":{}}"#.data(using: .utf8)!)
        }
        return .init(status: 404)
    }
}

/// A thread-safe tally for callbacks that arrive on other queues.
final class Counter {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Serialized: the mock network, the facade and the swizzle are process-wide.
@Suite(.serialized) final class ClientTests {
    let server = FakeServer()
    let root: URL
    let run = UUID().uuidString

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let server = self.server
        MockURLProtocol.setHandler({ server.handle($0) }, for: run)
        LocalizeMe.reset()
        LocalizeMe.onUpdate = nil
    }

    deinit {
        MockURLProtocol.retire(run)
        try? FileManager.default.removeItem(at: root)
        LocalizeMe.reset()
    }

    var requests: [URLRequest] { MockURLProtocol.requests(for: run) }

    func makeClient(
        applyImmediately: Bool = false, languages: [String] = ["de-DE"], intercept: Bool = false, reportMissingKeys: Bool = false
    ) -> Client {
        var configuration = LocalizeMeConfiguration(sdkKey: "lzs_test_key_1234")
        configuration.baseURL = URL(string: "https://api.test")!
        configuration.applyImmediately = applyImmediately
        configuration.interceptBundleLookups = intercept
        configuration.reportMissingKeys = reportMissingKeys
        configuration.checkOnForeground = false
        let client = Client(
            configuration: configuration, session: MockURLProtocol.session(for: run),
            store: Store(root: root), installID: "install-1"
        )
        client.preferredLanguages = { languages }
        return client
    }

    func check(_ client: Client, force: Bool = true) async -> Result<LocalizeMeCheckOutcome, LocalizeMeError> {
        await withCheckedContinuation { continuation in
            client.check(force: force) { continuation.resume(returning: $0) }
        }
    }

    @discardableResult
    func start(_ client: Client) async -> Result<LocalizeMeCheckOutcome, LocalizeMeError> {
        client.start()
        return await check(client)
    }

    /// Makes `client` the one the facade and the swizzled lookups use.
    @discardableResult
    func install(_ client: Client) async -> Result<LocalizeMeCheckOutcome, LocalizeMeError> {
        LocalizeMe.install(client)
        return await check(client)
    }

    func settle() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func firstRunDownloadsTheDeviceLanguageAndAppliesIt() async throws {
        let client = makeClient()
        let outcome = await start(client)
        #expect(try outcome.get() == .applied(version: 1))
        #expect(client.string(forKey: "home.title") == "Startseite")
        #expect(client.language == "de")
        #expect(client.version == 1)
        // The device language and nothing else: the source language is never
        // looked up, so it is not downloaded.
        #expect(server.bundleRequests == 1)

        let manifest = try #require(requests.first { $0.url!.path.hasSuffix("/manifest") })
        #expect(manifest.value(forHTTPHeaderField: "Authorization") == "Bearer lzs_test_key_1234")
        #expect(manifest.value(forHTTPHeaderField: "X-LocalizeMe-Install") == "install-1")
        #expect(manifest.value(forHTTPHeaderField: "X-LocalizeMe-SDK") == API.sdkVersion)
        #expect(manifest.url!.query == "platform=ios")
    }

    @Test func secondCheckIsConditionalAndUpToDate() async throws {
        let client = makeClient()
        await start(client)
        let outcome = await check(client)
        #expect(try outcome.get() == .upToDate)
        let last = try #require(requests.last { $0.url!.path.hasSuffix("/manifest") })
        #expect(last.value(forHTTPHeaderField: "If-None-Match") == server.etag)
        #expect(server.bundleRequests == 1)
    }

    @Test func aNewVersionIsStagedUntilAppliedOrNextLaunch() async throws {
        let client = makeClient()
        await start(client)

        server.version = 2
        server.strings["de"] = ["home.title": "Start"]
        let updatedVersion: Int = await withCheckedContinuation { continuation in
            client.onUpdate = { continuation.resume(returning: $0) }
            client.check(force: true) { _ in }
        }
        #expect(updatedVersion == 2)
        // Still showing the old strings.
        #expect(client.string(forKey: "home.title") == "Startseite")
        #expect(client.hasStagedUpdate)

        // Applying is synchronous, so the new strings are live on return, and
        // it is the app's own doing, so onUpdate stays quiet.
        let lateUpdates = Counter()
        client.onUpdate = { _ in lateUpdates.increment() }
        #expect(client.applyNow())
        #expect(client.string(forKey: "home.title") == "Start")
        #expect(client.version == 2)
        #expect(!client.hasStagedUpdate)
        #expect(!client.applyNow())
        // Safe to call from the SDK's own queue too.
        client.queue.sync { #expect(!client.applyNow()) }
        await settle()
        #expect(lateUpdates.value == 0)
    }

    @Test func aStagedVersionIsPromotedOnTheNextLaunch() async throws {
        let first = makeClient()
        await start(first)
        server.version = 2
        server.strings["de"] = ["home.title": "Start"]
        #expect(try await check(first).get() == .staged(version: 2))
        #expect(first.string(forKey: "home.title") == "Startseite")

        // "Next launch": a fresh client over the same cache directory.
        let second = makeClient()
        #expect(second.staged?.version == 2)
        second.start()
        #expect(second.string(forKey: "home.title") == "Start")
        #expect(second.version == 2)
        #expect(second.staged == nil)
        _ = await check(second)
    }

    @Test func aStagedVersionGainsALanguageWithoutBeingStagedAgain() async throws {
        server.strings["fr"] = ["home.title": "Accueil"]
        let client = makeClient()
        await start(client)
        server.version = 2
        server.strings["de"] = ["home.title": "Start"]
        #expect(try await check(client).get() == .staged(version: 2))
        let downloads = server.bundleRequests
        let updates = Counter()
        client.onUpdate = { _ in updates.increment() }

        // French is not published in the version on screen, so the device's
        // German stays live; the staged version gets French.
        client.setLanguage("fr")
        #expect(try await check(client).get() == .staged(version: 2))
        #expect(client.string(forKey: "home.title") == "Startseite")
        #expect(server.bundleRequests == downloads + 1)
        #expect(client.staged?.bundles.keys.sorted() == ["de", "fr"])

        // Checking again neither downloads nor stages anything.
        #expect(try await check(client).get() == .upToDate)
        #expect(server.bundleRequests == downloads + 1)
        await settle()
        #expect(updates.value == 1)

        #expect(client.applyNow())
        #expect(client.language == "fr")
        #expect(client.string(forKey: "home.title") == "Accueil")
    }

    @Test func applyImmediatelySwapsInPlace() async throws {
        let client = makeClient(applyImmediately: true)
        await start(client)
        server.version = 2
        server.strings["de"] = ["home.title": "Sofort"]
        #expect(try await check(client).get() == .applied(version: 2))
        #expect(client.string(forKey: "home.title") == "Sofort")
    }

    @Test func cachedStringsSurviveAnOfflineLaunch() async {
        await start(makeClient())
        MockURLProtocol.setHandler(nil, for: run)  // the network is gone
        let offline = makeClient()
        let outcome = await start(offline)
        #expect(offline.string(forKey: "home.title") == "Startseite")
        if case .failure(let error) = outcome {
            #expect(error.kind == .network)
        } else {
            Issue.record("expected a network failure")
        }
    }

    @Test func aRelaunchInAnotherLanguageFillsItFromThePersistedManifest() async throws {
        await start(makeClient(languages: ["en"]))
        #expect(server.bundleRequests == 1)

        // The user switched the device to German. The manifest is unchanged,
        // so the server answers 304; the copy on disk says where German is.
        let relaunched = makeClient(languages: ["de-DE"])
        #expect(relaunched.manifest == nil)
        #expect(try await start(relaunched).get() == .applied(version: 1))
        #expect(relaunched.language == "de")
        #expect(relaunched.string(forKey: "home.title") == "Startseite")
        #expect(server.manifestRequests == 2)
        #expect(server.bundleRequests == 2)
        let last = try #require(requests.last { $0.url!.path.hasSuffix("/manifest") })
        #expect(last.value(forHTTPHeaderField: "If-None-Match") == server.etag)
    }

    @Test func alternativeCodesInTheManifestPickTheLanguage() async {
        server.strings["no"] = ["home.title": "Hjem"]
        server.codes["no"] = ["nb", "nb-NO"]
        let client = makeClient(languages: ["nb-NO", "en"])
        await start(client)
        #expect(client.language == "no")
        #expect(client.string(forKey: "home.title") == "Hjem")

        // The codes travel with the snapshot, so a relaunch resolves offline too.
        MockURLProtocol.setHandler(nil, for: run)
        let relaunched = makeClient(languages: ["nb-NO", "en"])
        relaunched.start()
        #expect(relaunched.language == "no")
        #expect(relaunched.string(forKey: "home.title") == "Hjem")
        _ = await check(relaunched)
    }

    @Test func aCorruptCacheIsWipedAndStartsOverFromVersionZero() async throws {
        let client = makeClient()
        await start(client)
        server.version = 2
        server.strings["de"] = ["home.title": "Start"]
        #expect(try await check(client).get() == .staged(version: 2))

        // The live bundle's file is damaged behind the SDK's back, and the
        // network is gone so nothing is fetched again yet.
        let sha = try #require(client.current.bundles["de"])
        try Data("nope".utf8).write(to: client.store.bundleURL(sha256: sha))
        MockURLProtocol.setHandler(nil, for: run)
        client.setLanguage(nil)  // re-reads the live strings
        _ = await check(client)
        #expect(client.version == 0)
        #expect(client.string(forKey: "home.title") == nil)
        #expect(client.staged == nil)
        #expect(!client.hasStagedUpdate)
        #expect(client.store.loadSnapshot(named: "current") == nil)
        #expect(client.store.manifestETag == nil)

        // Back online, the next check starts from scratch and applies at once.
        let server = self.server
        MockURLProtocol.setHandler({ server.handle($0) }, for: run)
        #expect(try await check(client).get() == .applied(version: 2))
        #expect(client.string(forKey: "home.title") == "Start")
    }

    @Test func theDefaultPreferenceStartsWithWhatTheAppRenders() {
        var configuration = LocalizeMeConfiguration(sdkKey: "lzs_test_key_1234")
        configuration.baseURL = URL(string: "https://api.test")!
        let client = Client(
            configuration: configuration, session: MockURLProtocol.session(for: run),
            store: Store(root: root), installID: "install-1"
        )
        #expect(client.preferredLanguages() == Bundle.main.preferredLocalizations + Locale.preferredLanguages)
    }

    @Test func aHashMismatchIsRejectedAndReported() async {
        server.corruptBundles = true
        let client = makeClient()
        let outcome = await start(client)
        if case .failure(let error) = outcome {
            #expect(error.kind == .hashMismatch)
        } else {
            Issue.record("expected a hash failure")
        }
        #expect(client.string(forKey: "home.title") == nil)
        await settle()
        let types = server.reports.compactMap { ($0["errors"] as? [[String: String]])?.map { $0["type"] } }
        #expect(types.first == ["hash_mismatch"])
    }

    @Test func aRevokedKeyKeepsTheCacheAndStopsChecking() async {
        let client = makeClient()
        await start(client)
        server.unauthorized = true
        if case .failure(let error) = await check(client) {
            #expect(error.kind == .unauthorized)
        } else {
            Issue.record("expected unauthorized")
        }
        #expect(client.string(forKey: "home.title") == "Startseite")
        let before = server.manifestRequests
        let outcome = await check(client, force: false)
        #expect((try? outcome.get()) == .throttled)
        #expect(server.manifestRequests == before)
    }

    @Test func changingLanguageDownloadsTheNewOne() async {
        let client = makeClient(languages: ["en"])
        await start(client)
        #expect(client.string(forKey: "home.title") == "Home")
        #expect(server.bundleRequests == 1)

        client.setLanguage("de")
        _ = await check(client)
        #expect(server.bundleRequests == 2)
        #expect(client.string(forKey: "home.title") == "Startseite")
        #expect(client.language == "de")
    }

    @Test func missingKeysAreReportedWithTheNextCheck() async {
        let client = makeClient()
        await start(client)
        client.reporter.recordMissingKey("settings.title", language: "de")
        _ = await check(client)
        await settle()
        let keys = server.reports.compactMap { ($0["missing_keys"] as? [[String: String]])?.map { $0["key"] } }
        #expect(keys.first == ["settings.title"])
    }

    @Test func publicFacadeAnswersBeforeAndAfterStart() async {
        #expect(LocalizeMe.string("home.title") == nil)
        #expect(LocalizeMe.string("home.title", fallback: "x") == "x")
        #expect(LocalizeMe.localizedString(forKey: "home.title") == "home.title")
        #expect(LocalizeMe.version == 0)
        #expect(!LocalizeMe.applyNow())
        #expect(!LocalizeMe.hasStagedUpdate)
        let notStarted: Result<LocalizeMeCheckOutcome, LocalizeMeError> = await withCheckedContinuation { continuation in
            LocalizeMe.check { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = notStarted { #expect(error.kind == .notStarted) } else { Issue.record("expected not started") }

        LocalizeMe.onUpdate = { _ in }
        let client = makeClient()
        LocalizeMe.install(client)
        #expect(client.onUpdate != nil)
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Result<LocalizeMeCheckOutcome, LocalizeMeError>, Never>) in
            LocalizeMe.check { continuation.resume(returning: $0) }
        }
        #expect(LocalizeMe.string("home.title") == "Startseite")
        #expect(LocalizeMe.string("home.title", fallback: "Home") == "Startseite")
        #expect(LocalizeMe.localizedString(forKey: "home.title") == "Startseite")
        #expect(LocalizeMe.language == "de")
        #expect(LocalizeMe.version == 1)
        LocalizeMe.onUpdate = nil
        #expect(client.onUpdate == nil)
    }

    @Test func bundleLookupsGoThroughTheOTAStrings() async {
        let client = makeClient(intercept: true)
        await install(client)
        #expect(Bundle.main.localizedString(forKey: "home.title", value: nil, table: nil) == "Startseite")
        #expect(NSLocalizedString("home.title", comment: "") == "Startseite")
        // A key nobody has falls through to the shipped behaviour. Reporting
        // it is off by default.
        #expect(NSLocalizedString("nobody.has.this", comment: "") == "nobody.has.this")
        #expect(client.reporter.isEmpty)
        // Other bundles are left alone.
        #expect(Bundle(for: ClientTests.self).localizedString(forKey: "home.title", value: nil, table: nil) == "home.title")
    }

    /// Run under `./test.sh --sanitize=thread`: lookups on one thread while the
    /// SDK is started again and again on another must never touch the same
    /// memory unguarded.
    @Test func restartingWhileLookupsRunIsSafe() async {
        let hammer = Task.detached {
            var lookups = 0
            while !Task.isCancelled {
                _ = NSLocalizedString("home.title", comment: "")
                _ = Bundle.main.localizedString(forKey: "greeting %lld", value: nil, table: nil)
                _ = Bundle.main.__localizedAttributedString(forKey: "md", value: nil, table: nil)
                _ = LocalizeMe.localizedString(forKey: "bad %lld")
                _ = LocalizeMe.language
                lookups += 1
            }
            return lookups
        }
        for _ in 0..<5 {
            await install(makeClient(intercept: true))
        }
        hammer.cancel()
        let lookups = await hammer.value
        #expect(lookups > 0)
        #expect(NSLocalizedString("home.title", comment: "") == "Startseite")
    }
}
