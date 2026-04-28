import Foundation

/// URLProtocol subclass that intercepts all requests and returns a canned response.
///
/// Use `MockURLProtocol.requestHandler` to set the response for the next request.
///
/// Register before creating a `URLSession`:
/// ```swift
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [MockURLProtocol.self]
/// let session = URLSession(configuration: config)
/// ```
///
/// Note: The cloud refiners and transcribers use `URLSession.shared`, so we rely
/// on swizzling the shared session's protocol classes via `URLProtocol.registerClass`.
/// Each test registers/unregisters the mock via `setUp`/`tearDown`.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    /// Set this before making a request. Takes the incoming `URLRequest` and
    /// returns `(HTTPURLResponse, Data)` or throws.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            // URLSession converts httpBody to httpBodyStream when dispatching through URLProtocol.
            var mutableRequest = request
            if let stream = request.httpBodyStream, request.httpBody == nil {
                stream.open()
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read > 0 { data.append(buffer, count: read) }
                }
                stream.close()
                mutableRequest.httpBody = data
            }
            let (response, responseData) = try handler(mutableRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    // MARK: - Convenience factory

    /// Build an `HTTPURLResponse` with `statusCode` for a given `URL`.
    static func response(for url: URL, statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}
