import Foundation

/// The on-disk cache: a snapshot pointer and one JSON file per bundle.
///
/// Layout under `Caches/LocalizeMe/<key prefix>/`:
///   current.json   the snapshot the app is showing
///   staged.json    a newer snapshot waiting for `applyNow()` or the next launch
///   manifest.json  the last manifest, so a 304 still says where a language
///                  the device newly wants can be downloaded from
///   etag           the manifest ETag for the conditional request
///   bundles/<sha>.json
///
/// Every write goes to a temporary file first and is renamed into place, so a
/// crash mid-write leaves the old file, never a torn one.
final class Store {
    let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
    }

    static func defaultRoot(keyPrefix: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("LocalizeMe", isDirectory: true)
            .appendingPathComponent(keyPrefix, isDirectory: true)
    }

    // MARK: Snapshots

    func loadSnapshot(named name: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("\(name).json")) else {
            return nil
        }
        return try? decoder.decode(Snapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: Snapshot, named name: String) throws {
        try write(try encoder.encode(snapshot), to: root.appendingPathComponent("\(name).json"))
    }

    func removeSnapshot(named name: String) {
        try? fileManager.removeItem(at: root.appendingPathComponent("\(name).json"))
    }

    // MARK: Manifest

    func loadManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")) else {
            return nil
        }
        return try? decoder.decode(Manifest.self, from: data)
    }

    func saveManifest(_ manifest: Manifest) throws {
        try write(try encoder.encode(manifest), to: root.appendingPathComponent("manifest.json"))
    }

    // MARK: ETag

    var manifestETag: String? {
        get {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("etag")) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    func saveManifestETag(_ etag: String?) {
        let url = root.appendingPathComponent("etag")
        guard let etag, let data = etag.data(using: .utf8) else {
            try? fileManager.removeItem(at: url)
            return
        }
        try? write(data, to: url)
    }

    // MARK: Bundles

    func bundleURL(sha256: String) -> URL {
        root.appendingPathComponent("bundles", isDirectory: true)
            .appendingPathComponent("\(sha256).json")
    }

    func hasBundle(sha256: String) -> Bool {
        fileManager.fileExists(atPath: bundleURL(sha256: sha256).path)
    }

    func saveBundle(_ data: Data, sha256: String) throws {
        try write(data, to: bundleURL(sha256: sha256))
    }

    func loadBundle(sha256: String) -> StringBundle? {
        guard let data = try? Data(contentsOf: bundleURL(sha256: sha256)) else { return nil }
        return try? decoder.decode(StringBundle.self, from: data)
    }

    /// Drop bundle files no snapshot points at any more.
    func pruneBundles(keeping shas: Set<String>) {
        let dir = root.appendingPathComponent("bundles", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where file.hasSuffix(".json") {
            let sha = String(file.dropLast(5))
            if !shas.contains(sha) {
                try? fileManager.removeItem(at: dir.appendingPathComponent(file))
            }
        }
    }

    func wipe() {
        try? fileManager.removeItem(at: root)
    }

    // MARK: Plumbing

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}
