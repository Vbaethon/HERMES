import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum ThumbnailCollectionAnimation {
    @MainActor
    static func perform(_ updates: () -> Void) {
        updates()
    }
}

final class GlassClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let docView = documentView, docView.isFlipped,
              let window = window else { return result }
        let toolbarHeight = window.frame.height - window.contentLayoutRect.height
        guard toolbarHeight > 0, proposedBounds.origin.y < 0 else { return result }
        let clampedY = max(proposedBounds.origin.y, -toolbarHeight)
        if result.origin.y != clampedY {
            result.origin.y = clampedY
        }
        return result
    }
}

enum ThumbnailCollectionStyle {
    static let cellSide: CGFloat = 148
    static let itemSize = NSSize(width: cellSide, height: cellSide)
    static let itemSpacing: CGFloat = 20
    static let sectionInset = NSEdgeInsets(top: 22, left: 44, bottom: 24, right: 44)
    static let imageCornerRadius: CGFloat = 6
    static let selectionBorderWidth: CGFloat = 4
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
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        let glassClipView = GlassClipView()
        glassClipView.postsBoundsChangedNotifications = true
        scrollView.contentView = glassClipView
        scrollView.hasVerticalScroller = true
        scrollView.documentView = documentView
    }

    static func insetsEqual(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top
            && lhs.left == rhs.left
            && lhs.bottom == rhs.bottom
            && lhs.right == rhs.right
    }

    @MainActor
    static func updateGlassExtension(for scrollView: NSScrollView) {
        guard let window = scrollView.window else { return }
        let toolbarHeight = window.frame.height - window.contentLayoutRect.height
        guard toolbarHeight > 0 else { return }
        if scrollView.contentView.contentInsets.top != toolbarHeight {
            scrollView.contentView.contentInsets.top = toolbarHeight
        }
        if scrollView.scrollerInsets.top != toolbarHeight {
            scrollView.scrollerInsets.top = toolbarHeight
        }
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

@MainActor
enum ThumbnailCollectionSelection {
    static func indexPaths<Item: Identifiable>(
        for items: [Item],
        selectedIDs: Set<Item.ID>
    ) -> Set<IndexPath> where Item.ID: Hashable {
        Set(items.enumerated().compactMap { index, item in
            selectedIDs.contains(item.id) ? IndexPath(item: index, section: 0) : nil
        })
    }

    static func apply(_ indexPaths: Set<IndexPath>, to collectionView: NSCollectionView) {
        collectionView.deselectItems(at: collectionView.selectionIndexPaths.subtracting(indexPaths))
        collectionView.selectItems(at: indexPaths, scrollPosition: [])
        for visibleItem in collectionView.visibleItems() {
            if let indexPath = collectionView.indexPath(for: visibleItem),
               let item = visibleItem as? ThumbnailCollectionItem {
                item.setSelectedAppearance(indexPaths.contains(indexPath))
            }
        }
    }

    static func selectedIDs<Item: Identifiable>(
        in collectionView: NSCollectionView,
        items: [Item]
    ) -> Set<Item.ID> where Item.ID: Hashable {
        Set(collectionView.selectionIndexPaths.compactMap { indexPath in
            items.indices.contains(indexPath.item) ? items[indexPath.item].id : nil
        })
    }

    static func selectClickedItemForContextMenu(
        in collectionView: NSCollectionView,
        event: NSEvent,
        itemCount: Int,
        syncSelection: () -> Void,
        applySelection: () -> Void
    ) -> Bool {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        guard let clickedIndexPath = collectionView.indexPathForItem(at: point),
              clickedIndexPath.item < itemCount else {
            return false
        }

        if !collectionView.selectionIndexPaths.contains(clickedIndexPath) {
            collectionView.deselectItems(at: collectionView.selectionIndexPaths)
            collectionView.selectItems(at: [clickedIndexPath], scrollPosition: [])
            syncSelection()
            applySelection()
        }
        return true
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

final class ThumbnailScrollPositionController: @unchecked Sendable {
    private weak var scrollView: NSScrollView?
    private var latestReadOffsetY: CGFloat?
    private var writeScrollOffset: ((CGFloat) -> Void)?
    private var scrollObserver: NSObjectProtocol?
    private var latestTopOriginY: CGFloat?
    private var latestScrollOffsetY: CGFloat?
    private var pendingScrollCommit: DispatchWorkItem?
    private var isRestoring = false
    private var isActive = true

    deinit {
        stopObserving()
        pendingScrollCommit?.cancel()
    }

    @MainActor
    func attach(scrollView: NSScrollView, initialOffset: CGFloat, writeScrollOffset: @escaping (CGFloat) -> Void, isActive: Bool) {
        self.scrollView = scrollView
        self.latestReadOffsetY = initialOffset
        self.writeScrollOffset = writeScrollOffset
        self.latestScrollOffsetY = initialOffset
        self.isActive = isActive
        startObserving(scrollView)
        refreshTopOrigin(requiresLayout: true)
        restoreSavedPosition()
    }

    @MainActor
    func update(externalOffsetY: CGFloat, writeScrollOffset: @escaping (CGFloat) -> Void) {
        self.latestReadOffsetY = externalOffsetY
        self.writeScrollOffset = writeScrollOffset
        if abs((latestScrollOffsetY ?? externalOffsetY) - externalOffsetY) > 0.5 {
            latestScrollOffsetY = externalOffsetY
        }
        refreshTopOrigin(requiresLayout: true)
    }

    @MainActor
    func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else { return }
        if !isActive {
            commitCurrentPositionIfPossible()
            pendingScrollCommit?.cancel()
        }
        self.isActive = isActive
        if isActive {
            restoreSavedPosition()
        }
    }

    @MainActor
    func currentOriginY() -> CGFloat {
        guard let scrollView else {
            return absoluteOriginY(for: latestScrollOffsetY ?? latestReadOffsetY ?? 0)
        }
        let currentOriginY = scrollView.contentView.bounds.origin.y
        commit(offsetY: scrollOffsetY(for: currentOriginY))
        return currentOriginY
    }

    @MainActor
    func restore() {
        let offsetY = latestScrollOffsetY ?? latestReadOffsetY ?? 0
        restore(to: absoluteOriginY(for: offsetY))
    }

    @MainActor
    func restore(to originY: CGFloat) {
        restore(to: originY, animated: false)
    }

    @MainActor
    func scrollToDefaultStart(collectionView: NSCollectionView) {
        guard let scrollView else { return }
        ThumbnailCollectionStyle.updateGlassExtension(for: scrollView)
        collectionView.collectionViewLayout?.invalidateLayout()
        scrollView.layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        restoreToInitialTop()
    }

    @MainActor
    func restoreToInitialTop() {
        guard let topOriginY = refreshTopOrigin(requiresLayout: true) else { return }
        restoreImmediately(to: topOriginY)
    }

    @MainActor
    private func restore(to originY: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let currentBounds = scrollView.contentView.bounds
        let requestedBounds = NSRect(
            x: currentBounds.origin.x,
            y: originY,
            width: currentBounds.width,
            height: currentBounds.height
        )
        let constrainedOrigin = scrollView.contentView.constrainBoundsRect(requestedBounds).origin
        guard abs(currentBounds.origin.y - constrainedOrigin.y) > 0.5 else { return }
        isRestoring = true
        let targetPoint = NSPoint(x: currentBounds.origin.x, y: constrainedOrigin.y)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(targetPoint)
            } completionHandler: { [weak self, weak scrollView] in
                Task { @MainActor [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    self.commit(originY: constrainedOrigin.y)
                    self.isRestoring = false
                }
            }
        } else {
            scrollView.contentView.scroll(to: targetPoint)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            commit(originY: constrainedOrigin.y)
            isRestoring = false
        }
    }

    @MainActor
    private func restoreImmediately(to originY: CGFloat) {
        guard let scrollView else { return }
        let currentBounds = scrollView.contentView.bounds
        let requestedBounds = NSRect(
            x: currentBounds.origin.x,
            y: originY,
            width: currentBounds.width,
            height: currentBounds.height
        )
        let constrainedOrigin = scrollView.contentView.constrainBoundsRect(requestedBounds).origin
        guard abs(currentBounds.origin.y - constrainedOrigin.y) > 0.5 else { return }
        isRestoring = true
        scrollView.contentView.scroll(to: NSPoint(x: currentBounds.origin.x, y: constrainedOrigin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        commit(originY: constrainedOrigin.y)
        isRestoring = false
    }

    @MainActor
    func save() {
        guard isActive,
              let scrollView,
              scrollView.window != nil,
              !isRestoring else { return }
        refreshTopOrigin(requiresLayout: false)
        thumbnailScrollActivity.markScrolling()
        latestScrollOffsetY = scrollOffsetY(for: scrollView.contentView.bounds.origin.y)
        scheduleScrollCommit()
    }

    @MainActor
    private func scheduleScrollCommit() {
        pendingScrollCommit?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isRestoring, let latestScrollOffsetY = self.latestScrollOffsetY else { return }
                self.writeScrollOffset?(latestScrollOffsetY)
            }
        }
        pendingScrollCommit = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    @MainActor
    private func commit(originY: CGFloat) {
        pendingScrollCommit?.cancel()
        commit(offsetY: scrollOffsetY(for: originY))
    }

    @MainActor
    private func commit(offsetY: CGFloat) {
        pendingScrollCommit?.cancel()
        latestScrollOffsetY = offsetY
        writeScrollOffset?(offsetY)
    }

    @MainActor
    @discardableResult
    private func refreshTopOrigin(requiresLayout: Bool) -> CGFloat? {
        guard let scrollView, scrollView.window != nil else { return latestTopOriginY }
        ThumbnailCollectionStyle.updateGlassExtension(for: scrollView)
        if requiresLayout {
            scrollView.layoutSubtreeIfNeeded()
            scrollView.documentView?.layoutSubtreeIfNeeded()
        }
        latestTopOriginY = constrainedOriginY(for: topProbeOriginY(), in: scrollView)
        return latestTopOriginY
    }

    @MainActor
    private func restoreSavedPosition() {
        let savedOffsetY = latestScrollOffsetY ?? latestReadOffsetY ?? 0
        restoreImmediately(to: absoluteOriginY(for: savedOffsetY))
    }

    @MainActor
    private func commitCurrentPositionIfPossible() {
        guard let scrollView,
              scrollView.window != nil,
              !isRestoring else { return }
        refreshTopOrigin(requiresLayout: false)
        commit(originY: scrollView.contentView.bounds.origin.y)
    }

    @MainActor
    private func startObserving(_ scrollView: NSScrollView) {
        stopObserving()
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.save()
            }
        }
    }

    private func stopObserving() {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        scrollObserver = nil
    }

    @MainActor
    private func absoluteOriginY(for offsetY: CGFloat) -> CGFloat {
        let topOriginY = refreshTopOrigin(requiresLayout: false) ?? latestTopOriginY ?? 0
        if scrollView?.documentView?.isFlipped == false {
            return topOriginY - max(0, offsetY)
        }
        return topOriginY + max(0, offsetY)
    }

    @MainActor
    private func scrollOffsetY(for originY: CGFloat) -> CGFloat {
        let topOriginY = refreshTopOrigin(requiresLayout: false) ?? latestTopOriginY ?? 0
        if scrollView?.documentView?.isFlipped == false {
            return max(0, topOriginY - originY)
        }
        return max(0, originY - topOriginY)
    }

    @MainActor
    private func topProbeOriginY() -> CGFloat {
        if scrollView?.documentView?.isFlipped == false {
            return CGFloat.greatestFiniteMagnitude / 2
        }
        return -CGFloat.greatestFiniteMagnitude / 2
    }

    @MainActor
    private func constrainedOriginY(for originY: CGFloat, in scrollView: NSScrollView) -> CGFloat {
        let currentBounds = scrollView.contentView.bounds
        let requestedBounds = NSRect(
            x: currentBounds.origin.x,
            y: originY,
            width: currentBounds.width,
            height: currentBounds.height
        )
        return scrollView.contentView.constrainBoundsRect(requestedBounds).origin.y
    }
}

final class ThumbnailImageCache: @unchecked Sendable {
    let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 3_000
        cache.totalCostLimit = 512 * 1024 * 1024
        return cache
    }()

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url.standardizedFileURL as NSURL)
    }

    func store(_ image: NSImage, for url: URL) {
        let pixelSize = image.pixelSize
        let cost = max(1, Int(pixelSize.width * pixelSize.height * 4))
        cache.setObject(image, forKey: url.standardizedFileURL as NSURL, cost: cost)
    }

    func remove(_ url: URL) {
        cache.removeObject(forKey: url.standardizedFileURL as NSURL)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

let thumbnailCache = ThumbnailImageCache()

extension NSImage {
    var pixelSize: NSSize {
        if let representation = representations.first {
            return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return size
    }
}

enum ThumbnailDiskCache {
    private static let folderName = "HERMES/ThumbnailCache"
    private static let cacheFormatVersion = "v8-jpg"

    private static var cacheFolder: URL? {
        folder(named: folderName)
    }

    private static func folder(named name: String) -> URL? {
        guard let cachesFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return cachesFolder.appendingPathComponent(name, isDirectory: true)
    }

    static func image(for url: URL, maxPixelSize: Int) -> NSImage? {
        guard let fileURL = fileURL(for: url, maxPixelSize: maxPixelSize),
              let image = image(at: fileURL, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return image
    }

    static func store(_ image: NSImage, for url: URL, maxPixelSize: Int) {
        guard let fileURL = fileURL(for: url, maxPixelSize: maxPixelSize),
              let folder = cacheFolder else {
            return
        }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return
        }

        let temporaryURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("tmp.jpg")

        try? FileManager.default.removeItem(at: temporaryURL)

        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return
        }

        let properties: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: 0.86
        ] as CFDictionary

        let jpegImage = ImporterModel.opaqueSRGBImageForJPEG(from: cgImage) ?? cgImage
        CGImageDestinationAddImage(destination, jpegImage, properties)

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }

        try? FileManager.default.removeItem(at: fileURL)

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

    static func removeAll() {
        if let cacheFolder {
            try? FileManager.default.removeItem(at: cacheFolder)
        }
    }

    private static func image(at fileURL: URL, maxPixelSize: Int) -> NSImage? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, thumbnailSourceOptions()) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailCreateOptions(maxPixelSize: maxPixelSize)
        ) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        let displayImage = ImporterModel.opaqueSRGBImageForJPEG(from: cgImage) ?? cgImage
        return NSImage(
            cgImage: displayImage,
            size: NSSize(width: displayImage.width, height: displayImage.height)
        )
    }

    private static func fileURL(for url: URL, maxPixelSize: Int, in folder: URL? = cacheFolder) -> URL? {
        guard let folder else { return nil }
        let standardizedURL = url.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedTime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = values?.fileSize ?? 0
        let rawKey = "\(cacheFormatVersion)|\(standardizedURL.path)|\(modifiedTime)|\(fileSize)|\(maxPixelSize)"
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
        return folder.appendingPathComponent(fileName, isDirectory: false)
    }
}

actor ThumbnailLoadLimiter {
    private static let maxConcurrentLoads = 3
    private var activeLoads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if activeLoads < Self.maxConcurrentLoads {
            activeLoads += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        activeLoads += 1
    }

    func release() {
        activeLoads = max(0, activeLoads - 1)
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        }
    }
}

let thumbnailLoadLimiter = ThumbnailLoadLimiter()

final class ThumbnailScrollActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var scrolling = false
    private var pendingIdleWorkItem: DispatchWorkItem?

    func markScrolling() {
        lock.lock()
        generation += 1
        let currentGeneration = generation
        scrolling = true
        pendingIdleWorkItem?.cancel()
        lock.unlock()

        let workItem = DispatchWorkItem { [weak self] in
            self?.markIdle(ifGeneration: currentGeneration)
        }
        lock.lock()
        pendingIdleWorkItem = workItem
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    func waitUntilIdle(maxWaitMilliseconds: Int = 240) async {
        var waitedMilliseconds = 0
        while isScrolling, waitedMilliseconds < maxWaitMilliseconds {
            try? await Task.sleep(for: .milliseconds(40))
            waitedMilliseconds += 40
        }
    }

    var isScrolling: Bool {
        lock.lock()
        let value = scrolling
        lock.unlock()
        return value
    }

    private func markIdle(ifGeneration expectedGeneration: Int) {
        lock.lock()
        if generation == expectedGeneration {
            scrolling = false
        }
        lock.unlock()
    }
}


let thumbnailScrollActivity = ThumbnailScrollActivity()

final class ThumbnailDurationCache: @unchecked Sendable {
    let cache: NSCache<NSURL, NSString> = {
        let cache = NSCache<NSURL, NSString>()
        cache.countLimit = 600
        return cache
    }()
}

let thumbnailDurationCache = ThumbnailDurationCache()

final class ThumbnailFailureCache: @unchecked Sendable {
    private let cache: NSCache<NSURL, NSNumber> = {
        let cache = NSCache<NSURL, NSNumber>()
        cache.countLimit = 600
        return cache
    }()

    func contains(_ url: URL) -> Bool {
        cache.object(forKey: url.standardizedFileURL as NSURL) != nil
    }

    func insert(_ url: URL) {
        cache.setObject(1, forKey: url.standardizedFileURL as NSURL)
    }

    func remove(_ url: URL) {
        cache.removeObject(forKey: url.standardizedFileURL as NSURL)
    }
}

let thumbnailFailureCache = ThumbnailFailureCache()

let thumbnailDecodeDiagnosticsEnabled = false

func logThumbnailDecode(_ message: String, url: URL) {
    guard thumbnailDecodeDiagnosticsEnabled else { return }
    print("🖼️ ThumbnailDecode: \(message) | \(url.lastPathComponent) | \(url.standardizedFileURL.path)")
}

func cacheThumbnailImage(_ image: NSImage, for url: URL, maxPixelSize: Int) -> NSImage {
    thumbnailCache.store(image, for: url)
    ThumbnailDiskCache.store(image, for: url, maxPixelSize: maxPixelSize)
    return image
}

func thumbnailSourceOptions() -> CFDictionary {
    [
        kCGImageSourceShouldCache: false,
        kCGImageSourceShouldAllowFloat: false
    ] as CFDictionary
}

func thumbnailCreateOptions(maxPixelSize: Int) -> CFDictionary {
    let safeMaxPixelSize = min(maxPixelSize, 512)
    return [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: false,
        kCGImageSourceShouldAllowFloat: false,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: safeMaxPixelSize
    ] as CFDictionary
}

func loadImageThumbnail(from url: URL, maxPixelSize: Int) -> NSImage? {
    autoreleasepool {
        logThumbnailDecode("start image decode", url: url)
        guard !thumbnailFailureCache.contains(url) else {
            logThumbnailDecode("skip previously failed image decode", url: url)
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, thumbnailSourceOptions()) else {
            logThumbnailDecode("failed to create image source", url: url)
            thumbnailFailureCache.insert(url)
            return nil
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailCreateOptions(maxPixelSize: maxPixelSize)
        ) else {
            logThumbnailDecode("failed to create image thumbnail", url: url)
            thumbnailFailureCache.insert(url)
            return nil
        }
        let displayImage = ImporterModel.opaqueSRGBImageForJPEG(from: cgImage) ?? cgImage
        let image = NSImage(cgImage: displayImage, size: NSSize(width: displayImage.width, height: displayImage.height))
        logThumbnailDecode("finished image decode", url: url)
        thumbnailFailureCache.remove(url)
        return cacheThumbnailImage(image, for: url, maxPixelSize: maxPixelSize)
    }
}

func loadThumbnailImage(from url: URL, maxPixelSize: Int) async -> NSImage? {
    if let cachedImage = thumbnailCache.image(for: url) {
        return cachedImage
    }

    return await Task.detached(priority: .utility) { () -> NSImage? in
        guard !Task.isCancelled else { return nil }
        await thumbnailLoadLimiter.acquire()
        defer { Task { await thumbnailLoadLimiter.release() } }
        guard !Task.isCancelled else { return nil }

        if let diskCachedImage = ThumbnailDiskCache.image(for: url, maxPixelSize: maxPixelSize) {
            thumbnailCache.store(diskCachedImage, for: url)
            return diskCachedImage
        }

        guard !thumbnailFailureCache.contains(url) else {
            return nil
        }

        if FileSystemUtilities.isImage(url) {
            return loadImageThumbnail(from: url, maxPixelSize: maxPixelSize)
        }

        guard FileSystemUtilities.isVideo(url) else {
            return nil
        }

        logThumbnailDecode("start video decode", url: url)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard !Task.isCancelled else { return nil }
        guard let (cgImage, _) = try? await generator.image(at: .zero) else {
            logThumbnailDecode("failed to create video thumbnail", url: url)
            thumbnailFailureCache.insert(url)
            return nil
        }
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            let displayImage = ImporterModel.opaqueSRGBImageForJPEG(from: cgImage) ?? cgImage
            let image = NSImage(cgImage: displayImage, size: NSSize(width: displayImage.width, height: displayImage.height))
            thumbnailFailureCache.remove(url)
            thumbnailCache.store(image, for: url)
            ThumbnailDiskCache.store(image, for: url, maxPixelSize: maxPixelSize)
            logThumbnailDecode("finished video decode", url: url)
            return image
        }
    }.value
}

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
