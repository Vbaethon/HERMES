import CFNetwork
import Foundation

enum DownloaderNetworkPolicy {
    static let protectedDomainSuffixes: [String] = [
        "xhslink.com",
        "xhslink.cn",
        "xiaohongshu.com",
        "xhscdn.com",
        "douyin.com",
        "iesdouyin.com",
        "douyinvod.com",
        "snssdk.com"
    ]

    static let fallbackHTTPStatusCodes: Set<Int> = [403, 404, 429, 451]
    static let directCurlArguments = ["--disable", "--noproxy", "*", "--ipv4"]

    static func configureDirectSession(_ configuration: URLSessionConfiguration) {
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0
        ]
    }

    static func isXHSShortLinkHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "xhslink.com" || host == "xhslink.cn"
    }

    static func hostNeedsDNSOverride(_ host: String?) -> Bool {
        guard let host else { return false }
        let lowercased = host.lowercased()
        for suffix in protectedDomainSuffixes {
            if lowercased == suffix || lowercased.hasSuffix("." + suffix) {
                return true
            }
        }
        return false
    }

    static func publicIPv4Addresses(from addresses: [String]) -> [String] {
        var seen = Set<String>()
        var filtered: [String] = []
        for address in addresses where isPublicIPv4Address(address) && seen.insert(address).inserted {
            filtered.append(address)
        }
        return filtered
    }

    static func isPublicIPv4Address(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }

        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (100, 64...127), (127, _), (169, 254), (172, 16...31),
             (192, 0), (192, 168), (198, 18...19), (224...255, _):
            return false
        default:
            return true
        }
    }

    static func shouldFallbackHTTPStatus(_ statusCode: Int, for request: URLRequest) -> Bool {
        guard fallbackHTTPStatusCodes.contains(statusCode) else { return false }
        return hostNeedsDNSOverride(request.url?.host)
    }
}
