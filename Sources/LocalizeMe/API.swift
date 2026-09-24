import Foundation

/// The three calls the SDK makes, with the headers the dashboard reads.
final class API {
    static let sdkVersion = "0.1.0-beta.1"
    /// The platform whose strings this SDK asks for.
    static let platform = "ios"

    let configuration: LocalizeMeConfiguration
    let session: URLSession
    let installID: String
    let appVersion: String
    let osVersion: String
    var language: String?

    init(configuration: LocalizeMeConfiguration, session: URLSession, installID: String) {
        self.configuration = configuration
        self.session = session
        self.installID = installID
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        appVersion = build.isEmpty || build == short ? short : "\(short) (\(build))"
        osVersion = API.currentOSVersion()
    }

    enum ManifestResult {
        case notModified
        case manifest(Manifest, etag: String?)
    }

    func fetchManifest(etag: String?, completion: @escaping (Result<ManifestResult, LocalizeMeError>) -> Void) {
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("ota/v1/manifest"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "platform", value: API.platform)]
        var request = makeRequest(url: components.url!)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        perform(request) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let (data, response)):
                if response.statusCode == 304 {
                    completion(.success(.notModified))
                    return
                }
                guard response.statusCode == 200 else {
                    completion(.failure(API.error(for: response, data: data)))
                    return
                }
                do {
                    let envelope = try JSONDecoder().decode(Envelope<Manifest>.self, from: data)
                    guard let manifest = envelope.data else {
                        throw LocalizeMeError(kind: .badResponse, message: envelope.message ?? "empty manifest")
                    }
                    let newETag = response.value(forHTTPHeaderField: "ETag")
                    completion(.success(.manifest(manifest, etag: newETag)))
                } catch let error as LocalizeMeError {
                    completion(.failure(error))
                } catch {
                    completion(.failure(LocalizeMeError(kind: .badResponse, message: "manifest: \(error)")))
                }
            }
        }
    }

    func fetchBundle(_ language: Manifest.Language, completion: @escaping (Result<Data, LocalizeMeError>) -> Void) {
        let request = makeRequest(url: language.url)
        perform(request) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let (data, response)):
                guard response.statusCode == 200 else {
                    completion(.failure(API.error(for: response, data: data)))
                    return
                }
                guard Hashing.sha256Hex(data) == language.sha256 else {
                    completion(.failure(LocalizeMeError(kind: .hashMismatch, message: "bundle \(language.sha256.prefix(8))")))
                    return
                }
                completion(.success(data))
            }
        }
    }

    func report(errors: [[String: String]], missingKeys: [[String: String]], completion: @escaping (Bool) -> Void) {
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("ota/v1/report"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "platform", value: API.platform)]
        var request = makeRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["errors": errors, "missing_keys": missingKeys]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        perform(request) { result in
            if case .success(let (_, response)) = result, (200..<300).contains(response.statusCode) {
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    // MARK: Plumbing

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.sdkKey)", forHTTPHeaderField: "Authorization")
        request.setValue(installID, forHTTPHeaderField: "X-LocalizeMe-Install")
        request.setValue(appVersion, forHTTPHeaderField: "X-LocalizeMe-App")
        request.setValue(API.sdkVersion, forHTTPHeaderField: "X-LocalizeMe-SDK")
        request.setValue(osVersion, forHTTPHeaderField: "X-LocalizeMe-OS")
        if let language {
            request.setValue(language, forHTTPHeaderField: "X-LocalizeMe-Language")
        }
        request.setValue("localizeme-ios/\(API.sdkVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        return request
    }

    private func perform(_ request: URLRequest, completion: @escaping (Result<(Data, HTTPURLResponse), LocalizeMeError>) -> Void) {
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(LocalizeMeError(kind: .network, message: error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(LocalizeMeError(kind: .badResponse, message: "not HTTP")))
                return
            }
            completion(.success((data ?? Data(), http)))
        }
        task.resume()
    }

    private static func error(for response: HTTPURLResponse, data: Data) -> LocalizeMeError {
        let message = (try? JSONDecoder().decode(Envelope<String>.self, from: data))?.message
            ?? "HTTP \(response.statusCode)"
        switch response.statusCode {
        case 401, 403:
            return LocalizeMeError(kind: .unauthorized, message: message)
        default:
            return LocalizeMeError(kind: .badResponse, message: message)
        }
    }

    private static func currentOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if os(iOS)
        return "iOS \(number)"
        #elseif os(tvOS)
        return "tvOS \(number)"
        #elseif os(watchOS)
        return "watchOS \(number)"
        #elseif os(macOS)
        return "macOS \(number)"
        #else
        return number
        #endif
    }
}
