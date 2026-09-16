import XCTest
@testable import HermesNetworking

final class DouyinSourceResolverTests: XCTestCase {
    private func u32(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }
    private func atom(_ type: String, _ payload: Data) -> Data {
        u32(UInt32(payload.count + 8)) + Data(type.utf8) + payload
    }
    private func track(_ kind: String, width: UInt32, height: UInt32) -> Data {
        let tkhd = atom("tkhd", Data(repeating: 0, count: 76) + u32(width << 16) + u32(height << 16))
        let mdia = atom("mdia", atom("hdlr", Data(repeating: 0, count: 8) + Data(kind.utf8)))
        return atom("trak", tkhd + mdia)
    }
    func testSourceRequestUsesActualVideoIDWithoutResolutionCap() {
        let url = DouyinSourceResolver.sourceURL(videoID: "v0200fg10000d9rg4cnog65jspknaig0")!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains(.init(name: "ratio", value: "default")))
        XCTAssertTrue(query.contains(.init(name: "improve_bitrate", value: "1")))
        XCTAssertNil(DouyinSourceResolver.sourceURL(videoID: "https://example.com/video"))
        XCTAssertNil(DouyinSourceResolver.sourceURL(videoID: "7671620362009840930"))
    }
    func testReadsVideoTrackAndSkipsAudio() {
        let data = atom("moov", track("soun", width: 1, height: 1) + track("vide", width: 2560, height: 1440))
        let size = DouyinSourceResolver.dimensions(in: data)
        XCTAssertEqual(size?.width, 2560)
        XCTAssertEqual(size?.height, 1440)
    }
    func testRejectsTruncatedAndMalformedMetadata() {
        let data = atom("moov", track("vide", width: 2560, height: 1440))
        for count in 0..<data.count {
            XCTAssertNil(DouyinSourceResolver.dimensions(in: Data(data.prefix(count))))
        }
        XCTAssertNil(DouyinSourceResolver.dimensions(in: Data(repeating: 255, count: 32)))
        XCTAssertNil(DouyinSourceResolver.dimensions(in: atom("moov", track("soun", width: 2560, height: 1440))))
    }
    func testSupports64BitMediaAtomSize() {
        var size = UInt64(4_550_104_431).bigEndian
        let data = u32(1) + Data("mdat".utf8) + withUnsafeBytes(of: &size) { Data($0) }
        XCTAssertEqual(DouyinSourceResolver.atomHeader(data, at: 0)?.size, 4_550_104_431)
    }
}

private final class SourceRangeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status = url.lastPathComponent == "ignored-range" ? 200 : 206
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes 99-114/1000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 16))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension DouyinSourceResolverTests {
    func testProbeRejectsIgnoredRangeAndWrongOffsetWithoutInvalidatingCallerSession() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SourceRangeProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for path in ["ignored-range", "wrong-offset"] {
            let url = URL(string: "https://example.com/\(path)")!
            do {
                _ = try await DouyinSourceResolver.probe(url: url, userAgent: "test", session: session)
                XCTFail("An invalid range must not be interpreted as video metadata")
            } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
        }
        do {
            let (_, response) = try await session.data(from: URL(string: "https://example.com/ignored-range")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        } catch { XCTFail("The caller's shared session must remain usable: \(error)") }
    }
}
