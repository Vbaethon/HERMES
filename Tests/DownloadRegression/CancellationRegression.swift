import AppKit
import Foundation

enum ToolRunResult: Sendable { case success(String), failure(String) }

/// Forces just the slow transfer through the production curl fallback.
private final class CurlFallbackProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.path == "/curl-slow" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
    override func stopLoading() {}
}

@main struct CancellationRegression {
    static func waitForStagedBytes(_ file: URL) async throws {
        for _ in 0..<300 {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if bytes >= 128 * 1024 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "REGRESSION", code: 1, userInfo: [NSLocalizedDescriptionKey: "Slow transfer did not start"])
    }

    static func cancel<T: Sendable>(_ task: Task<T, Error>, staged: URL) async throws {
        do { try await waitForStagedBytes(staged) }
        catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
        let started = Date()
        task.cancel()
        do { _ = try await task.value; fatalError("Cancelled transfer returned success") }
        catch { precondition(DownloaderHTTPCompatibility.isCancellation(error)) }
        precondition(Date().timeIntervalSince(started) < 3, "Cancellation waited for the slow response")
        precondition(!FileManager.default.fileExists(atPath: staged.path), "Cancelled staging file survived")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HERMES-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32)!
        bitmap.bitmapData!.initialize(repeating: 255, count: 64 * 256)
        let validPNG = bitmap.representation(using: .png, properties: [:])!
        try validPNG.write(to: root.appendingPathComponent("valid.png"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("cancellation_fixture_server.py")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", fixture.path, root.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
        }
        let portFile = root.appendingPathComponent("port")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: portFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let successfulCurl = root.appendingPathComponent("successful-curl.png")
        try await DownloaderHTTPCompatibility.downloadAsync(URLRequest(url: base.appendingPathComponent("good")), to: successfulCurl)
        let successfulCurlBytes = try Data(contentsOf: successfulCurl)
        precondition(successfulCurlBytes == validPNG)

        // The production Douyin task group cancels a streaming sibling after a bad source fails.
        let slow = root.appendingPathComponent("douyin-slow.mp4")
        let good = root.appendingPathComponent("completed.jpg")
        do {
            _ = try await DouyinNativeDownloader.download([
                .init(url: base.appendingPathComponent("bad"), destination: root.appendingPathComponent("bad.mp4")),
                .init(url: base.appendingPathComponent("douyin-slow"), destination: slow),
                .init(url: base.appendingPathComponent("good"), destination: good)
            ], maxConcurrentDownloads: 3)
            fatalError("Bad media unexpectedly passed")
        } catch { precondition((error as NSError).domain == "MediaValidation") }
        precondition(!FileManager.default.fileExists(atPath: slow.appendingPathExtension("part").path))
        precondition(!FileManager.default.fileExists(atPath: slow.path))
        let completed = good.deletingPathExtension().appendingPathExtension("png")
        let completedBytes = try Data(contentsOf: completed)
        precondition(completedBytes == validPNG, "Completed media was removed")

        // XHS cancellation must not try the next advertised source.
        let xhs = root.appendingPathComponent("xhs.mp4")
        let xhsTask = Task {
            try await XHSNativeDownloader.download(.init(urls: [base.appendingPathComponent("xhs-slow"), base.appendingPathComponent("xhs-backup")],
                destination: xhs, requestUserAgent: "HERMES-fixture", videoHDRHint: nil), retries: 0)
        }
        try await cancel(xhsTask, staged: xhs.appendingPathExtension("part"))
        let requests = try String(contentsOf: root.appendingPathComponent("requests.txt"), encoding: .utf8)
        precondition(!requests.contains("/xhs-backup"), "Cancellation tried a backup source")

        // Dewu's shared retry path: a group failure cancels a sibling in the curl fallback.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CurlFallbackProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let curl = root.appendingPathComponent("curl.mp4")
        let started = Date()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (path, destination) in [("bad", root.appendingPathComponent("shared-bad.mp4")), ("curl-slow", curl)] {
                    group.addTask {
                        try await DownloaderInfra.downloadWithRetriesAsync(base.appendingPathComponent(path), to: destination, retries: 1,
                            validate: { try await MediaFileUtilities.validateMedia($0, expectedSuffix: "mp4") },
                            userAgent: "HERMES-fixture", session: session, shouldUseDirectly: { _ in false })
                    }
                }
                for try await _ in group {}
            }
            fatalError("Bad shared media unexpectedly passed")
        } catch { precondition((error as NSError).domain == "MediaValidation") }
        precondition(Date().timeIntervalSince(started) < 4, "Curl ignored its parent's cancellation")
        precondition(!FileManager.default.fileExists(atPath: curl.appendingPathExtension("part").path))
        precondition(!FileManager.default.fileExists(atPath: curl.path))
        let finalRequests = try String(contentsOf: root.appendingPathComponent("requests.txt"), encoding: .utf8)
        precondition(finalRequests.components(separatedBy: "\n").filter { $0 == "/curl-slow" }.count == 1, "Cancelled curl retried")
        let finalCompletedBytes = try Data(contentsOf: completed)
        precondition(finalCompletedBytes == validPNG)
        let retainedCurlBytes = try Data(contentsOf: successfulCurl)
        precondition(retainedCurlBytes == validPNG)
        print("PASS: failed batch cancels streaming siblings, cleans staging, keeps completed media; XHS skips backup on cancellation; shared Dewu curl fallback stops promptly without retry")
    }
}
