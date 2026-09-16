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
