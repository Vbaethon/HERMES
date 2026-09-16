import Foundation
import XCTest
@testable import HermesNetworking

final class DownloaderNetworkPolicyTests: XCTestCase {
    func testDownloadSessionDisablesSystemProxies() {
        let configuration = URLSessionConfiguration.ephemeral

        DownloaderHTTPCompatibility.tuneDownloadSession(configuration)

        let proxyDictionary = configuration.connectionProxyDictionary ?? [:]
        XCTAssertEqual(proxyDictionary[kCFNetworkProxiesHTTPEnable as String] as? Int, 0)
        XCTAssertEqual(proxyDictionary[kCFNetworkProxiesHTTPSEnable as String] as? Int, 0)
        XCTAssertEqual(proxyDictionary[kCFNetworkProxiesSOCKSEnable as String] as? Int, 0)
        XCTAssertEqual(proxyDictionary[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Int, 0)
        XCTAssertEqual(proxyDictionary[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] as? Int, 0)
    }

    func testFiltersUnsafeResolvedAddresses() {
        let rawIPs = [
            "198.18.6.204",
            "10.0.0.8",
            "172.20.0.3",
            "192.168.31.1",
            "127.0.0.1",
            "169.254.1.2",
            "106.54.99.69",
            "118.195.253.242"
        ]

        let filtered = DownloaderNetworkPolicy.publicIPv4Addresses(from: rawIPs)

        XCTAssertEqual(filtered, ["106.54.99.69", "118.195.253.242"])
    }

    func testHTTP404OnProtectedHostUsesFallback() throws {
        let url = try XCTUnwrap(URL(string: "https://xhslink.com/o/example"))
        let request = URLRequest(url: url)
        let error = NSError(
            domain: "XHSDownloader",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 404: https://xhslink.com/o/example"]
        )

        XCTAssertTrue(DownloaderHTTPCompatibility.shouldFallback(after: error, for: request))
    }

    func testCurlCompatibilityArgumentsDisableProxyConfiguration() {
        XCTAssertEqual(DownloaderNetworkPolicy.directCurlArguments, ["--disable", "--noproxy", "*", "--ipv4"])
    }
    func testBothXHSShortLinkDomainsUseCompatibleResolution() throws {
        for host in ["xhslink.com", "xhslink.cn", "XHSLINK.CN"] {
            XCTAssertTrue(DownloaderNetworkPolicy.isXHSShortLinkHost(host))
            let request = URLRequest(url: try XCTUnwrap(URL(string: "https://\(host)/o/example")))
            let error = NSError(domain: "XHSDownloader", code: 404)
            XCTAssertTrue(DownloaderHTTPCompatibility.shouldFallback(after: error, for: request))
        }
        XCTAssertFalse(DownloaderNetworkPolicy.isXHSShortLinkHost("xhslink.cn.example.com"))
        XCTAssertFalse(DownloaderNetworkPolicy.isXHSShortLinkHost(nil))
    }

}
