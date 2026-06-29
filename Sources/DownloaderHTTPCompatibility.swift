import Foundation

/// Shared network compatibility layer.
///
/// Provides curl-based fallback with DNS-over-HTTPS resolution for domains
/// affected by DNS poisoning. Used by all platform downloaders (XHS, Douyin, Dewu).
enum DownloaderHTTPCompatibility {
    static func downloadConcurrencyLimit() -> Int {
        if let value = boundedEnvironmentInt("HERMES_DOWNLOAD_CONCURRENCY", range: 1...64) {
            return value
        }
        return min(max(ProcessInfo.processInfo.activeProcessorCount * 2, 8), 24)
    }

    static func hostConnectionLimit() -> Int {
        if let value = boundedEnvironmentInt("HERMES_HOST_CONNECTIONS", range: 1...64) {
            return value
        }
        return min(max(ProcessInfo.processInfo.activeProcessorCount * 3, 12), 32)
    }

    static func tuneDownloadSession(_ configuration: URLSessionConfiguration) {
        configuration.httpMaximumConnectionsPerHost = hostConnectionLimit()
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
    }

    /// Creates a pre-configured ephemeral URLSession for downloading platform media.
    static func makeDownloadSession(
        timeoutRequest: TimeInterval = 30,
        timeoutResource: TimeInterval = 180,
        includeCookieStorage: Bool = true
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        tuneDownloadSession(configuration)
        configuration.timeoutIntervalForRequest = timeoutRequest
        configuration.timeoutIntervalForResource = timeoutResource
        if includeCookieStorage {
            configuration.httpCookieStorage = HTTPCookieStorage()
        }
        return URLSession(configuration: configuration)
    }

    private static func boundedEnvironmentInt(_ key: String, range: ClosedRange<Int>) -> Int? {
        guard let value = ProcessInfo.processInfo.environment[key],
              let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return min(max(parsed, range.lowerBound), range.upperBound)
    }

    // MARK: - DNS-over-HTTPS resolver for domains affected by DNS poisoning

    /// Domains whose DNS may be poisoned — resolve via DoH and pass --resolve to curl.
    private static let dnsOverrideSuffixes: [String] = [
        // Xiaohongshu
        "xhslink.com",
        "xiaohongshu.com",
        "xhscdn.com",
        // Douyin
        "douyin.com",
        "iesdouyin.com",
        "douyinvod.com",
        "snssdk.com"
    ]

    /// DNS cache: host → IPs.  Protected by an actor for sendable safety.
    private static let dnsCacheActor = DNSCacheStore()
    private static let dnsCacheTTL: TimeInterval = 300

    private actor DNSCacheStore {
        private var cache: [String: (ips: [String], timestamp: Date)] = [:]

        func read(_ host: String) -> [String]? {
            guard let entry = cache[host],
                  Date().timeIntervalSince(entry.timestamp) < dnsCacheTTL else { return nil }
            return entry.ips
        }

        func store(_ host: String, ips: [String]) {
            cache[host] = (ips: ips, timestamp: Date())
        }
    }

    /// Returns true if the host matches a domain known to suffer DNS poisoning.
    private static func hostNeedsDNSOverride(_ host: String?) -> Bool {
        guard let host else { return false }
        let lowercased = host.lowercased()
        for suffix in dnsOverrideSuffixes {
            if lowercased == suffix || lowercased.hasSuffix("." + suffix) {
                return true
            }
        }
        return false
    }

    /// Resolve a hostname via DNS-over-HTTPS. Returns cached result when available.
    static func resolveHostViaDoH(_ host: String) async -> [String] {
        let lowercased = host.lowercased()
        let cached: [String]? = await dnsCacheActor.read(lowercased)
        if let cached { return cached }

        let dohSession: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            config.timeoutIntervalForResource = 8
            return URLSession(configuration: config)
        }()

        var ips: [String] = []
        var succeededProvider: String?
        let providers: [(name: String, url: String)] = [
            ("AliDNS",     "https://dns.alidns.com/dns-query?name=\(lowercased)&type=A&ct=application/dns-json"),
            ("DNSPod",     "https://doh.pub/dns-query?name=\(lowercased)&type=A&ct=application/dns-json"),
            ("Google",     "https://dns.google/resolve?name=\(lowercased)&type=A"),
            ("Cloudflare", "https://cloudflare-dns.com/dns-query?name=\(lowercased)&type=A&ct=application/dns-json"),
        ]
        for provider in providers {
            guard let providerURL = URL(string: provider.url) else { continue }
            var req = URLRequest(url: providerURL)
            req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            let data = try? await dohSession.data(for: req).0
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = json["Answer"] as? [[String: Any]] else { continue }
            for answer in answers {
                if (answer["type"] as? Int) == 1,
                   let ip = answer["data"] as? String {
                    ips.append(ip)
                }
            }
            if !ips.isEmpty {
                succeededProvider = provider.name
                break
            }
        }

        if let provider = succeededProvider {
            fputs("[HERMES] DoH resolved \(lowercased) via \(provider): \(ips.joined(separator: ", "))\n", stderr)
            await dnsCacheActor.store(lowercased, ips: ips)
        } else {
            fputs("[HERMES] DoH resolution failed for \(lowercased)\n", stderr)
        }
        return ips
    }

    // MARK: - Public API

    static func shouldUseDirectly(for request: URLRequest) -> Bool {
        false
    }

    static func shouldFallback(after error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && [
                NSURLErrorSecureConnectionFailed,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorCannotFindHost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorServerCertificateUntrusted,
	            NSURLErrorServerCertificateHasUnknownRoot,
	                NSURLErrorAppTransportSecurityRequiresSecureConnection,
	            ].contains(nsError.code)
    }

    // MARK: - Async API

    static func dataAsync(for request: URLRequest, readsBody: Bool = true) async throws -> (Data, URL?) {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HERMES-HTTP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let effectiveURL = try await runCurl(request: request, outputURL: temporaryURL, reportsEffectiveURL: true)
        let data = readsBody ? try Data(contentsOf: temporaryURL) : Data()
        return (data, effectiveURL)
    }

    static func downloadAsync(_ request: URLRequest, to destination: URL) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        _ = try await runCurl(request: request, outputURL: destination, reportsEffectiveURL: false)
    }

    private static func runCurl(
        request: URLRequest,
        outputURL: URL,
        reportsEffectiveURL: Bool
    ) async throws -> URL? {
        guard let url = request.url else {
            throw URLError(.badURL)
        }

        var arguments = [
            "--silent",
            "--show-error",
            "--location",
            "--fail-with-body",
            "--connect-timeout", "5",
            "--max-time", "60",
            "--retry", "2",
            "--retry-all-errors",
            "--output", outputURL.path
        ]

        // --resolve to bypass DNS poisoning for XHS domains
        if let host = url.host, hostNeedsDNSOverride(host) {
            let realIPs = await resolveHostViaDoH(host)
            let ports = Set([url.port ?? (url.scheme == "https" ? 443 : 80), 80, 443])
            for ip in realIPs.prefix(4) {
                for port in ports.sorted() {
                    arguments.append(contentsOf: ["--resolve", "\(host):\(port):\(ip)"])
                }
            }
        }

        for (field, value) in request.allHTTPHeaderFields ?? [:] {
            arguments.append(contentsOf: ["--header", "\(field): \(value)"])
        }
        if reportsEffectiveURL {
            arguments.append(contentsOf: ["--write-out", "%{url_effective}"])
        }
        arguments.append(url.absoluteString)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let output = String(
                    data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errorOutput = String(
                    data: standardError.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: NSError(
                        domain: "DownloaderHTTPCompatibility",
                        code: Int(process.terminationStatus),
                        userInfo: [
                            NSLocalizedDescriptionKey: errorOutput.isEmpty
                                ? "兼容网络请求失败：\(url.absoluteString)"
                                : errorOutput
                        ]
                    ))
                    return
                }

                continuation.resume(returning: reportsEffectiveURL ? URL(string: output) : nil)
            }
        }
    }

}
