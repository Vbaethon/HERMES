import AppKit
import AVFoundation
import CoreMedia

enum ThumbnailCollectionAnimation {
    // Matches the installed Photos grid's default layout-transition duration.
    // AppKit owns collection item fading and movement within this transaction.
    static let transitionDuration: TimeInterval = 0.4

    @MainActor
    static func duration(animated: Bool = true) -> TimeInterval {
        animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? transitionDuration : 0
    }

    @MainActor
    static func perform(_ updates: () -> Void) {
        updates()
    }
}

/// This grid has fixed-size items and no scrolling supplementary views. A
/// viewport translation must not invalidate every item's layout on each tick.
class ThumbnailFlowLayout: NSCollectionViewFlowLayout {
    private struct ResizeAnchor {
        let indexPath: IndexPath
        let offsetFromTop: CGFloat
        var expectedOrigin: CGFloat
    }

    private var preparedViewportSize: NSSize?
    private var resizeAnchor: ResizeAnchor?

    override func prepare() {
        super.prepare()
        preparedViewportSize = collectionView?.enclosingScrollView?.contentView.bounds.size
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        if sectionHeadersPinToVisibleBounds || sectionFootersPinToVisibleBounds {
            return super.shouldInvalidateLayout(forBoundsChange: newBounds)
        }
        // AppKit supplies the visible viewport here; collectionView.bounds is
        // the entire document and can be thousands of points taller.
        guard let preparedViewportSize else { return true }
        if preparedViewportSize == newBounds.size {
            if let anchor = resizeAnchor, abs(newBounds.minY - anchor.expectedOrigin) > 0.5 {
                resizeAnchor = nil
            }
            return false
        }
        return true
    }

    override func invalidationContext(forBoundsChange newBounds: NSRect) -> NSCollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        guard scrollDirection == .vertical, !sectionHeadersPinToVisibleBounds, !sectionFootersPinToVisibleBounds,
              let collectionView, let clipView = collectionView.enclosingScrollView?.contentView,
              let preparedViewportSize, preparedViewportSize.width != newBounds.width,
              collectionView.numberOfSections == 1, itemSize.width > 0, itemSize.height > 0,
              resizeAnchor != nil || newBounds.minY > 0 else { return context }

        if let anchor = resizeAnchor, abs(newBounds.minY - anchor.expectedOrigin) > 0.5 {
            resizeAnchor = nil
        }
        if resizeAnchor == nil {
            let oldViewport = NSRect(origin: newBounds.origin, size: preparedViewportSize)
            let first = layoutAttributesForElements(in: oldViewport)
                .filter { $0.representedElementCategory == .item && $0.frame.intersects(oldViewport) }
                .min { $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
            if let first, let path = first.indexPath {
                resizeAnchor = ResizeAnchor(indexPath: path, offsetFromTop: first.frame.minY - newBounds.minY,
                                            expectedOrigin: newBounds.minY)
            }
        }
        guard var anchor = resizeAnchor else { return context }
        let count = collectionView.numberOfItems(inSection: 0)
        guard anchor.indexPath.item < count else { resizeAnchor = nil; return context }
        let availableWidth = newBounds.width - sectionInset.left - sectionInset.right
        let columns = max(1, Int(floor((availableWidth + minimumInteritemSpacing) / (itemSize.width + minimumInteritemSpacing))))
        let rowStride = itemSize.height + minimumLineSpacing
        let desiredOrigin = sectionInset.top + CGFloat(anchor.indexPath.item / columns) * rowStride - anchor.offsetFromTop
        context.contentOffsetAdjustment.y = desiredOrigin - newBounds.minY

        // Let NSClipView apply its native boundary clamp. Remember that clamped
        // origin without replacing the item's desired offset, so widening near
        // the bottom and narrowing again restores the same item position.
        let rows = (count + columns - 1) / columns
        let contentHeight = sectionInset.top + CGFloat(rows) * rowStride - minimumLineSpacing + sectionInset.bottom
        let documentRect = clipView.documentRect
        let maxOrigin = max(documentRect.minY, documentRect.maxY + contentHeight - collectionView.bounds.height - newBounds.height)
        anchor.expectedOrigin = min(max(desiredOrigin, documentRect.minY), maxOrigin)
        resizeAnchor = anchor
        return context
    }

    override func prepare(forCollectionViewUpdates updateItems: [NSCollectionViewUpdateItem]) {
        resizeAnchor = nil
        super.prepare(forCollectionViewUpdates: updateItems)
    }
}

enum ThumbnailCollectionStyle {
    static let cellSide: CGFloat = 148
    static let itemSize = NSSize(width: cellSide, height: cellSide)
    static let itemSpacing: CGFloat = 20
    static let sectionInset = NSEdgeInsets(top: 22, left: 44, bottom: 24, right: 44)
    static let imageCornerRadius: CGFloat = 6
    static let stateRingGap: CGFloat = 1
    static let stateRingLineWidth: CGFloat = 3

    static func sectionInset(additionalBottomInset: CGFloat) -> NSEdgeInsets {
        var inset = sectionInset
        inset.bottom = max(inset.bottom, additionalBottomInset)
        return inset
    }

    @MainActor
    static func makeLayout(sectionInset: NSEdgeInsets = ThumbnailCollectionStyle.sectionInset) -> NSCollectionViewFlowLayout {
        let layout = ThumbnailFlowLayout()
        layout.scrollDirection = .vertical
        layout.itemSize = itemSize
        layout.minimumInteritemSpacing = itemSpacing
        layout.minimumLineSpacing = itemSpacing
        layout.sectionInset = sectionInset
        return layout
    }

    @MainActor
    static func prepare(_ collectionView: NSCollectionView, sectionInset: NSEdgeInsets = ThumbnailCollectionStyle.sectionInset) {
        collectionView.wantsLayer = true
        collectionView.collectionViewLayout = makeLayout(sectionInset: sectionInset)
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.register(ThumbnailCollectionItem.self, forItemWithIdentifier: ThumbnailCollectionItem.identifier)
    }

    @MainActor
    static func prepare(_ scrollView: NSScrollView, documentView: NSCollectionView) {
        // Keep the entire clipping/document hierarchy layer-backed so AppKit
        // can pan retained thumbnail layers instead of redrawing the viewport.
        scrollView.wantsLayer = true
        scrollView.contentView.wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        documentView.frame = scrollView.contentView.bounds
        documentView.autoresizingMask = [.width]
        scrollView.documentView = documentView
    }

    static func insetsEqual(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top
            && lhs.left == rhs.left
            && lhs.bottom == rhs.bottom
            && lhs.right == rhs.right
    }
}

@MainActor
enum ThumbnailBadgeStyle {
    static let height: CGFloat = 16
    static let horizontalPadding: CGFloat = 4
    static let inset: CGFloat = 6
    static let font = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let cornerRadius: CGFloat = 4

    static func font(for text: String) -> NSFont {
        text.contains(":") ? .monospacedDigitSystemFont(ofSize: 10, weight: .medium) : font
    }
    static let textColor = NSColor.white

    static func size(for text: String) -> NSSize {
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font(for: text)]).width)
        return NSSize(width: textWidth + horizontalPadding * 2, height: height)
    }
}

enum ThumbnailCollectionContextMenu {
    private static let iconSize = NSSize(width: 18, height: 18)

    @MainActor
    static func item(
        title: String,
        symbolName: String,
        target: AnyObject,
        action: Selector,
        isEnabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.isEnabled = isEnabled
        item.image = menuSymbol(symbolName)
        return item
    }

    @MainActor
    private static func menuSymbol(
        _ symbolName: String,
        pointSize: CGFloat = 15,
        weight: NSFont.Weight = .regular,
        scale: NSImage.SymbolScale = .medium
    ) -> NSImage? {
        guard let sourceImage = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        ) else {
            return nil
        }

        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: weight,
            scale: scale
        )
        let configuredImage = sourceImage.withSymbolConfiguration(configuration) ?? sourceImage
        configuredImage.size = iconSize
        configuredImage.isTemplate = true
        return configuredImage
    }
}

extension NSImage {
    var pixelSize: NSSize {
        if let representation = representations.first {
            return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return size
    }
}

final class ThumbnailDurationCache: @unchecked Sendable {
    let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 600
        return cache
    }()

    func key(for url: URL, contentVersion: TimeInterval) -> NSString {
        "\(url.standardizedFileURL.absoluteString)\n\(contentVersion.bitPattern)" as NSString
    }
}

let thumbnailDurationCache = ThumbnailDurationCache()

func loadVideoDurationText(from url: URL, contentVersion: TimeInterval = 0) async -> String? {
    let cacheKey = thumbnailDurationCache.key(for: url, contentVersion: contentVersion)
    if let cachedText = thumbnailDurationCache.cache.object(forKey: cacheKey) {
        return cachedText as String
    }

    return await Task.detached(priority: .utility) { () -> String? in
        guard FileSystemUtilities.isVideo(url) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        let roundedSeconds = Int(seconds.rounded())
        let hours = roundedSeconds / 3600
        let minutes = (roundedSeconds % 3600) / 60
        let remainingSeconds = roundedSeconds % 60
        let text: String
        if hours > 0 {
            text = String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            text = String(format: "%d:%02d", minutes, remainingSeconds)
        }
        thumbnailDurationCache.cache.setObject(text as NSString, forKey: cacheKey)
        return text
    }.value
}
