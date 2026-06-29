import AppKit
import Foundation

// MARK: - Shared download infrastructure

/// Box types and async helpers shared by all platform downloaders (Dewu, Douyin, XHS).
enum DownloaderInfra {
    typealias ProgressHandler = @Sendable (Double) async -> Void

    actor DownloadProgressAggregator {
        private let totalCount: Int
        private let handler: ProgressHandler?
        private var fractions: [Int: Double] = [:]

        init(totalCount: Int, handler: ProgressHandler?) {
            self.totalCount = max(totalCount, 1)
            self.handler = handler
        }

        func update(index: Int, fraction: Double) async {
            fractions[index] = min(max(fraction, 0), 1)
            await publish()
        }

        func complete(index: Int) async {
            fractions[index] = 1
            await publish()
        }

        private func publish() async {
            guard let handler else { return }
            let sum = fractions.values.reduce(0, +)
            await handler(min(max(sum / Double(totalCount), 0), 1))
        }
    }

    // MARK: - Async HTTP request (eliminates URLSession semaphore)

    /// Performs an HTTP GET request asynchronously.  Falls back to `DownloaderHTTPCompatibility`
    /// (curl) when the primary `URLSession` call fails with a retryable error.
    static func requestAsync(
        _ url: URL,
        headers: [String: String] = [:],
        userAgent: String,
        session: URLSession,
        shouldUseDirectly: (URLRequest) -> Bool
    ) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.assumesHTTP3Capable = false
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers where !["accept-encoding", "content-length"].contains(key.lowercased()) {
            req.setValue(value, forHTTPHeaderField: key)
        }
        if shouldUseDirectly(req) {
            return try await DownloaderHTTPCompatibility.dataAsync(for: req).0
        }
        do {
            let (data, response) = try await session.data(for: req)
            if let httpResponse = response as? HTTPURLResponse, !(200..<400).contains(httpResponse.statusCode) {
                throw NSError(domain: "DownloaderInfra", code: httpResponse.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(url.absoluteString)"])
            }
            return data
        } catch {
            guard DownloaderHTTPCompatibility.shouldFallback(after: error) else { throw error }
            return try await DownloaderHTTPCompatibility.dataAsync(for: req).0
        }
    }

    // MARK: - Async download once (eliminates URLSession semaphore)

    /// Downloads a single file asynchronously.  Falls back to `DownloaderHTTPCompatibility`
    /// (curl) when the primary `URLSession` call fails with a retryable error.
    static func downloadOnceAsync(
        _ url: URL,
        to destination: URL,
        userAgent: String,
        session: URLSession,
        shouldUseDirectly: (URLRequest) -> Bool,
        extraHeaders: [String: String] = [:],
        progress: ProgressHandler? = nil
    ) async throws {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.assumesHTTP3Capable = false
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: key)
        }
        if shouldUseDirectly(req) {
            await progress?(0)
            try await DownloaderHTTPCompatibility.downloadAsync(req, to: destination)
            await progress?(1)
            return
        }
        do {
            try await streamDownload(req, to: destination, session: session, progress: progress)
        } catch {
            guard DownloaderHTTPCompatibility.shouldFallback(after: error) else { throw error }
            await progress?(0)
            try await DownloaderHTTPCompatibility.downloadAsync(req, to: destination)
            await progress?(1)
        }
    }

    private static func streamDownload(
        _ request: URLRequest,
        to destination: URL,
        session: URLSession,
        progress: ProgressHandler?
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<400).contains(httpResponse.statusCode) {
            throw NSError(
                domain: "DownloaderInfra",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(request.url?.absoluteString ?? "")"]
            )
        }
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let expectedLength = (response as? HTTPURLResponse)?.expectedContentLength ?? response.expectedContentLength
        var receivedLength: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(128 * 1024)
        var lastPublished: Double = -1

        func publishIfNeeded(force: Bool = false) async {
            guard expectedLength > 0 else { return }
            let fraction = min(max(Double(receivedLength) / Double(expectedLength), 0), 1)
            if force || fraction - lastPublished >= 0.01 {
                lastPublished = fraction
                await progress?(fraction)
            }
        }

        await progress?(0)
        for try await byte in bytes {
            buffer.append(byte)
            receivedLength += 1
            if buffer.count >= 128 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                await publishIfNeeded()
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        await publishIfNeeded(force: true)
        await progress?(1)
    }

    // MARK: - Async retry loop (preferred — no semaphore bridge)

    static func downloadWithRetriesAsync(
        _ url: URL,
        to destination: URL,
        fallbackURLs: [URL] = [],
        retries: Int = 3,
        userAgent: String,
        session: URLSession,
        shouldUseDirectly: @escaping (URLRequest) -> Bool,
        extraHeaders: [String: String] = [:],
        progress: ProgressHandler? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lastError: Error?
        var candidates: [URL] = []
        var seen = Set<String>()
        for candidate in [url] + fallbackURLs where seen.insert(candidate.absoluteString).inserted {
            candidates.append(candidate)
        }
        for candidate in candidates {
            for _ in 0..<retries {
                do {
                    let temporaryURL = destination.appendingPathExtension("part")
                    try await downloadOnceAsync(candidate, to: temporaryURL, userAgent: userAgent, session: session, shouldUseDirectly: shouldUseDirectly, extraHeaders: extraHeaders, progress: progress)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: temporaryURL, to: destination)
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                    return
                } catch {
                    lastError = error
                    try? FileManager.default.removeItem(at: destination.appendingPathExtension("part"))
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        throw lastError ?? NSError(domain: "DownloaderInfra", code: 1, userInfo: [NSLocalizedDescriptionKey: "下载失败：\(destination.lastPathComponent)"])
    }

    // MARK: - Shared utility helpers

    /// Safely convert an `Any?` value to `String?`.
    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    /// Safely convert an `Any?` value to a non-empty `String?`.
    static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = string(value), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Safely convert an `Any?` value to `Int`.
    static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return Int(string(value) ?? "") ?? 0
    }

    /// Safely convert an `Any?` value to `Bool`.
    static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        let text = (string(value) ?? "").lowercased()
        return text == "true" || text == "1" || text == "yes"
    }

    /// Strip trailing punctuation characters commonly found at the end of URLs
    /// extracted from free-form text (e.g. Chinese commas, full-width brackets).
    static func trimURLPunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "，,。！!）)]】"))
    }

    /// Decode Unicode escape sequences (\\uXXXX) and HTML entities in a URL string.
    /// Uses dydl's full implementation that handles `&amp;`, `\\u0026`, etc.
    static func formatURL(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\u003D", with: "=")
            .replacingOccurrences(of: "\\u003f", with: "?")
            .replacingOccurrences(of: "\\u003F", with: "?")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard normalized.contains("\\u") || normalized.contains("\\/") else {
            return normalized
        }
        let jsonText = "\"\(normalized)\""
        if let data = jsonText.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return decoded
        }
        return normalized
    }

    /// Detect the file type of a downloaded file by reading its binary signature.
    /// Returns the appropriate file extension.
    static func sniffSuffix(_ url: URL, defaultSuffix: String) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return defaultSuffix
        }
        let data = handle.readData(ofLength: 16)
        try? handle.close()
        let signatures: [(Int, [UInt8], String)] = [
            (0, [0xff, 0xd8, 0xff], "jpg"),
            (0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], "png"),
            (4, Array("ftypavif".utf8), "avif"),
            (4, Array("ftypheic".utf8), "heic"),
            (8, Array("WEBP".utf8), "webp"),
            (4, Array("ftypMSNV".utf8), "mp4"),
            (4, Array("ftypisom".utf8), "mp4"),
            (4, Array("ftypmp42".utf8), "mp4"),
            (4, Array("ftypqt  ".utf8), "mov")
        ]
        for (offset, signature, suffix) in signatures where data.count >= offset + signature.count {
            if Array(data[offset..<(offset + signature.count)]) == signature {
                return suffix
            }
        }
        return defaultSuffix
    }

    /// Decode HTML entities in a string using NSAttributedString.
    static func htmlDecode(_ value: String) -> String {
        guard let data = value.data(using: .utf8),
              let decoded = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ).string else {
            return value
        }
        return decoded
    }

    /// Safely create a mutable dictionary from an `Any?` value.
    static func mutableDictionary(_ value: Any?) -> NSMutableDictionary {
        if let dictionary = value as? NSDictionary {
            return dictionary.mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
        }
        return NSMutableDictionary()
    }

}

// MARK: - Shared Box types

final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func set(_ result: Result<T, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() throws -> T { lock.lock(); defer { lock.unlock() }; return try value!.get() }
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var error: Error?
    var hasError: Bool { lock.lock(); defer { lock.unlock() }; return error != nil }
    func set(_ error: Error) { lock.lock(); if self.error == nil { self.error = error }; lock.unlock() }
}
