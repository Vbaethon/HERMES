import AppKit
import Darwin
import OSLog
import QuartzCore

/// Counters called only from instrumented temporary copies of production sources.
/// Deferred Core Animation/WindowServer work is captured by the signposted trace,
/// not inferred from the synchronous setter or layout durations below.
@MainActor enum WindowProbeCounters {
    static var active = false
    static var counts: [String: Int] = [:]
    static var costs: [String: Double] = [:]
    static var paneActions: [[String: Any]] = []
    static var inputEvents: [[String: Any]] = []

    static func reset() { counts = [:]; costs = [:]; paneActions = []; inputEvents = []; active = true }
    static func record(_ key: String, milliseconds: Double? = nil) {
        guard active else { return }
        counts[key, default: 0] += 1
        if let milliseconds {
            costs[key + "_sum_ms", default: 0] += milliseconds
            costs[key + "_max_ms"] = max(costs[key + "_max_ms", default: 0], milliseconds)
        }
    }
    static func visibility(_ collection: NSCollectionView?) -> String {
        collection?.isHiddenOrHasHiddenAncestor == false ? "visible" : "hidden"
    }
    static func recordPrepare(_ collection: NSCollectionView?, milliseconds: Double) {
        record(visibility(collection) + "_flow_prepare", milliseconds: milliseconds)
    }
    static func measureInvalidation(_ collection: NSCollectionView?, _ decision: () -> Bool) -> Bool {
        let result = decision()
        record(visibility(collection) + "_flow_bounds_query")
        if result { record(visibility(collection) + "_flow_bounds_invalidation") }
        return result
    }
    static func measureGlassUpdate(_ update: () -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        update()
        record("native_glass_radius_set", milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    static func recordPaneAction(_ pane: String, sender: Any?) {
        guard active else { return }
        record("native_" + pane + "_action")
        var sample: [String: Any] = ["pane": pane, "sender": sender.map { String(describing: type(of: $0)) } ?? "nil",
                                     "uptime": ProcessInfo.processInfo.systemUptime]
        if let event = NSApp.currentEvent {
            sample["event_type"] = event.type.rawValue
            sample["event_timestamp"] = event.timestamp
        }
        paneActions.append(sample)
    }
    static func recordInput(_ event: NSEvent) {
        guard active else { return }
        record("local_input_event")
        inputEvents.append(["type": event.type.rawValue, "timestamp": event.timestamp,
                            "window_number": event.windowNumber,
                            "location_x": event.locationInWindow.x, "location_y": event.locationInWindow.y])
    }
}

private struct ProbeFixture: Decodable {
    let directory: String
    let files: [String]
    let widths: [Double]
    let toggleCount: Int
    let scrollSeconds: Double
    let startupDelay: Double
    let label: String
}

private struct ProbeError: Error, CustomStringConvertible { let description: String }

@main @MainActor
final class WindowAnimationBenchmark: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController!
    private var split: NSSplitViewController!
    private var scroll: NSScrollView!
    private var collection: NSCollectionView!
    private var displayLink: CADisplayLink?
    private var heartbeat: Timer?
    private var resizeObserver: NSObjectProtocol?
    private var liveResizeObservers: [NSObjectProtocol] = []
    private var inputMonitor: Any?
    private let signposter = OSSignposter(subsystem: "com.codex.HERMES.WindowProbe", category: "animation")
    private var fixture: ProbeFixture!
    private var phase: String?
    private var phaseStart = 0.0
    private var phaseCPU = 0.0
    private var phaseProcessCPU: clock_t = 0
    private var signpostState: OSSignpostIntervalState?
    private var lastHeartbeat = 0.0
    private var lastCallback = 0.0
    private var heartbeatGaps: [Double] = []
    private var callbackGaps: [Double] = []
    private var widthSamples: [[String: Any]] = []
    private var lastResize = 0.0
    private var resizeCount = 0
    private var scrollAnimationStart: Double?
    private var scrollAnimationDuration = 0.0
    private var scrollSubmissions: [Double] = []
    private var unreadyCallbacks = 0
    private var previousColumns: Int?
    private var columnChanges = 0
    private var pageSizes: [ObjectIdentifier: NSSize] = [:]
    private var transitionCompletionTime: Double?
    private var initialGeometry: [CGFloat] = []
    private var initialCollapsed: [Bool] = []
    private var invalidReasons: [String] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = WindowAnimationBenchmark()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Window benchmark failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw ProbeError(description: "Expected one fixture manifest path") }
        fixture = try JSONDecoder().decode(ProbeFixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let domain = ProcessInfo.processInfo.processName
        guard Bundle.main.bundleIdentifier == nil, domain.hasPrefix("HermesWindowAnimationProbe-") else {
            throw ProbeError(description: "The benchmark must use its unique unbundled defaults domain")
        }
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain); stopSampling(); controller?.window?.orderOut(nil) }
        defaults.set(fixture.directory, forKey: "DownloadOutputFolderPath.v1")
        defaults.set(true, forKey: "HERMESInspectorVisible.v1")
        let urls = fixture.files.map { URL(fileURLWithPath: $0) }
        let model = ImporterModel(refreshOnInit: false)
        model.stopMonitoringLocalFiles()
        model.downloadPhotos = urls.filter(FileSystemUtilities.isImage)
        model.downloadVideos = urls.filter(FileSystemUtilities.isVideo)
        model.downloadFilter = .notComposed
        model.downloadFilter = .all
        guard model.visibleDownloadItems.count == urls.count else {
            throw ProbeError(description: "The read-only manifest did not create one visible grid item per media file")
        }
        model.selection = .downloads
        controller = MainWindowController(model: model)
        controller.requestTermination = { exit(130) }
        controller.showWindow(nil)
        guard let window = controller.window,
              let actualSplit = window.contentViewController as? NSSplitViewController else {
            throw ProbeError(description: "Production MainWindowController did not create its split view")
        }
        split = actualSplit
        window.title = "HERMES · 完整窗口性能验证 · \(fixture.label)"
        window.setContentSize(NSSize(width: fixture.widths[0], height: 800))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let selected = model.visibleDownloadItems.first { model.selectedDownloadItemIDs = [selected.id] }
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < readyDeadline {
            if let candidate = descendants(split.splitViewItems[1].viewController.view)
                .compactMap({ $0 as? NSCollectionView })
                .first(where: { !$0.isHiddenOrHasHiddenAncestor && $0.enclosingScrollView != nil
                    && $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) == urls.count
                    && !$0.visibleItems().isEmpty }) {
                collection = candidate
                scroll = candidate.enclosingScrollView
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard collection != nil, scroll != nil else {
            throw ProbeError(description: "The production downloads collection is not visible")
        }
        startSampling()
        emit(["event": "ready", "label": fixture.label, "pid": ProcessInfo.processInfo.processIdentifier,
              "media_count": urls.count, "production_window": true, "optimized_build": true,
              "measurement": "Main-thread CPU and callback gaps; these are not display/GPU FPS"])
        if fixture.startupDelay > 0 { try await Task.sleep(for: .seconds(fixture.startupDelay)) }

        for requestedWidth in fixture.widths {
            // Preset sizes are outside measured phases. Pane actions below never
            // replace the system animation with a manual frame mutation.
            window.setContentSize(NSSize(width: requestedWidth, height: 800))
            try await waitForSettledGeometry()
            try await Task.sleep(for: .milliseconds(500))
            for visit in ["first_visit_scroll", "revisit_scroll"] {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(100))
                beginPhase("\(visit)_\(Int(requestedWidth))")
                scrollAnimationDuration = fixture.scrollSeconds
                scrollAnimationStart = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .seconds(fixture.scrollSeconds))
                scrollAnimationStart = nil
                finishPhase(requestedWidth: requestedWidth)
                try await Task.sleep(for: .milliseconds(350))
            }
            for identifier in [NSToolbarItem.Identifier.toggleInspector, .toggleSidebar] {
                guard let item = window.toolbar?.items.first(where: { $0.itemIdentifier == identifier }),
                      let action = item.action else {
                    throw ProbeError(description: "Missing production native toolbar action: \(identifier.rawValue)")
                }
                let paneIndex = identifier == .toggleInspector ? 2 : 0
                for toggle in 0..<fixture.toggleCount {
                    let expectedCollapsed = !split.splitViewItems[paneIndex].isCollapsed
                    beginPhase("\(identifier.rawValue)_\(toggle + 1)_\(Int(requestedWidth))")
                    guard NSApp.sendAction(action, to: item.target, from: item) else {
                        throw ProbeError(description: "The production responder chain rejected a pane action")
                    }
                    try await waitForSettledGeometry(expectedPane: paneIndex, collapsed: expectedCollapsed)
                    finishPhase(requestedWidth: requestedWidth)
                }
            }
        }
    }

    private func startSampling() {
        displayLink = controller.window!.contentView!.displayLink(target: self, selector: #selector(displayTick(_:)))
        displayLink?.add(to: .main, forMode: .common)
        heartbeat = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase != nil else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.lastHeartbeat > 0 { self.heartbeatGaps.append((now - self.lastHeartbeat) * 1000) }
                self.lastHeartbeat = now
            }
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
        resizeObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
            object: split.splitView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastResize = ProcessInfo.processInfo.systemUptime
                if self.phase != nil { self.resizeCount += 1 }
            }
        }
        for (notification, key) in [(NSWindow.willStartLiveResizeNotification, "window_live_resize_start"),
                                    (NSWindow.didEndLiveResizeNotification, "window_live_resize_end")] {
            liveResizeObservers.append(NotificationCenter.default.addObserver(forName: notification,
                object: controller.window, queue: .main) { _ in
                    MainActor.assumeIsolated { WindowProbeCounters.record(key) }
                })
        }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged]) { event in
                MainActor.assumeIsolated { WindowProbeCounters.recordInput(event) }
                return event
            }
    }

    private func stopSampling() {
        displayLink?.invalidate()
        heartbeat?.invalidate()
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        for observer in liveResizeObservers { NotificationCenter.default.removeObserver(observer) }
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        WindowProbeCounters.active = false
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard phase != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { WindowProbeCounters.record("probe_display_link_sampling",
            milliseconds: (ProcessInfo.processInfo.systemUptime - now) * 1000) }
        if lastCallback > 0 { callbackGaps.append((now - lastCallback) * 1000) }
        lastCallback = now
        if let started = scrollAnimationStart {
            let changedGeometry = zip(initialGeometry, geometry()).contains { abs($0.0 - $0.1) > 0.25 }
            if changedGeometry && !invalidReasons.contains("geometry_changed_during_scroll") {
                invalidReasons.append("geometry_changed_during_scroll")
            }
            if initialCollapsed != split.splitViewItems.map(\.isCollapsed)
                && !invalidReasons.contains("pane_collapsed_state_changed_during_scroll") {
                invalidReasons.append("pane_collapsed_state_changed_during_scroll")
            }
            let fraction = min(1, max(0, (now - started) / scrollAnimationDuration))
            let progress = fraction < 0.5 ? fraction * 2 : (1 - fraction) * 2
            let maximum = max(0, collection.bounds.height - scroll.contentView.bounds.height)
            let start = ProcessInfo.processInfo.systemUptime
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * progress))
            scroll.reflectScrolledClipView(scroll.contentView)
            // No forced display/flush: retain AppKit's normal layout and CA
            // transaction scheduling. This is the scroll submission cost only.
            scrollSubmissions.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let visible = collection.visibleItems()
        let pages = split.splitViewItems[1].viewController.children.map(\.view)
        for page in pages {
            let identity = ObjectIdentifier(page)
            if let previous = pageSizes[identity], previous != page.frame.size {
                let status = page.isHiddenOrHasHiddenAncestor ? "hidden" : "visible"
                WindowProbeCounters.record(status + (page.window == nil ? "_detached" : "_attached") + "_page_size_change")
            }
            pageSizes[identity] = page.frame.size
        }
        if visible.contains(where: { $0.imageView?.image == nil || ($0.imageView?.alphaValue ?? 0) < 1 }) {
            unreadyCallbacks += 1
        }
        let columns = visibleColumns(visible)
        if let columns, let previousColumns, columns != previousColumns { columnChanges += 1 }
        if let columns { previousColumns = columns }
        let paneSamples: [[String: Any]] = split.splitViewItems.map { item in
            let view = item.viewController.view
            var sample: [String: Any] = ["x": view.frame.minX, "width": view.frame.width, "collapsed": item.isCollapsed]
            if let presented = view.layer?.presentation() {
                sample["ca_presentation_x"] = presented.frame.minX
                sample["ca_presentation_width"] = presented.frame.width
            }
            return sample
        }
        widthSamples.append(["elapsed_ms": (now - phaseStart) * 1000,
                             "callback_gap_ms": callbackGaps.last ?? 0,
                             "display_link_timestamp": link.timestamp,
                             "display_link_target_timestamp": link.targetTimestamp,
                             "window_width": controller.window!.frame.width,
                             "viewport_width": scroll.contentView.bounds.width,
                             "viewport_height": scroll.contentView.bounds.height,
                             "document_width": collection.bounds.width,
                             "document_height": collection.bounds.height,
                             "panes": paneSamples, "visible_row_columns": columns ?? -1,
                             "attached_pages": pages.filter { $0.window != nil }.count,
                             "window_live_resize": controller.window!.inLiveResize])
    }

    private func beginPhase(_ name: String) {
        phase = name
        phaseStart = ProcessInfo.processInfo.systemUptime
        phaseCPU = mainThreadCPUSeconds() ?? 0
        phaseProcessCPU = clock()
        lastHeartbeat = phaseStart
        lastCallback = 0
        heartbeatGaps = []; callbackGaps = []; widthSamples = []; scrollSubmissions = []
        resizeCount = 0; unreadyCallbacks = 0; previousColumns = nil; columnChanges = 0
        transitionCompletionTime = nil
        initialGeometry = geometry()
        initialCollapsed = split.splitViewItems.map(\.isCollapsed)
        invalidReasons = []
        pageSizes = Dictionary(uniqueKeysWithValues: split.splitViewItems[1].viewController.children.map {
            (ObjectIdentifier($0.view), $0.view.frame.size)
        })
        WindowProbeCounters.reset()
        signpostState = signposter.beginInterval("WindowProbePhase", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
    }

    private func finishPhase(requestedWidth: Double) {
        guard let phase else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !WindowProbeCounters.inputEvents.isEmpty {
            invalidReasons.append("local_input_during_automated_phase")
        }
        if phase.contains("scroll"), !WindowProbeCounters.paneActions.isEmpty {
            invalidReasons.append("unexpected_native_pane_action_during_scroll")
        }
        if WindowProbeCounters.counts["window_live_resize_start", default: 0] > 0 {
            invalidReasons.append("live_resize_during_automated_phase")
        }
        if let signpostState { signposter.endInterval("WindowProbePhase", signpostState) }
        WindowProbeCounters.active = false
        emit(["event": "phase", "label": fixture.label, "phase": phase,
              "requested_window_width": requestedWidth, "window_width": controller.window!.frame.width,
              "elapsed_ms": (now - phaseStart) * 1000,
              "last_native_resize_elapsed_ms": max(0, lastResize - phaseStart) * 1000,
              "native_transition_completion_observed_ms": transitionCompletionTime.map { ($0 - phaseStart) * 1000 } ?? -1,
              "main_thread_cpu_ms": max(0, (mainThreadCPUSeconds() ?? phaseCPU) - phaseCPU) * 1000,
              "process_cpu_ms": Double(clock() - phaseProcessCPU) / Double(CLOCKS_PER_SEC) * 1000,
              "main_run_loop_5ms_timer_gaps": gapSummary(heartbeatGaps),
              "display_link_callback_gaps": gapSummary(callbackGaps),
              "scroll_submission_ms": gapSummary(scrollSubmissions),
              "resize_notifications": resizeCount, "callbacks_with_unready_thumbnail": unreadyCallbacks,
              "visible_row_column_changes": columnChanges,
              "valid": invalidReasons.isEmpty, "invalid_reasons": invalidReasons,
              "synchronous_work_counts": WindowProbeCounters.counts,
              "native_pane_action_samples": WindowProbeCounters.paneActions,
              "local_input_event_samples": WindowProbeCounters.inputEvents,
              "synchronous_work_costs": WindowProbeCounters.costs, "width_samples": widthSamples])
        self.phase = nil
    }

    private func waitForSettledGeometry(expectedPane: Int? = nil, collapsed: Bool? = nil) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        var previous = geometry()
        var stableSince = start
        while ProcessInfo.processInfo.systemUptime - start < 5 {
            try await Task.sleep(for: .milliseconds(20))
            let now = ProcessInfo.processInfo.systemUptime
            let current = geometry()
            if zip(previous, current).contains(where: { abs($0.0 - $0.1) > 0.25 }) { stableSince = now }
            previous = current
            let expectedMatches = expectedPane.map { split.splitViewItems[$0].isCollapsed == collapsed! } ?? true
            if expectedPane != nil, expectedMatches, !controller.inspectorController.isPaneTransitioning,
               transitionCompletionTime == nil { transitionCompletionTime = now }
            let presentationSettled = split.splitViewItems.allSatisfy { item in
                guard let layer = item.viewController.view.layer, let presented = layer.presentation() else { return true }
                return abs(presented.bounds.width - layer.bounds.width) < 0.25
                    && abs(presented.position.x - layer.position.x) < 0.25
            }
            if expectedMatches, !controller.inspectorController.isPaneTransitioning, presentationSettled,
               now - stableSince >= 0.08, now - lastResize >= 0.08 { return }
        }
        throw ProbeError(description: "Native pane geometry/presentation did not settle within five seconds")
    }

    private func geometry() -> [CGFloat] {
        [controller.window!.frame.width, controller.window!.frame.height]
            + split.splitViewItems.flatMap { [$0.viewController.view.frame.minX, $0.viewController.view.frame.width] }
    }

    private func visibleColumns(_ items: [NSCollectionViewItem]) -> Int? {
        let frames = items.compactMap { item -> NSRect? in
            guard let path = collection.indexPath(for: item) else { return nil }
            return collection.collectionViewLayout?.layoutAttributesForItem(at: path)?.frame
        }
        let rows = Dictionary(grouping: frames, by: { Int(($0.minY * 2).rounded()) })
        return rows.values.map(\.count).max()
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func gapSummary(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * fraction)]
        }
        return ["samples": sorted.count, "p50_ms": percentile(0.50), "p95_ms": percentile(0.95),
                "p99_ms": percentile(0.99), "max_ms": sorted.last ?? 0,
                "over_16_7_ms": values.filter { $0 > 16.7 }.count, "over_33_3_ms": values.filter { $0 > 33.3 }.count]
    }

    private func mainThreadCPUSeconds() -> Double? {
        var information = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Double(information.user_time.seconds) + Double(information.system_time.seconds)
            + Double(information.user_time.microseconds + information.system_time.microseconds) / 1_000_000
    }

    private func emit(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        print(json)
        fflush(stdout)
    }
}
