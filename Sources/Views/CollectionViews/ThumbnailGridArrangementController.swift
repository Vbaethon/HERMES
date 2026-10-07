import Foundation

/// The single owner of the grid's arrangement. Data is already in chronological
/// source order. A library counts snapshots backwards from its newest column;
/// an album compacts towards its start. Refresh, filtering and insertion use
/// that same policy, with a left-aligned visible first row in either mode.
@MainActor
final class ThumbnailGridArrangementController {
    enum Flow {
        case newestEnd // Global library: earlier photos fill toward the newest end.
        case oldestStart // Album: following photos fill toward the beginning.
    }
    let flow: Flow
    private(set) var itemIDs: [String] = []
    private(set) var spec = ZoomGridSpec(level: 2)
    private(set) var viewportSize = CGSize(width: 900, height: 600)
    private(set) var metrics = ZoomMetrics()
    private var newestColumn: Int?
    private var hasPresentedItems = false
    private var trailingSpace: CGFloat = 0
    private var pending: SnapshotChange?

    init(flow: Flow = .newestEnd) { self.flow = flow }

    var count: Int { itemIDs.count }
    var contentSize: CGSize {
        CGSize(width: viewportSize.width,
               height: max(max(viewportSize.height, spec.height(count: count, width: viewportSize.width, metrics: metrics)
                               + (count > 0 ? trailingSpace : 0)), pending?.minimumHeight ?? 0))
    }
    var maximumOrigin: CGFloat { max(0, contentSize.height - viewportSize.height) }

    private struct SnapshotChange {
        let ids: [String]
        let spec: ZoomGridSpec
        let minimumHeight: CGFloat
        var followsNewest: Bool
        var origin: CGFloat
        var anchor: ZoomAnchor?
        var anchorID: String?
        var completed = false
    }

    func isAtNewest(origin: CGFloat) -> Bool {
        count > 0 && (maximumOrigin == 0 || origin >= maximumOrigin - 1)
    }

    /// Rebase the old document before AppKit captures it if an expanding
    /// snapshot needs space above it. Scroll by the same whole rows, so existing
    /// cells have identical screen coordinates throughout the transaction.
    func prepareSnapshot(_ ids: [String], origin: CGFloat) -> CGFloat? {
        precondition(ids != itemIDs)
        let previousHeight = contentSize.height
        let columns = ZoomGeometry.columns[spec.level]
        let followsNewest = pending?.followsNewest
            ?? (flow == .newestEnd && (!hasPresentedItems || count == 0 || isAtNewest(origin: origin)))
        let anchor = readingAnchor(origin: origin)
        if followsNewest && count > 0 {
            // The newest photo may sit above the viewport bottom in a short
            // library. Carry that visible space through expanding snapshots so
            // coordinate rebasing also preserves their actual screen position.
            trailingSpace = max(0, viewportSize.height + origin
                - spec.height(count: count, width: viewportSize.width, metrics: metrics))
        }
        var anchorID = anchor.map { itemIDs[$0.index] }
        if let anchor, let id = anchorID, !ids.contains(id) {
            let retained = Set(ids)
            let earlier = itemIDs[..<anchor.index].last(where: { retained.contains($0) })
            let following = itemIDs[(anchor.index + 1)...].first(where: { retained.contains($0) })
            anchorID = flow == .newestEnd ? earlier ?? following : following ?? earlier
        }
        var target = spec
        var rebasedOrigin = origin
        if ids.isEmpty {
            target.leadingSlots = 0
            target.visualAnchorIndex = 0
        } else if count == 0 {
            let lastColumn = newestColumn ?? (columns - 1)
            target.leadingSlots = flow == .newestEnd
                ? ((lastColumn - (ids.count - 1)) % columns + columns) % columns : 0
            target.visualAnchorIndex = 0
        } else {
            let leading = spec.leadingSlots + (flow == .newestEnd ? count - ids.count : 0)
            var addedRows = leading < 0 ? (-leading + columns - 1) / columns : 0
            target.leadingSlots = leading + addedRows * columns
            let proposedOrigin = followsNewest
                ? max(0, target.height(count: ids.count, width: viewportSize.width, metrics: metrics)
                      + trailingSpace - viewportSize.height)
                : origin + CGFloat(addedRows) * rowPitch
            let bounded = Self.respectingVisibleStart(target, count: ids.count, origin: proposedOrigin,
                                                     width: viewportSize.width, metrics: metrics)
            if bounded != target { target = bounded; addedRows = 0 }
            if addedRows > 0 {
                spec.leadingSlots += addedRows * columns
                rebasedOrigin += CGFloat(addedRows) * rowPitch
            }
            if itemIDs.indices.contains(spec.visualAnchorIndex),
               let index = ids.firstIndex(of: itemIDs[spec.visualAnchorIndex]) {
                target.visualAnchorIndex = index
            } else {
                target.visualAnchorIndex = min(spec.visualAnchorIndex, ids.count - 1)
            }
        }
        if count == 0 && !ids.isEmpty {
            let proposedOrigin = followsNewest
                ? max(0, target.height(count: ids.count, width: viewportSize.width, metrics: metrics)
                      + trailingSpace - viewportSize.height) : 0
            target = Self.respectingVisibleStart(target, count: ids.count, origin: proposedOrigin,
                                                 width: viewportSize.width, metrics: metrics)
        }
        pending = SnapshotChange(ids: ids, spec: target, minimumHeight: max(previousHeight, contentSize.height),
                                 followsNewest: followsNewest,
                                 origin: rebasedOrigin, anchor: anchor, anchorID: anchorID)
        return rebasedOrigin != origin ? rebasedOrigin : nil
    }

    func beginPreparedSnapshot() {
        guard let pending else { preconditionFailure("A snapshot must be prepared before it begins") }
        itemIDs = pending.ids
        spec = pending.spec
        rememberNewestColumn()
    }

    func snapshotDidComplete() { pending?.completed = true }

    /// Called only after the current diffable snapshot has reached the native
    /// collection. Bounds notifications and old completions cannot settle it.
    func finishSnapshot() -> CGFloat? {
        guard let pending, pending.completed else { return nil }
        self.pending = nil
        guard count > 0 else { trailingSpace = 0; return 0 }
        let columns = ZoomGeometry.columns[spec.level]
        let origin = pending.followsNewest ? maximumOrigin : pending.anchor.flatMap { anchor in
            guard let id = pending.anchorID, let index = itemIDs.firstIndex(of: id) else { return nil }
            let frame = spec.frame(index: index, width: viewportSize.width, metrics: metrics)
            return frame.minY + frame.height * anchor.unitPoint.y - anchor.viewportPoint.y
        } ?? pending.origin
        // Empty rows outside the viewport can be removed without moving a
        // single pixel. Keep visible leading space in a short grid; trimming
        // it after the fade with an unscrollable clip would cause a second jump.
        let rows = min(spec.leadingSlots / columns, Int(floor(max(0, origin) / rowPitch)))
        spec.leadingSlots -= rows * columns
        hasPresentedItems = true
        return pending.followsNewest ? maximumOrigin : origin - CGFloat(rows) * rowPitch
    }

    func commitZoom(_ preparedSpec: ZoomGridSpec, origin: CGFloat) {
        spec = preparedSpec
        trailingSpace = 0
        rememberNewestColumn()
        pending?.origin = origin
        pending?.followsNewest = flow == .newestEnd && isAtNewest(origin: origin)
        let anchor = readingAnchor(origin: origin)
        pending?.anchor = anchor
        pending?.anchorID = anchor.map { itemIDs[$0.index] }
    }

    /// Window size and section insets use the same newest/reading anchor as
    /// snapshots, including the left boundary when a larger viewport exposes it.
    func updateViewport(size: CGSize, metrics: ZoomMetrics, origin: CGFloat) -> CGFloat {
        let followsNewest = flow == .newestEnd && (pending?.followsNewest == true || isAtNewest(origin: origin))
        let anchor = readingAnchor(origin: origin)
        viewportSize = size
        self.metrics = metrics
        var nextOrigin = followsNewest ? maximumOrigin : anchor.map {
            let frame = spec.frame(index: $0.index, width: size.width, metrics: metrics)
            return frame.minY + frame.height * $0.unitPoint.y - $0.viewportPoint.y
        } ?? origin
        let bounded = Self.respectingVisibleStart(spec, count: count, origin: nextOrigin, width: size.width, metrics: metrics)
        if bounded != spec, pending == nil {
            spec = bounded
            rememberNewestColumn()
            nextOrigin = followsNewest ? maximumOrigin : anchor.map {
                let frame = spec.frame(index: $0.index, width: size.width, metrics: metrics)
                return max(0, frame.minY + frame.height * $0.unitPoint.y - $0.viewportPoint.y)
            } ?? origin
        }
        pending?.origin = nextOrigin
        pending?.anchor = anchor
        pending?.anchorID = anchor.map { itemIDs[$0.index] }
        return nextOrigin
    }

    private func readingAnchor(origin: CGFloat) -> ZoomAnchor? {
        let point = CGPoint(x: viewportSize.width / 2, y: origin + 1)
        return ZoomGeometry.nearestIndex(to: point, count: count, width: viewportSize.width,
                                        spec: spec, metrics: metrics).map {
            ZoomAnchor(index: $0, frame: spec.frame(index: $0, width: viewportSize.width, metrics: metrics),
                       documentPoint: point, viewportPoint: CGPoint(x: point.x, y: 1))
        }
    }

    private var rowPitch: CGFloat {
        ZoomGeometry.side(width: viewportSize.width, columns: ZoomGeometry.columns[spec.level], metrics: metrics) + metrics.gap
    }

    private func rememberNewestColumn() {
        if count > 0 { newestColumn = (spec.leadingSlots + count - 1) % ZoomGeometry.columns[spec.level] }
    }

    /// Direction is independent of the visible library boundary. Neither the
    /// global library nor an album right-aligns two photos or leaves holes at
    /// the beginning of a visible first row. Zoom uses this same boundary rule.
    nonisolated static func respectingVisibleStart(_ proposed: ZoomGridSpec, count: Int, origin: CGFloat,
                                                   width: CGFloat, metrics: ZoomMetrics) -> ZoomGridSpec {
        guard proposed.leadingSlots > 0, count > 0,
              count <= ZoomGeometry.columns[proposed.level]
                || origin < proposed.frame(index: 0, width: width, metrics: metrics).maxY + metrics.gap else {
            return proposed
        }
        return ZoomGridSpec(level: proposed.level, visualAnchorIndex: proposed.visualAnchorIndex)
    }
}
