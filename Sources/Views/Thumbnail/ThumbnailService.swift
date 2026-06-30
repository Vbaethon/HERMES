import AppKit
import AVFoundation
import CoreMedia

enum ThumbnailCollectionAnimation {
    @MainActor
    static func perform(_ updates: () -> Void) {
        updates()
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
    static let thumbnailMaxPixelSize = 512

    static func sectionInset(additionalBottomInset: CGFloat) -> NSEdgeInsets {
        var inset = sectionInset
        inset.bottom = max(inset.bottom, additionalBottomInset)
        return inset
    }

    @MainActor
    static func makeLayout(sectionInset: NSEdgeInsets = ThumbnailCollectionStyle.sectionInset) -> NSCollectionViewFlowLayout {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = itemSize
        layout.minimumInteritemSpacing = itemSpacing
        layout.minimumLineSpacing = itemSpacing
        layout.sectionInset = sectionInset
        return layout
    }

    @MainActor
    static func prepare(_ collectionView: NSCollectionView, sectionInset: NSEdgeInsets = ThumbnailCollectionStyle.sectionInset) {
        collectionView.collectionViewLayout = makeLayout(sectionInset: sectionInset)
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.register(ThumbnailCollectionItem.self, forItemWithIdentifier: ThumbnailCollectionItem.identifier)
    }

    @MainActor
    static func prepare(_ scrollView: NSScrollView, documentView: NSCollectionView) {
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
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
    static let height: CGFloat = 10
    static let horizontalPadding: CGFloat = 0
    static let inset: CGFloat = 2
    static let font = NSFont.systemFont(ofSize: 8, weight: .regular)
    static let textColor = NSColor.white

    static func size(for text: String) -> NSSize {
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
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
    let cache: NSCache<NSURL, NSString> = {
        let cache = NSCache<NSURL, NSString>()
        cache.countLimit = 600
        return cache
    }()
}

let thumbnailDurationCache = ThumbnailDurationCache()

func loadVideoDurationText(from url: URL) async -> String? {
    let cacheKey = url.standardizedFileURL as NSURL
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
