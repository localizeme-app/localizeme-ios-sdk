import Foundation

/// Answers every request from a handler, so tests run with no network.
///
/// Each test registers its handler under a run id and gets sessions that tag
/// their requests with it. Retiring the run makes a straggler from a finished
/// test (a report POST still in flight) fail instead of reaching the next
/// test's server. The sessions themselves are left alone: creating a task on
/// an invalidated session raises an exception, and a cancelled download's
/// failure path sends a report.
final class MockURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    static let runHeader = "X-LocalizeMe-Test-Run"
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) -> Response] = [:]
    private static var recorded: [URLRequest] = []

    /// Answer the run's requests with `handler`; nil makes them fail as if offline.
    static func setHandler(_ handler: ((URLRequest) -> Response)?, for run: String) {
        lock.lock(); defer { lock.unlock() }
        handlers[run] = handler
    }

    static func retire(_ run: String) {
        lock.lock(); defer { lock.unlock() }
        handlers[run] = nil
        recorded.removeAll { $0.value(forHTTPHeaderField: runHeader) == run }
    }

    static func requests(for run: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.value(forHTTPHeaderField: runHeader) == run }
    }

    static func session(for run: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = [runHeader: run]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let run = request.value(forHTTPHeaderField: MockURLProtocol.runHeader)
        MockURLProtocol.lock.lock()
        MockURLProtocol.recorded.append(request)
        let handler = run.flatMap { MockURLProtocol.handlers[$0] }
        MockURLProtocol.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = handler(request)
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// URLProtocol sees the body as a stream, not `httpBody`.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
