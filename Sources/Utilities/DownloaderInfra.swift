import AppKit
import Foundation

// MARK: - Shared download infrastructure

/// Box types and async helpers shared by all platform downloaders (Dewu, Douyin, XHS).
enum DownloaderInfra {
    typealias ProgressHandler = @Sendable (Double) async -> Void

    enum DownloadStage: CaseIterable, Equatable, Sendable {
        case readingLink, findingMedia, readingClient, waitingClient
        case downloadingFile, downloadingImage, downloadingVideo, downloadingLivePhoto
        case checkingFile, recoveringAudio, savingFile
        case waitingForResponse, retrying, tryingAlternative, completed, failed

        var text: String {
            switch self {
            case .readingLink: "读取链接"
            case .findingMedia: "查找资源"
            case .readingClient: "读取客户端"
            case .waitingClient: "等待客户端"
            case .downloadingFile: "下载文件"
            case .downloadingImage: "下载图片"
            case .downloadingVideo: "下载视频"
            case .downloadingLivePhoto: "下载实况"
            case .checkingFile: "检查文件"
            case .recoveringAudio: "补充声音"
            case .savingFile: "保存文件"
            case .waitingForResponse: "等待响应"
            case .retrying: "重试下载"
            case .tryingAlternative: "尝试其他地址"
            case .completed: "下载完成"
            case .failed: "下载失败"
            }
        }

        var priority: Int {
            switch self {
            case .waitingForResponse, .waitingClient: 3
            case .retrying, .tryingAlternative: 2
            case .checkingFile, .savingFile, .completed, .failed: 0
            default: 1
            }
        }

        var isTransfer: Bool {
            switch self {
            case .downloadingFile, .downloadingImage, .downloadingVideo, .downloadingLivePhoto: true
            default: false
            }
        }
    }

    struct DownloadStatus: Equatable, Sendable {
        var stage: DownloadStage
        var item: String? = nil

        var text: String {
            guard let item else { return stage.text }
            return "\(item) · \(stage.isTransfer ? "下载中" : stage.text)"
        }

        func forItem(_ item: String) -> Self { Self(stage: stage, item: item) }
    }

    typealias StatusHandler = @Sendable (DownloadStatus) async -> Void

    @TaskLocal static var statusHandler: StatusHandler?

    static func reportStatus(_ stage: DownloadStage) async {
        guard !Task.isCancelled, let statusHandler else { return }
        await statusHandler(DownloadStatus(stage: stage))
    }

    actor DownloadProgressAggregator {
        private struct ActiveStatus {
            let status: DownloadStatus
            let sequence: Int
        }
        private let totalCount: Int
        private let handler: ProgressHandler?
        private let statusHandler: StatusHandler?
        private var fractions: [Int: Double] = [:]
        private var statuses: [Int: ActiveStatus] = [:]
        private var completedIndices = Set<Int>()
        private var statusSequence = 0
        private var lastPublishedStatus: DownloadStatus?
        private var hasStatusUpdates = false
        private var lastPublishedProgress: Double?
        private var isPublishingProgress = false

        init(totalCount: Int, handler: ProgressHandler?) {
            self.totalCount = max(totalCount, 1)
            self.handler = handler
            self.statusHandler = DownloaderInfra.statusHandler
        }

        func update(index: Int, fraction: Double) async {
            guard !Task.isCancelled, (0..<totalCount).contains(index), fraction.isFinite,
                  !completedIndices.contains(index) else { return }
            let next = max(fractions[index] ?? 0, min(max(fraction, 0), 1))
            guard fractions[index] != next else { return }
            fractions[index] = next
            await publish()
        }

        func complete(index: Int) async {
            guard !Task.isCancelled, (0..<totalCount).contains(index), !completedIndices.contains(index) else { return }
            fractions[index] = 1
            completedIndices.insert(index)
            statuses.removeValue(forKey: index)
            await publish()
            await publishStatus()
        }

        func updateStatus(index: Int, status: DownloadStatus) async {
            guard !Task.isCancelled, !completedIndices.contains(index) else { return }
            hasStatusUpdates = true
            statusSequence += 1
            statuses[index] = ActiveStatus(status: status, sequence: statusSequence)
            await publishStatus()
        }

        private func publishStatus() async {
            guard !Task.isCancelled, hasStatusUpdates, let statusHandler else { return }
            let status = statuses.values.max {
                $0.status.stage.priority == $1.status.stage.priority
                    ? $0.sequence < $1.sequence : $0.status.stage.priority < $1.status.stage.priority
            }?.status ?? (completedIndices.count == totalCount ? DownloadStatus(stage: .completed) : nil)
            guard let status, status != lastPublishedStatus else { return }
            lastPublishedStatus = status
            await statusHandler(status)
        }

        private func publish() async {
            guard let handler, !isPublishingProgress else { return }
            isPublishingProgress = true
            defer { isPublishingProgress = false }
            // The handler suspends across actors. Serialize it and coalesce
            // updates received while suspended so older callbacks cannot arrive last.
            while !Task.isCancelled {
                let value = min(max(fractions.values.reduce(0, +) / Double(totalCount), 0), 1)
                if let lastPublishedProgress, value <= lastPublishedProgress { return }
                lastPublishedProgress = value
                await handler(value)
            }
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
        try Task.checkCancellation()
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
            try Task.checkCancellation()
            guard DownloaderHTTPCompatibility.shouldFallback(after: error, for: req) else { throw error }
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
        progress: ProgressHandler? = nil,
        transferPolicy: DownloaderHTTPCompatibility.TransferPolicy? = nil,
        stage: DownloadStage = .downloadingFile
    ) async throws {
        try Task.checkCancellation()
        await reportStatus(stage)
        let statusMonitor: Task<Void, Never>?
        if statusHandler != nil {
            statusMonitor = Task { await monitorTransferStatus(at: destination, stage: stage) }
        } else { statusMonitor = nil }
        try await withTaskCancellationHandler {
            do {
                try await performDownloadOnceAsync(url, to: destination, userAgent: userAgent,
                    session: session, shouldUseDirectly: shouldUseDirectly, extraHeaders: extraHeaders,
                    progress: progress, transferPolicy: transferPolicy, stage: stage)
                statusMonitor?.cancel()
                await statusMonitor?.value
            } catch {
                statusMonitor?.cancel()
                await statusMonitor?.value
                throw error
            }
        } onCancel: {
            statusMonitor?.cancel()
        }
    }

    private static func performDownloadOnceAsync(
        _ url: URL,
        to destination: URL,
        userAgent: String,
        session: URLSession,
        shouldUseDirectly: (URLRequest) -> Bool,
        extraHeaders: [String: String],
        progress: ProgressHandler?,
        transferPolicy: DownloaderHTTPCompatibility.TransferPolicy?,
        stage: DownloadStage
    ) async throws {
        var req = URLRequest(url: url)
        req.timeoutInterval = transferPolicy.map { TimeInterval($0.idleTimeout) } ?? 30
        req.assumesHTTP3Capable = false
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: key)
        }
        if shouldUseDirectly(req) {
            await progress?(0)
            try await DownloaderHTTPCompatibility.downloadAsync(req, to: destination, transferPolicy: transferPolicy)
            await progress?(1)
            return
        }
        do {
            if let transferPolicy {
                let request = req
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await streamDownload(request, to: destination, session: session, progress: progress)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(transferPolicy.maximumDuration))
                        throw URLError(.timedOut)
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } else {
                try await streamDownload(req, to: destination, session: session, progress: progress)
            }
        } catch {
            try Task.checkCancellation()
            guard DownloaderHTTPCompatibility.shouldFallback(after: error, for: req) else { throw error }
            await reportStatus(.retrying)
            await progress?(0)
            await reportStatus(stage)
            try await DownloaderHTTPCompatibility.downloadAsync(req, to: destination, transferPolicy: transferPolicy)
            await progress?(1)
        }
    }

    /// File growth is available for both native streaming and curl. An unchanged
    /// progress callback alone is not evidence that a transfer has stopped.
    private static func monitorTransferStatus(at destination: URL, stage: DownloadStage) async {
        var previousSize: UInt64 = 0
        var lastGrowth = ContinuousClock.now
        var isWaiting = false
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if size > previousSize {
                lastGrowth = .now
                if isWaiting { await reportStatus(stage) }
                isWaiting = false
            } else if size < previousSize {
                // Switching from native to curl replaces the staged file.
                lastGrowth = .now
                isWaiting = false
            } else if lastGrowth.duration(to: .now) >= .seconds(4) {
                if !isWaiting { await reportStatus(.waitingForResponse) }
                isWaiting = true
            }
            previousSize = size
        }
    }

    private static func streamDownload(
        _ request: URLRequest,
        to destination: URL,
        session: URLSession,
        progress: ProgressHandler?
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
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
            let fraction: Double
            if expectedLength > 0 {
                fraction = min(max(Double(receivedLength) / Double(expectedLength), 0), 1)
            } else {
                // 无 Content-Length 时用渐进估算：已收块数 / (已收块数 + 6)，逼近 0.95
                let chunks = Double(receivedLength) / (128.0 * 1024.0)
                fraction = min(chunks / (chunks + 6.0), 0.95)
            }
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
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                await publishIfNeeded()
            }
        }
        try Task.checkCancellation()
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
        validate: (@Sendable (URL) async throws -> Void)? = nil,
        userAgent: String,
        session: URLSession,
        shouldUseDirectly: @escaping (URLRequest) -> Bool,
        extraHeaders: [String: String] = [:],
        progress: ProgressHandler? = nil,
        stage: DownloadStage = .downloadingFile
    ) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = destination.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        var lastError: Error?
        var candidates: [URL] = []
        var seen = Set<String>()
        for candidate in [url] + fallbackURLs where seen.insert(candidate.absoluteString).inserted {
            candidates.append(candidate)
        }
        for (sourceIndex, candidate) in candidates.enumerated() {
            if sourceIndex > 0 { await reportStatus(.tryingAlternative) }
            for attempt in 0..<retries {
                do {
                    try await downloadOnceAsync(candidate, to: temporaryURL, userAgent: userAgent, session: session, shouldUseDirectly: shouldUseDirectly, extraHeaders: extraHeaders, progress: progress, stage: stage)
                    if validate != nil { await reportStatus(.checkingFile) }
                    try await validate?(temporaryURL)
                    try Task.checkCancellation()
                    await reportStatus(.savingFile)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: temporaryURL, to: destination)
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                    return
                } catch {
                    try Task.checkCancellation()
                    if DownloaderHTTPCompatibility.isCancellation(error) { throw error }
                    lastError = error
                    try? FileManager.default.removeItem(at: temporaryURL)
                    if attempt + 1 < retries { await reportStatus(.retrying) }
                    else if sourceIndex + 1 < candidates.count { await reportStatus(.tryingAlternative) }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        throw lastError ?? NSError(domain: "DownloaderInfra", code: 1, userInfo: [NSLocalizedDescriptionKey: "下载失败：\(destination.lastPathComponent)"])
    }

    // MARK: - Shared utility helpers

    static func string(_ value: Any?) -> String? {
        JSONValueUtilities.string(value)
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        JSONValueUtilities.nonEmptyString(value)
    }

    static func intValue(_ value: Any?) -> Int {
        JSONValueUtilities.intValue(value)
    }

    static func boolValue(_ value: Any?) -> Bool {
        JSONValueUtilities.boolValue(value)
    }

    static func trimURLPunctuation(_ value: String) -> String {
        MediaFileUtilities.trimURLPunctuation(value)
    }

    static func formatURL(_ value: String) -> String {
        MediaFileUtilities.formatURL(value)
    }

    static func sniffSuffix(_ url: URL, defaultSuffix: String) -> String {
        MediaFileUtilities.sniffSuffix(url, defaultSuffix: defaultSuffix)
    }

    static func htmlDecode(_ value: String) -> String {
        MediaFileUtilities.htmlDecode(value)
    }

    static func mutableDictionary(_ value: Any?) -> NSMutableDictionary {
        JSONValueUtilities.mutableDictionary(value)
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
