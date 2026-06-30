import Foundation
import Testing
@testable import HermesNetworking

@Suite("Downloader network policy")
struct DownloaderNetworkPolicyTests {
    @Test("download sessions ignore system proxy settings")
    func downloadSessionDisablesSystemProxies() {
        let configuration = URLSessionConfiguration.ephemeral

        DownloaderHTTPCompatibility.tuneDownloadSession(configuration)

        let proxyDictionary = configuration.connectionProxyDictionary ?? [:]
        #expect(proxyDictionary[kCFNetworkProxiesHTTPEnable as String] as? Int == 0)
        #expect(proxyDictionary[kCFNetworkProxiesHTTPSEnable as String] as? Int == 0)
        #expect(proxyDictionary[kCFNetworkProxiesSOCKSEnable as String] as? Int == 0)
        #expect(proxyDictionary[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Int == 0)
        #expect(proxyDictionary[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] as? Int == 0)
    }

    @Test("DoH results keep public IPs and reject fake or private IPs")
    func filtersUnsafeResolvedAddresses() {
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

        #expect(filtered == ["106.54.99.69", "118.195.253.242"])
    }

    @Test("404 from a protected host should use compatibility fallback")
    func http404OnProtectedHostUsesFallback() throws {
        let request = URLRequest(url: try #require(URL(string: "https://xhslink.com/o/example")))
        let error = NSError(
            domain: "XHSDownloader",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 404: https://xhslink.com/o/example"]
        )

        #expect(DownloaderHTTPCompatibility.shouldFallback(after: error, for: request))
    }
}
