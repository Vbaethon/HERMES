import AppKit
import Darwin
import OSLog
import QuartzCore

/// Instrumentation is inserted into temporary source copies only. Nested
/// function totals overlap; do not add them together as a frame duration.
@MainActor enum ZoomProbeCounters {
    static var active = false
    static var samples: [String: [Double]] = [:]
    static func reset() { samples = [:]; active = true }
    static func record(_ name: String, milliseconds: Double) {
        if active { samples[name, default: []].append(milliseconds) }
    }
    static func measure<T>(_ name: String, _ work: () -> T) -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer { record(name, milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000) }
        return work()
    }
    static func summary(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * fraction)]
        }
        return ["count": sorted.count, "p50_ms": percentile(0.5), "p95_ms": percentile(0.95),
                "max_ms": sorted.last ?? 0, "sum_ms": sorted.reduce(0, +)]
    }
    static func summaries() -> [String: Any] { samples.mapValues(summary) }
}

/// Pre-generated decoded images with four distinct aspect ratios. The worker
/// constructs NSImage wrappers only; no Quick Look, filesystem or defaults I/O.
enum ZoomProbeArtwork {
    private struct Bitmaps: @unchecked Sendable { let values: [CGImage] }
    private static let bitmaps = Bitmaps(values: (0..<16).map { index in
        let sizes = [(384, 512), (512, 384), (512, 512), (320, 640)]
        let (width, height) = sizes[index % sizes.count]
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: CGFloat(index + 1) / 17, green: CGFloat(16 - index) / 17,
                                     blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 0.65))
        context.fill(CGRect(x: width / 7, y: height / 3, width: width / 3, height: height / 5))
        return context.makeImage()!
    })
    static func load(_ url: URL, _ pointSize: CGFloat, _ scale: CGFloat) async -> MediaThumbnailResult {
        // Exercise asynchronous completion bursts under deterministic worker
        // latency while keeping actual media services outside this CPU probe.
        try? await Task.sleep(for: .milliseconds(1))
        guard !Task.isCancelled else { return MediaThumbnailResult() }
        let index = Int(url.deletingPathExtension().lastPathComponent) ?? 0
        let image = bitmaps.values[index % bitmaps.values.count]
        return MediaThumbnailResult(image: NSImage(cgImage: image,
            size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)))
    }
}

private struct ZoomProbeFixture: Decodable {
    let label: String
    let counts: [Int]
    let frames: Int
    let repeats: Int
    let cadence: Int
    let width: Double
    let height: Double
    let startupDelay: Double
    let coldWarmOnly: Bool
}
private struct ZoomProbeError: Error, CustomStringConvertible { let description: String }

@main @MainActor
final class ThumbnailZoomBenchmark: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var grid: ThumbnailGridController!
    private var scroll: NSScrollView!
    private var displayLink: CADisplayLink?
    private var heartbeat: Timer?
    private var inputMonitor: Any?
    private var sampled = false
    private var heartbeatGaps: [Double] = []
    private var displayCallbackGaps: [Double] = []
    private var lastHeartbeat: Double = 0
    private var lastDisplay: Double = 0
    private var externalEvents = 0
    private var externalEventDetails: [[String: Any]] = []
    private let signposter = OSSignposter(subsystem: "com.codex.HERMES.ZoomProbe", category: "zoom")
    private var fixture: ZoomProbeFixture!

    static func main() {
        let app = NSApplication.shared
        let delegate = ThumbnailZoomBenchmark()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run(); NSApp.terminate(nil) }
            catch { fputs("Zoom probe failed: \(error)\n", stderr); cleanup(); exit(1) }
        }
    }

    private func cleanup() {
        sampled = false
        ZoomProbeCounters.active = false
        displayLink?.invalidate(); displayLink = nil
        heartbeat?.invalidate(); heartbeat = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        window?.orderOut(nil)
    }

    private func run() async throws {
        guard let manifest = CommandLine.arguments.dropFirst().first else {
            throw ZoomProbeError(description: "Missing synthetic fixture manifest")
        }
        fixture = try JSONDecoder().decode(ZoomProbeFixture.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: fixture.width, height: fixture.height))
        window = NSWindow(contentRect: scroll.frame,
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "HERMES · Synthetic Zoom CPU Probe"
        window.contentView = scroll
        let toolbar = NSToolbar(identifier: "SyntheticZoomProbeToolbar")
        window.toolbar = toolbar
        window.orderFront(nil)
        defer { cleanup() }
        heartbeat = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sampled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.lastHeartbeat > 0 { self.heartbeatGaps.append((now - self.lastHeartbeat) * 1000) }
                self.lastHeartbeat = now
            }
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown,
                                                                  .scrollWheel, .magnify, .gesture]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.sampled {
                    self.externalEvents += 1
                    self.externalEventDetails.append(["type": event.type.rawValue,
                        "timestamp": event.timestamp, "window_number": event.windowNumber])
                }
            }
            return event
        }
        emit(["event": "setup", "label": fixture.label,
              "fixture": "Generated CGImages; no real media or application preferences",
              "measurement": "Nested main-thread elapsed work, process CPU and callback gaps, not screen FPS",
              "backing_scale": window.backingScaleFactor])
        if fixture.startupDelay > 0 { try await Task.sleep(for: .seconds(fixture.startupDelay)) }
        for count in fixture.counts {
            // A fresh controller makes the first zoom's native badge bitmap
            // cache genuinely cold. A fresh URL prefix prevents the shared
            // synthetic thumbnail cache from inheriting another fixture run.
            grid = ThumbnailGridController()
            scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: fixture.width, height: fixture.height))
            ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
            window.contentView = scroll
            displayLink?.invalidate()
            displayLink = scroll.displayLink(target: self, selector: #selector(displayTick(_:)))
            displayLink?.add(to: .main, forMode: .common)
            let urlPrefix = UUID().uuidString
            grid.updateItems((0..<count).map { index in
                ThumbnailGridItem(id: "synthetic-\(index)",
                    url: URL(fileURLWithPath: "/synthetic-hermes-zoom/\(urlPrefix)/\(index).\(index % 3 == 0 ? "heic" : "jpg")"),
                    status: .finished, mediaKind: .photo, contentVersion: 1)
            }, animatingDifferences: false)
            scroll.layoutSubtreeIfNeeded(); grid.nsCollectionView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(750))
            try await runTransition(count: count, visit: 0, location: "interior", from: 2, to: 3,
                                    preparePreset: false, cacheState: "cold_zoom_cache")
            try await runTransition(count: count, visit: 1, location: "interior", from: 2, to: 3,
                                    cacheState: "warm_same_zoom")
            if fixture.coldWarmOnly { continue }
            for visit in 0..<fixture.repeats {
                for location in ["interior", "newest"] {
                    for (from, to) in [(0, 1), (1, 0), (1, 2), (2, 1), (2, 3), (3, 2)] {
                        try await runTransition(count: count, visit: visit, location: location, from: from, to: to)
                    }
                }
            }
        }
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard sampled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if lastDisplay > 0 { displayCallbackGaps.append((now - lastDisplay) * 1000) }
        lastDisplay = now
    }

    private func submitDisplay() -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        return (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    private func runTransition(count: Int, visit: Int, location: String, from: Int, to: Int,
                               preparePreset: Bool = true, cacheState: String = "preset_prepared") async throws {
        let zoom = grid.zoom!
        if preparePreset {
            zoom.zoom(to: from)
            zoom.displayFrame(at: CACurrentMediaTime() + 10)
            await Task.yield()
        } else if zoom.position != CGFloat(from) || zoom.plan != nil {
            throw ZoomProbeError(description: "Cold fixture was already zoomed before measurement")
        }
        let layout = zoom.layout
        let requestedOrigin = location == "newest" ? zoom.maximumOrigin : zoom.maximumOrigin * 0.5
        scroll.contentView.scroll(to: scroll.contentView.convert(CGPoint(x: 0, y: requestedOrigin), from: grid.nsCollectionView))
        scroll.reflectScrolledClipView(scroll.contentView)
        grid.nsCollectionView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        let viewport = scroll.contentView.documentVisibleRect
        let initialClipBounds = scroll.contentView.bounds
        let initialWindowFrame = window.frame
        let initialContentBounds = window.contentView?.bounds ?? .zero
        let nominalPoint = CGPoint(x: viewport.minX + viewport.width * 0.68,
                                   y: viewport.minY + viewport.height * 0.44)
        guard let index = ZoomGeometry.nearestIndex(to: nominalPoint, count: count,
            width: layout.viewportSize.width, spec: layout.spec, metrics: layout.metrics) else {
            throw ZoomProbeError(description: "Synthetic focal item could not be found")
        }
        let frame = layout.spec.frame(index: index, width: layout.viewportSize.width, metrics: layout.metrics)
        let point = CGPoint(x: frame.minX + frame.width * 0.35, y: frame.minY + frame.height * 0.7)
        let initialPoint = CGPoint(x: point.x - viewport.minX, y: point.y - viewport.minY)
        let visitName = cacheState == "preset_prepared" ? (visit == 0 ? "prepared_first" : "prepared_revisit\(visit)") : cacheState
        let name = "\(count)_\(visitName)_\(location)_\(from)-\(to)"
        let interval = signposter.beginInterval("ZoomGesture", "\(name, privacy: .public)")
        ZoomProbeCounters.reset()
        heartbeatGaps = []; displayCallbackGaps = []; externalEvents = 0; externalEventDetails = []
        lastHeartbeat = ProcessInfo.processInfo.systemUptime; lastDisplay = 0
        sampled = true
        let cpuStart = clock(), wallStart = ProcessInfo.processInfo.systemUptime
        zoom.beginGesture(at: point)
        guard let plan = zoom.plan else { throw ZoomProbeError(description: "Production pinch failed to prepare a plan") }
        var inputSubmissions: [Double] = [], displaySubmissions: [Double] = [], pivotErrors: [Double] = []
        var horizontalPivotErrors: [Double] = [], verticalPivotErrors: [Double] = []
        var maxTiles = zoom.overlay.retainedTileCount
        for step in 1...fixture.frames {
            // Release just short of the preset so the production AppKit
            // animation clock, final layout and deferred handoff all execute.
            let progress = CGFloat(step) / CGFloat(fixture.frames) * 0.9
            let desired = CGFloat(from) + CGFloat(to - from) * progress
            let currentSide = ZoomGeometry.side(width: layout.viewportSize.width, position: zoom.position, metrics: layout.metrics)
            let desiredSide = ZoomGeometry.side(width: layout.viewportSize.width, position: desired, metrics: layout.metrics)
            let start = ProcessInfo.processInfo.systemUptime
            zoom.changeGesture(magnification: 2 * (desiredSide - currentSide) / zoom.gesture!.startSide)
            inputSubmissions.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            displaySubmissions.append(submitDisplay())
            maxTiles = max(maxTiles, zoom.overlay.retainedTileCount)
            if let focal = zoom.overlay.focalFrames[plan.anchor.index] {
                let actual = CGPoint(x: focal.minX + focal.width * plan.anchor.unitPoint.x,
                                     y: focal.minY + focal.height * plan.anchor.unitPoint.y)
                let dx = actual.x - initialPoint.x, dy = actual.y - initialPoint.y
                horizontalPivotErrors.append(abs(dx)); verticalPivotErrors.append(abs(dy))
                pivotErrors.append(hypot(dx, dy))
            }
            try await Task.sleep(for: .nanoseconds(Int64(1_000_000_000 / fixture.cadence)))
        }
        let releaseStart = ProcessInfo.processInfo.systemUptime
        zoom.endGesture()
        let releaseSubmission = (ProcessInfo.processInfo.systemUptime - releaseStart) * 1000
        let deadline = releaseStart + 3
        while (zoom.plan != nil || !zoom.overlay.isHidden) && ProcessInfo.processInfo.systemUptime < deadline {
            displaySubmissions.append(submitDisplay())
            maxTiles = max(maxTiles, zoom.overlay.retainedTileCount)
            try await Task.sleep(for: .nanoseconds(Int64(1_000_000_000 / fixture.cadence)))
        }
        let releaseSettlement = (ProcessInfo.processInfo.systemUptime - releaseStart) * 1000
        try await Task.sleep(for: .milliseconds(80))
        sampled = false; ZoomProbeCounters.active = false
        signposter.endInterval("ZoomGesture", interval)
        let finalViewport = scroll.contentView.documentVisibleRect
        // documentVisibleRect is converted between coordinate systems and can
        // accumulate CGFloat rounding at a fractional document origin. Allow
        // only numeric noise there; the actual clip/window sizes stay exact.
        let documentVisibleSizeUnchanged = abs(finalViewport.width - viewport.width) <= 1e-6
            && abs(finalViewport.height - viewport.height) <= 1e-6
        let clipSizeUnchanged = scroll.contentView.bounds.size == initialClipBounds.size
        let windowSizeUnchanged = window.frame.size == initialWindowFrame.size
        let geometryUnchanged = documentVisibleSizeUnchanged && clipSizeUnchanged && windowSizeUnchanged
        let finished = zoom.plan == nil && zoom.gesture == nil && zoom.overlay.isHidden
        let emptyImages = grid.nsCollectionView.visibleItems().filter { $0.imageView?.image == nil }.count
        var invalidReasons: [String] = []
        if externalEvents > 0 { invalidReasons.append("external_input") }
        if !documentVisibleSizeUnchanged { invalidReasons.append("document_visible_size_changed") }
        if !clipSizeUnchanged { invalidReasons.append("clip_bounds_size_changed") }
        if !windowSizeUnchanged { invalidReasons.append("window_frame_size_changed") }
        if !finished { invalidReasons.append("native_handoff_incomplete") }
        func rectangle(_ rect: CGRect) -> [String: Double] {
            ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
        }
        var record: [String: Any] = [
            "event": "phase", "label": fixture.label, "phase": name, "items": count,
            "zoom_cache_state": cacheState,
            "from_columns": ZoomGeometry.columns[from], "to_columns": ZoomGeometry.columns[to],
            "source_anchor": plan.anchor.index,
            "valid": externalEvents == 0 && geometryUnchanged && finished,
            "invalid_reasons": invalidReasons,
            "external_input_events": externalEvents, "native_handoff_finished": finished,
            "external_input_details": externalEventDetails,
            "geometry": [
                "initial_document_visible_rect": rectangle(viewport),
                "final_document_visible_rect": rectangle(finalViewport),
                "initial_clip_bounds": rectangle(initialClipBounds),
                "final_clip_bounds": rectangle(scroll.contentView.bounds),
                "initial_window_frame": rectangle(initialWindowFrame),
                "final_window_frame": rectangle(window.frame),
                "initial_content_bounds": rectangle(initialContentBounds),
                "final_content_bounds": rectangle(window.contentView?.bounds ?? .zero),
            ],
            "wall_seconds": ProcessInfo.processInfo.systemUptime - wallStart,
            "process_cpu_seconds": Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC),
            "input_submission_main_thread": ZoomProbeCounters.summary(inputSubmissions),
            "display_submission_main_thread": ZoomProbeCounters.summary(displaySubmissions),
            "main_heartbeat_callback_gaps": ZoomProbeCounters.summary(heartbeatGaps),
            "display_link_callback_gaps": ZoomProbeCounters.summary(displayCallbackGaps),
            "release_submission_main_thread_ms": releaseSubmission,
            "release_to_native_handoff_wall_ms": releaseSettlement,
            "max_retained_tiles": maxTiles, "native_visible_empty_images": emptyImages,
            "methods": ZoomProbeCounters.summaries(),
        ]
        // A fixed full-width column preset constrains the final horizontal
        // slot. Its required endpoint movement must not be mistaken for the
        // unwanted newest-pinned vertical movement; report both axes separately.
        func pointSummary(_ values: [Double]) -> [String: Any] {
            let errors = ZoomProbeCounters.summary(values)
            return ["p50": errors["p50_ms"]!, "p95": errors["p95_ms"]!, "max": errors["max_ms"]!]
        }
        let endpointFrame = plan.specs[to].frame(index: plan.anchor.index,
            width: layout.viewportSize.width, metrics: layout.metrics)
        record["computed_pointer_displacement_pt"] = pointSummary(pivotErrors)
        record["computed_pointer_displacement_x_pt"] = pointSummary(horizontalPivotErrors)
        record["computed_pointer_displacement_y_pt"] = pointSummary(verticalPivotErrors)
        record["full_width_endpoint_pointer_shift_x_pt"] = endpointFrame.minX
            + endpointFrame.width * plan.anchor.unitPoint.x - initialPoint.x
        emit(record)
    }

    private func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
    }
}
