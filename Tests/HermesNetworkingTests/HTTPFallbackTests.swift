import Foundation
import XCTest
@testable import HermesNetworking

private final class StatusProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: Int(url.lastPathComponent)!, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("primary".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HTTPFallbackTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testProtectedHTTPFailuresActuallyEnterFallback() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        for host in ["www.xiaohongshu.com", "www.douyin.com", "xhslink.cn"] {
            for status in [403, 404, 429, 451] {
                let request = URLRequest(url: URL(string: "https://\(host)/\(status)")!)
                let result = try await DownloaderHTTPCompatibility.requestData(for: request, session: session) { request, readsBody in
                    XCTAssertTrue(readsBody)
                    return (Data("fallback".utf8), request.url)
                }
                XCTAssertEqual(result.0, Data("fallback".utf8))
                XCTAssertEqual(result.1, request.url)
            }
        }
    }

    func testSuccessDoesNotRetryAndHonorsReadsBody() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let result = try await DownloaderHTTPCompatibility.requestData(
            for: URLRequest(url: URL(string: "https://www.xiaohongshu.com/200")!), session: session, readsBody: false
        ) { _, _ in
            XCTFail("Successful requests must not fall back")
            return (Data(), nil)
        }
        XCTAssertTrue(result.0.isEmpty)
    }

    func testUnrelatedHostDoesNotRetryHTTP404() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await DownloaderHTTPCompatibility.requestData(
                for: URLRequest(url: URL(string: "https://example.com/404")!), session: session
            ) { _, _ in
                XCTFail("An unrelated HTTP 404 must not enter fallback")
                return (Data(), nil)
            }
            XCTFail("Expected the original error")
        } catch {
            XCTAssertEqual((error as NSError).code, 404)
        }
    }
}
