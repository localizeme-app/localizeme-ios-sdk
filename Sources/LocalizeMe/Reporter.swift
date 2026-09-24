import Foundation

/// Buffers what the SDK wants to tell the dashboard and sends it with the
/// next check, so reporting never costs a request of its own on launch.
final class Reporter {
    static let maxErrorsPerLaunch = 20
    static let maxMissingKeysPerLaunch = 200

    private let lock = NSLock()
    private var errors: [[String: String]] = []
    private var seenErrorTypes: Set<String> = []
    private var missing: [String: [String: String]] = [:]

    func recordError(_ error: LocalizeMeError) {
        lock.lock(); defer { lock.unlock() }
        // One report per type per launch: a failing cache read would otherwise
        // report once per string lookup. A placeholder mismatch is about one
        // key, so those count per key.
        let id = error.kind == .formatMismatch ? "\(error.kind.rawValue)\u{0}\(error.message)" : error.kind.rawValue
        guard !seenErrorTypes.contains(id), errors.count < Reporter.maxErrorsPerLaunch else { return }
        seenErrorTypes.insert(id)
        errors.append(["type": error.kind.rawValue, "message": String(error.message.prefix(500))])
    }

    func recordMissingKey(_ key: String, language: String?) {
        lock.lock(); defer { lock.unlock() }
        guard missing.count < Reporter.maxMissingKeysPerLaunch else { return }
        let id = "\(language ?? "")\u{0}\(key)"
        if missing[id] == nil {
            var entry = ["key": key]
            if let language { entry["language"] = language }
            missing[id] = entry
        }
    }

    /// Everything buffered, cleared. Put it back with `restore` if sending fails.
    func drain() -> (errors: [[String: String]], missingKeys: [[String: String]]) {
        lock.lock(); defer { lock.unlock() }
        let out = (errors, Array(missing.values))
        errors = []
        missing = [:]
        return out
    }

    func restore(errors: [[String: String]], missingKeys: [[String: String]]) {
        lock.lock(); defer { lock.unlock() }
        self.errors = errors + self.errors
        for entry in missingKeys {
            let id = "\(entry["language"] ?? "")\u{0}\(entry["key"] ?? "")"
            if missing[id] == nil { missing[id] = entry }
        }
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return errors.isEmpty && missing.isEmpty
    }
}
