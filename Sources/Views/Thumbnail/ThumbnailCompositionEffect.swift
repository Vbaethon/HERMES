import AppKit
import SwiftUI

/// Artwork-derived color fields rendered by Apple's MeshGradient. No private Music APIs,
/// custom shader, animation dependency, or full-resolution image work in the frame loop.
final class ThumbnailCompositionEffect: NSView {
    static let minimumPlaybackDuration: Duration = .seconds(3)
    private let state = CompositionEffectState()
    private var hostingView: NSHostingView<CompositionColorField>?
    private weak var sourceImage: NSImage?
    private var revision = 0
    private var windowObserver: NSObjectProtocol?
    private var finishTask: Task<Void, Never>?
    private var playbackStartedAt: ContinuousClock.Instant?
    private(set) var isRunning = false
    var onPresentationEnded: (() -> Void)?
    var isPresenting: Bool { hostingView != nil && !isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ThumbnailCollectionStyle.imageCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(image: NSImage?, running: Bool) {
        guard running, let image else {
            stop(animated: image != nil)
            return
        }
        let wasFinishing = finishTask != nil
        finishTask?.cancel()
        finishTask = nil
        guard !isRunning || sourceImage !== image || wasFinishing else { return }
        revision += 1
        isRunning = true
        if sourceImage !== image {
            sourceImage = image
            state.colors = Self.sampleColors(from: image)
        }
        let startsPresentation = hostingView == nil
        if hostingView == nil {
            state.startedAt = Date()
            playbackStartedAt = ContinuousClock.now
            let host = NSHostingView(rootView: CompositionColorField(state: state))
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            host.setAccessibilityElement(false)
            addSubview(host)
            hostingView = host
        }
        isHidden = false
        // A refresh or interrupted exit must never flash the original image underneath.
        if startsPresentation { alphaValue = 0 }
        updateActivity()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.3
            animator().alphaValue = 1
        }
    }

    func reset() {
        let wasPresenting = isPresenting
        finishTask?.cancel()
        finishTask = nil
        playbackStartedAt = nil
        revision += 1
        isRunning = false
        state.isActive = false
        sourceImage = nil
        layer?.removeAllAnimations()
        hostingView?.removeFromSuperview()
        hostingView = nil
        alphaValue = 0
        isHidden = true
        if wasPresenting { onPresentationEnded?() }
    }

    private func stop(animated: Bool) {
        guard isRunning, finishTask == nil else { return }
        revision += 1
        let stoppedRevision = revision
        let elapsed = playbackStartedAt?.duration(to: .now) ?? .zero
        let remaining = max(.zero, Self.minimumPlaybackDuration - elapsed)
        finishTask = Task { [weak self] in
            do { try await Task.sleep(for: remaining) } catch { return }
            guard let self, !Task.isCancelled, self.revision == stoppedRevision else { return }
            self.fadeOut(animated: animated, revision: stoppedRevision)
        }
    }

    private func fadeOut(animated: Bool, revision stoppedRevision: Int) {
        isRunning = false
        // Keep the mesh moving throughout the dissolve, and stop it only when removed.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.3 : 0
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.revision == stoppedRevision else { return }
                self.reset()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        if let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateActivity() }
            }
        }
        updateActivity()
    }

    override func layout() {
        super.layout()
        updateActivity()
    }

    private func updateActivity() {
        let active = isPresenting && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
        if state.isActive != active { state.isActive = active }
    }

    isolated deinit {
        finishTask?.cancel()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    /// Downsample once per loaded thumbnail, retaining its spatial palette, including neutrals.
    static func sampleColors(from image: NSImage) -> [Color] {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return Array(repeating: Color(nsColor: .controlBackgroundColor), count: 9)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.controlBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: 3, height: 3).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: 3, height: 3), from: .zero,
                   operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return (0..<3).flatMap { y in
            (0..<3).map { x in Color(nsColor: bitmap.colorAt(x: x, y: y) ?? .controlBackgroundColor) }
        }
    }
}

private final class CompositionEffectState: ObservableObject {
    @Published var colors: [Color] = Array(repeating: .clear, count: 9)
    @Published var isActive = false
    var startedAt = Date()
}

private struct CompositionColorField: View {
    @ObservedObject var state: CompositionEffectState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !state.isActive || reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(state.startedAt)
            MeshGradient(width: 3, height: 3, points: points(at: time), colors: state.colors,
                         smoothsColors: true, colorSpace: .perceptual)
                .blur(radius: 9, opaque: true)
                .scaleEffect(1.18)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func points(at time: TimeInterval) -> [SIMD2<Float>] {
        let t = Float(time) * 0.65
        // Keep the outer edges pinned so movement never opens transparent corners.
        return [
            [0, 0], [0.5 + 0.23 * sin(t), 0], [1, 0],
            [0, 0.5 + 0.22 * cos(t * 0.83)],
            [0.5 + 0.26 * sin(t * 0.91 + 1), 0.5 + 0.26 * cos(t * 0.79)],
            [1, 0.5 + 0.22 * sin(t * 0.87 + 2)],
            [0, 1], [0.5 + 0.23 * cos(t * 0.73 + 1), 1], [1, 1]
        ]
    }
}
