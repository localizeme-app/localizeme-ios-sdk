import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The SDK's state: which strings are live, what is staged, and when to check.
///
/// One instance per `start()`. All state changes happen on `queue`; string
/// lookups read an immutable dictionary under a lock, so they never wait on
/// a download.
final class Client {
    let configuration: LocalizeMeConfiguration
    let store: Store
    let api: API
    let reporter = Reporter()
    let queue = DispatchQueue(label: "app.localizeme.sdk")
    /// The bundle whose lookups the SDK answers: the app's own.
    let appBundle: Bundle
    /// Where the OTA plural tables are written.
    let pluralRoot: URL
    private static let queueKey = DispatchSpecificKey<Bool>()

    private let lock = NSLock()
    private var live: [String: String] = [:]
    private var liveLanguage: String?
    private var liveVersion = 0
    /// The live strings' plurals, as a bundle Foundation applies rules from.
    private var plurals: PluralTables?
    /// Bumped whenever `live` changes, so a format verdict computed against
    /// the old strings is not cached against the new ones.
    private var liveGeneration = 0
    /// `table\0key` → whether the OTA value may replace the shipped string.
    private var safe: [String: Bool] = [:]
    private var onUpdateHandler: ((Int) -> Void)?
    private var consentLevel: LocalizeMeConsent
    /// Set once `start()` has done its work off the queue; until then a
    /// consent change leaves the first check to `start()`.
    private var started = false
    private let defaults: UserDefaults

    private(set) var current: Snapshot
    private(set) var staged: Snapshot?
    private(set) var manifest: Manifest?
    private var lastCheck: Date?
    private var checking = false
    private var pendingCompletions: [(Result<LocalizeMeCheckOutcome, LocalizeMeError>) -> Void] = []
    private var foregroundObserver: Any?
    private var languageOverride: String??

    /// Called on the main queue when a version arrives. Set from any thread.
    var onUpdate: ((Int) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return onUpdateHandler }
        set { lock.lock(); onUpdateHandler = newValue; lock.unlock() }
    }

    /// The languages to match, most preferred first: the localization the app
    /// is rendering, then the device's own list.
    var preferredLanguages: () -> [String] = { Bundle.main.preferredLocalizations + Locale.preferredLanguages }

    init(
        configuration: LocalizeMeConfiguration, session: URLSession = Client.defaultSession(), store: Store? = nil,
        installID: String? = nil, defaults: UserDefaults = .standard, appBundle: Bundle = .main
    ) {
        self.configuration = configuration
        let prefix = String(configuration.sdkKey.prefix(10))
        self.appBundle = appBundle
        // Next to an injected store, so it goes with it; else Application
        // Support, which the system does not purge under a running app.
        self.pluralRoot = store.map { $0.root.appendingPathComponent("plurals", isDirectory: true) }
            ?? Client.defaultPluralRoot(keyPrefix: prefix)
        self.store = store ?? Store(root: Store.defaultRoot(keyPrefix: prefix))
        self.defaults = defaults
        self.api = API(configuration: configuration, session: session) {
            installID ?? InstallID.current(defaults: defaults)
        }
        self.consentLevel = configuration.consent
        self.current = self.store.loadSnapshot(named: "current") ?? .empty
        self.staged = self.store.loadSnapshot(named: "staged")
        queue.setSpecific(key: Client.queueKey, value: true)
        if configuration.consent < .full {
            reporter.setEnabled(false)
            // An id from an earlier launch with full consent goes, on the
            // queue rather than the launching thread, and before any request.
            queue.async { InstallID.remove(defaults: defaults) }
        }
    }

    private static func defaultPluralRoot(keyPrefix: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("LocalizeMe", isDirectory: true)
            .appendingPathComponent(keyPrefix, isDirectory: true)
            .appendingPathComponent("plurals", isDirectory: true)
    }

    /// No URL cache: every answer is a 304 or content the SDK stores itself.
    private static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    // MARK: Lifecycle

    func start() {
        // A staged snapshot is what "next launch" means: promote it now. If it
        // cannot be saved it stays staged and the old strings stay live.
        if let staged {
            do {
                try promote(staged, clearStaged: true)
            } catch {
                reporter.recordError(LocalizeMeError(kind: .storage, message: "\(error)"))
                log("could not promote version \(staged.version): \(error)")
                loadLiveStrings()
            }
        } else {
            loadLiveStrings()
        }

        if configuration.interceptBundleLookups, !Swizzle.install() {
            reporter.recordError(LocalizeMeError(kind: .storage, message: "swizzle_failed"))
            log("could not intercept Bundle lookups; use LocalizeMe.localizedString(forKey:)")
        }

        lock.lock()
        started = true
        lock.unlock()

        #if canImport(UIKit) && !os(watchOS)
        if configuration.checkOnForeground {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.check(force: false, completion: nil)
            }
        }
        #endif

        check(force: true, completion: nil)
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    // MARK: Lookup

    func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return live[key]
    }

    /// The OTA plural for `key`, as the string Foundation formats with its
    /// plural rules, when the live strings have every form it needs.
    func pluralString(forKey key: String, table: String?) -> String? {
        guard let plurals = livePlurals, plurals.serves(key, table: table) else { return nil }
        return Swizzle.shippedString(bundle: plurals.bundle, key: key, value: nil, table: table)
    }

    /// `pluralString(forKey:table:)` for the attributed lookup.
    func pluralAttributedString(forKey key: String, table: String?) -> NSAttributedString? {
        guard let plurals = livePlurals, plurals.serves(key, table: table) else { return nil }
        return Swizzle.shippedAttributedString(bundle: plurals.bundle, key: key, value: nil, table: table)
    }

    /// The OTA plural for a caller that looked `key` up itself and got
    /// `format`, the shipped plural or already the OTA one.
    func pluralString(forKey key: String, format: String) -> String? {
        guard let plurals = livePlurals, let table = plurals.table(forKey: key, format: format) else { return nil }
        return Swizzle.shippedString(bundle: plurals.bundle, key: key, value: nil, table: table)
    }

    private var livePlurals: PluralTables? {
        lock.lock(); defer { lock.unlock() }
        return plurals
    }

    var version: Int {
        lock.lock(); defer { lock.unlock() }
        return liveVersion
    }

    var language: String? {
        lock.lock(); defer { lock.unlock() }
        return liveLanguage
    }

    var consent: LocalizeMeConsent {
        lock.lock(); defer { lock.unlock() }
        return consentLevel
    }

    /// Changes what the SDK may do from the next request on. Going below
    /// `.full` drops buffered reports at once and deletes the install id;
    /// leaving `.off` checks straight away, since checks were skipped. Before
    /// `start()` it only records the level: the check `start()` makes uses it.
    func setConsent(_ level: LocalizeMeConsent) {
        // One critical section, so two calls racing cannot leave the level
        // and what the reporter and requests do disagreeing.
        lock.lock()
        let previous = consentLevel
        consentLevel = level
        reporter.setEnabled(level == .full)
        api.consent = level
        let checkNow = started && previous == .off && level > .off
        lock.unlock()
        queue.async {
            if level < .full {
                // On the queue, where the id is created, so a request being
                // built cannot make it again after this.
                InstallID.remove(defaults: self.defaults)
                self.api.forgetInstallID()
            }
            self.log("consent \(level.rawValue)")
            if checkNow {
                self.check(force: true, completion: nil)
            }
        }
    }

    var hasStagedUpdate: Bool {
        onQueue { staged != nil }
    }

    /// Whether `ota` may stand in for the shipped string of `key`: its
    /// placeholders must take the same arguments, or formatting would read
    /// memory that is not there. Verdicts are cached per key until the live
    /// strings change; a mismatch is reported once per key.
    func isSafe(key: String, table: String?, ota: String) -> Bool {
        let cacheKey = "\(table ?? "")\u{0}\(key)"
        lock.lock()
        let cached = safe[cacheKey]
        let generation = liveGeneration
        lock.unlock()
        if let cached { return cached }

        let shipped = Swizzle.shippedString(bundle: appBundle, key: key, value: nil, table: table)
        let verdict = FormatSpecifiers.compatible(ota, shipped)
        lock.lock()
        if liveGeneration == generation { safe[cacheKey] = verdict }
        lock.unlock()
        if !verdict {
            reporter.recordError(LocalizeMeError(kind: .formatMismatch, message: key))
            log("placeholders of \"\(key)\" differ from the shipped string; showing the shipped one")
        }
        return verdict
    }

    /// A key that neither the OTA strings nor the shipped ones had.
    func noteMissing(_ key: String) {
        guard configuration.reportMissingKeys else { return }
        // Without a live language every key looks missing, and a sentence is
        // a view's own text rather than a key.
        guard let language, FormatSpecifiers.looksLikeIdentifier(key) else { return }
        reporter.recordMissingKey(key, language: language)
    }

    func setLanguage(_ code: String?) {
        queue.async {
            self.languageOverride = .some(code)
            self.loadLiveStrings()
            // The new language may not be on disk yet.
            self.check(force: true, completion: nil)
        }
    }

    private var override: String? {
        languageOverride ?? configuration.language
    }

    /// The language to show from `snapshot`: only one whose bundle is on disk.
    private func resolvedLanguage(in snapshot: Snapshot) -> String? {
        var available: [String: [String]] = [:]
        for code in snapshot.bundles.keys {
            available[code] = snapshot.codes[code] ?? []
        }
        return LanguageResolver.resolve(preferred: preferredLanguages(), available: available, override: override)
    }

    /// Which languages a check should download for this device.
    private func wantedLanguages(from manifest: Manifest) -> [String] {
        switch configuration.languageScope {
        case .all:
            return Array(manifest.languages.keys)
        case .device:
            let chosen = LanguageResolver.resolve(
                preferred: preferredLanguages(), available: manifest.codesByLanguage, override: override
            )
            return chosen.map { [$0] } ?? []
        }
    }

    private func loadLiveStrings() {
        let snapshot = current
        var strings: [String: String] = [:]
        var chosen: String?
        var version = snapshot.version
        if let language = resolvedLanguage(in: snapshot), let sha = snapshot.bundles[language] {
            if let bundle = store.loadBundle(sha256: sha) {
                strings = bundle.strings
                chosen = language
            } else {
                // Unreadable cache: drop all of it and start over from nothing.
                reporter.recordError(LocalizeMeError(kind: .storage, message: "cache_corrupt"))
                store.wipe()
                current = .empty
                staged = nil
                version = 0
            }
        }
        api.language = chosen
        let plurals = chosen.flatMap { language in
            Plurals.build(
                strings: strings, language: language, appBundle: appBundle, root: pluralRoot,
                log: { self.log($0) },
                mismatch: { key in
                    self.reporter.recordError(LocalizeMeError(kind: .formatMismatch, message: key))
                    self.log("placeholders of plural \"\(key)\" differ from the shipped strings; showing the shipped ones")
                }
            )
        }
        lock.lock()
        live = strings
        self.plurals = plurals
        liveLanguage = chosen
        liveVersion = version
        liveGeneration += 1
        safe = [:]
        lock.unlock()
        log("live: \(strings.count) strings, \(plurals?.entries.values.map(\.count).reduce(0, +) ?? 0) plurals, language \(chosen ?? "-"), version \(version)")
    }

    // MARK: Checking

    func check(force: Bool, completion: ((Result<LocalizeMeCheckOutcome, LocalizeMeError>) -> Void)?) {
        queue.async {
            if let completion { self.pendingCompletions.append(completion) }
            if self.checking { return }
            if self.consent == .off {
                self.finish(.failure(LocalizeMeError(kind: .consentOff, message: "consent is off")))
                return
            }
            if !force, let last = self.lastCheck,
               Date().timeIntervalSince(last) < self.configuration.minimumCheckInterval {
                self.finish(.success(.throttled))
                return
            }
            self.checking = true
            self.lastCheck = Date()
            self.api.fetchManifest(etag: self.store.manifestETag) { result in
                self.queue.async { self.handleManifest(result) }
            }
        }
    }

    private func handleManifest(_ result: Result<API.ManifestResult, LocalizeMeError>) {
        if consent == .off {
            // Turned off while the manifest was on its way: download nothing.
            finish(.failure(LocalizeMeError(kind: .consentOff, message: "consent is off")))
            return
        }
        switch result {
        case .failure(let error):
            reporter.recordError(error)
            log("check failed: \(error)")
            if error.kind == .unauthorized {
                // A revoked key: keep what we have and stop asking.
                lastCheck = .distantFuture
            }
            sendReports()
            finish(.failure(error))
        case .success(.notModified):
            log("up to date at version \(current.version)")
            // The manifest may be current while a language is still missing
            // locally: the device language changed, or setLanguage() asked for
            // one. The manifest on disk says where to get it; what is staged
            // counts as had, so a staged version is not built twice.
            if let manifest = manifest ?? store.loadManifest() {
                self.manifest = manifest
                let have = (staged ?? current).bundles
                let missing = wantedLanguages(from: manifest).filter { have[$0] == nil }
                if !missing.isEmpty {
                    download(manifest: manifest, languages: missing, etag: store.manifestETag)
                    return
                }
            }
            sendReports()
            finish(.success(.upToDate))
        case .success(.manifest(let manifest, let etag)):
            self.manifest = manifest
            download(manifest: manifest, languages: wantedLanguages(from: manifest), etag: etag)
        }
    }

    /// Fetches the bundles of `languages` that are not on disk yet, then commits.
    private func download(manifest: Manifest, languages: [String], etag: String?) {
        let group = DispatchGroup()
        var failure: LocalizeMeError?
        for code in languages {
            guard let language = manifest.languages[code], !store.hasBundle(sha256: language.sha256) else { continue }
            group.enter()
            api.fetchBundle(language) { result in
                self.queue.async {
                    switch result {
                    case .success(let data):
                        do {
                            try self.store.saveBundle(data, sha256: language.sha256)
                        } catch {
                            failure = LocalizeMeError(kind: .storage, message: "\(error)")
                        }
                    case .failure(let error):
                        failure = error
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: queue) {
            if let failure {
                self.reporter.recordError(failure)
                self.log("download failed: \(failure)")
                self.sendReports()
                self.finish(.failure(failure))
                return
            }
            self.commit(manifest: manifest, etag: etag)
        }
    }

    private func commit(manifest: Manifest, etag: String?) {
        var snapshot = Snapshot(
            version: manifest.version,
            sourceLanguage: manifest.sourceLanguage,
            bundles: [:],
            codes: manifest.codesByLanguage
        )
        for (code, language) in manifest.languages where store.hasBundle(sha256: language.sha256) {
            snapshot.bundles[code] = language.sha256
        }
        // The ETag only counts once the manifest it belongs to is on disk too,
        // or a later 304 could not say where a missing language comes from.
        do {
            try store.saveManifest(manifest)
            store.saveManifestETag(etag)
        } catch {
            reporter.recordError(LocalizeMeError(kind: .storage, message: "\(error)"))
        }

        if snapshot == current || snapshot == staged {
            // Nothing new: what is live or already waiting. In particular a
            // language downloaded into a staged version is staged only once.
            sendReports()
            finish(.success(.upToDate))
            return
        }

        let outcome: LocalizeMeCheckOutcome
        do {
            if snapshot.version == current.version {
                // Same strings, one more language on disk — the one just asked
                // for. Nothing on screen changes except that language, so it
                // goes live now; a staged newer version stays staged.
                try promote(snapshot, clearStaged: false)
                outcome = .applied(version: snapshot.version)
            } else if configuration.applyImmediately || current.bundles.isEmpty {
                // First run has nothing to disturb: apply straight away.
                try promote(snapshot, clearStaged: true)
                outcome = .applied(version: snapshot.version)
            } else {
                try store.saveSnapshot(snapshot, named: "staged")
                staged = snapshot
                pruneBundles()
                outcome = .staged(version: snapshot.version)
            }
        } catch {
            let failure = LocalizeMeError(kind: .storage, message: "\(error)")
            reporter.recordError(failure)
            finish(.failure(failure))
            return
        }
        log("version \(snapshot.version) \(outcome == .staged(version: snapshot.version) ? "staged" : "applied")")
        notifyUpdate(version: snapshot.version)
        sendReports()
        finish(.success(outcome))
    }

    /// Makes `snapshot` the one the app shows: saves it, swaps the live strings
    /// and drops bundle files nothing points at any more. Throws, changing
    /// nothing, when it cannot be saved.
    private func promote(_ snapshot: Snapshot, clearStaged: Bool) throws {
        try store.saveSnapshot(snapshot, named: "current")
        if clearStaged {
            store.removeSnapshot(named: "staged")
            staged = nil
        }
        current = snapshot
        loadLiveStrings()
        pruneBundles()
    }

    private func pruneBundles() {
        var keep = Set(current.bundles.values)
        if let staged { keep.formUnion(staged.bundles.values) }
        store.pruneBundles(keeping: keep)
    }

    /// Promotes the staged snapshot, if any. Synchronous, so the caller can
    /// re-render right after; true when the strings changed. The app asked
    /// for this, so `onUpdate` is not called.
    @discardableResult
    func applyNow() -> Bool {
        onQueue {
            guard let staged = self.staged else { return false }
            do {
                try self.promote(staged, clearStaged: true)
                self.log("version \(staged.version) applied")
                return true
            } catch {
                self.reporter.recordError(LocalizeMeError(kind: .storage, message: "\(error)"))
                self.log("could not apply version \(staged.version): \(error)")
                return false
            }
        }
    }

    /// Runs `work` on `queue`, inline when already there.
    private func onQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Client.queueKey) == true {
            return work()
        }
        return queue.sync(execute: work)
    }

    private func notifyUpdate(version: Int) {
        guard let onUpdate else { return }
        DispatchQueue.main.async { onUpdate(version) }
    }

    private func finish(_ result: Result<LocalizeMeCheckOutcome, LocalizeMeError>) {
        checking = false
        let completions = pendingCompletions
        pendingCompletions = []
        for completion in completions {
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func sendReports() {
        guard consent == .full, !reporter.isEmpty else { return }
        let (errors, missing) = reporter.drain()
        api.report(errors: errors, missingKeys: missing) { ok in
            if !ok {
                self.reporter.restore(errors: errors, missingKeys: missing)
            }
        }
    }

    func log(_ message: @autoclosure () -> String) {
        guard configuration.debugLogging else { return }
        print("[LocalizeMe] \(message())")
    }
}
