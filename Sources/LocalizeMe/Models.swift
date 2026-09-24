import Foundation

/// The manifest the API answers with: what is current, per language.
struct Manifest: Codable, Equatable {
    struct Language: Codable, Equatable {
        let url: URL
        let sha256: String
        let size: Int
        let strings: Int
        /// The other codes this language answers to (`nb` and `nb-NO` for
        /// `no`). Absent from manifests older than the field.
        let codes: [String]?
    }

    let version: Int
    let platform: String
    let sourceLanguage: String?
    let languages: [String: Language]

    private enum CodingKeys: String, CodingKey {
        case version, platform, languages
        case sourceLanguage = "source_language"
    }

    /// Every language with the other codes it answers to, the shape
    /// `LanguageResolver` takes.
    var codesByLanguage: [String: [String]] {
        languages.mapValues { $0.codes ?? [] }
    }
}

/// The API's envelope around every JSON answer.
struct Envelope<T: Decodable>: Decodable {
    let success: Bool
    let message: String?
    let data: T?
}

/// One language's strings as downloaded.
struct StringBundle: Codable, Equatable {
    let v: Int
    let project: Int
    let platform: String
    let lang: String
    let strings: [String: String]
}

/// What is on disk and in memory: a manifest version plus one bundle per
/// language that has been downloaded for it.
struct Snapshot: Codable, Equatable {
    var version: Int
    var sourceLanguage: String?
    /// language code → sha256 of the bundle file on disk
    var bundles: [String: String]
    /// language code → the other codes it answers to, copied from the
    /// manifest so a device can be matched to a bundle without the network.
    var codes: [String: [String]]

    static let empty = Snapshot(version: 0, sourceLanguage: nil, bundles: [:], codes: [:])
}

/// What an update check found.
public enum LocalizeMeCheckOutcome: Equatable {
    /// The server said nothing changed.
    case upToDate
    /// New strings were downloaded and applied.
    case applied(version: Int)
    /// New strings were downloaded and will apply on the next launch or on `applyNow()`.
    case staged(version: Int)
    /// The check was skipped because one ran less than `minimumCheckInterval` ago.
    case throttled
}

public struct LocalizeMeError: Error, Equatable, CustomStringConvertible {
    public enum Kind: String {
        case notStarted = "not_started"
        case unauthorized
        case badResponse = "bad_response"
        case hashMismatch = "hash_mismatch"
        case network
        case storage
        /// An OTA value's placeholders differ from the shipped string's; the
        /// message names the key. The shipped string is used instead.
        case formatMismatch = "format_mismatch"
    }

    public let kind: Kind
    public let message: String

    public var description: String { "\(kind.rawValue): \(message)" }
}
