import AppKit
import Darwin

/// Isolated scroll probe using production thumbnail views and read-only media.
/// No ImporterModel, preferences, download records, or source-file mutations.
@main @MainActor
final class ThumbnailScrollBenchmark: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let grid = ThumbnailGridController()
    private var heartbeat: Timer?
    private var lastBeat = CFAbsoluteTimeGetCurrent()
    private var intervals: [Double] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = ThumbnailScrollBenchmark()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run(); NSApp.terminate(nil) }
    }

    private func run() async {
        let directory = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HERMES")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let images = files.filter(FileSystemUtilities.isImage)
        let imageStems = Set(images.map { $0.deletingPathExtension().lastPathComponent })
        let urls = (images + files.filter { FileSystemUtilities.isVideo($0)
            && !imageStems.contains($0.deletingPathExtension().lastPathComponent) })
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else { print("No media fixtures"); return }
        let copies = max(1, Int(CommandLine.arguments.dropFirst(2).first ?? "1") ?? 1)
        let entries = (0..<copies).flatMap { _ in urls }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "HERMES · 缩略图滚动性能验证"
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.orderOut(nil); heartbeat?.invalidate() }
        grid.updateItems(entries.enumerated().map { index, url in
            ThumbnailGridItem(id: "probe-\(index)", url: url, status: .finished,
                mediaKind: FileSystemUtilities.isVideo(url) ? .video : .photo,
                contentVersion: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0)
        }, animatingDifferences: false)
        scroll.layoutSubtreeIfNeeded()
        grid.nsCollectionView.layoutSubtreeIfNeeded()
        print("document_layer_backed=\(grid.nsCollectionView.layer != nil) viewport_layer_backed=\(scroll.contentView.layer != nil) origin_invalidates_layout=\(grid.nsCollectionView.collectionViewLayout?.shouldInvalidateLayout(forBoundsChange: scroll.contentView.bounds.offsetBy(dx: 0, dy: 5)) ?? false)")
        heartbeat = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                self.intervals.append((now - self.lastBeat) * 1000)
                self.lastBeat = now
            }
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
        try? await Task.sleep(for: .milliseconds(500))

        for pass in ["first_scroll", "revisit_scroll"] {
            intervals.removeAll(keepingCapacity: true)
            lastBeat = CFAbsoluteTimeGetCurrent()
            let cpuStart = clock()
            var steps: [Double] = []
            var unreadySteps = 0
            let maxY = max(0, grid.nsCollectionView.bounds.height - scroll.contentView.bounds.height)
            for step in 0..<160 {
                let fraction = Double(step < 80 ? step : 159 - step) / 79
                let start = CFAbsoluteTimeGetCurrent()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * fraction))
                scroll.reflectScrolledClipView(scroll.contentView)
                grid.nsCollectionView.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                steps.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                if grid.nsCollectionView.visibleItems().contains(where: {
                    $0.imageView?.image == nil || $0.imageView?.alphaValue ?? 0 < 1
                }) { unreadySteps += 1 }
                try? await Task.sleep(for: .milliseconds(16))
            }
            let beats = intervals.sorted()
            let work = steps.sorted()
            let output: [String: Any] = [
                "pass": pass, "items": entries.count, "source_files": urls.count,
                "cpu_seconds": Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC),
                "main_gap_p95_ms": beats.isEmpty ? 0 : beats[Int(Double(beats.count - 1) * 0.95)],
                "main_gap_max_ms": beats.last ?? 0,
                "scroll_step_p95_ms": work[Int(Double(work.count - 1) * 0.95)],
                "frames_with_unready_thumbnail": unreadySteps
            ]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) { print(json) }
            try? await Task.sleep(for: .milliseconds(750))
        }
    }
}
