import AppKit

struct ThumbnailGridItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let status: PairItem.Status
    let mediaKind: ThumbnailMediaKind
    let contentVersion: TimeInterval
    var unavailableMessage: String? = nil
    var resourceURLs: [URL] = []
}

@MainActor
final class ThumbnailGridController: NSObject, NSCollectionViewDelegate, NSDraggingSource {
    private enum Section {
        static let main = "main"
    }

    private final class GridCollectionView: NSCollectionView {
        weak var gridController: ThumbnailGridController?

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            gridController?.zoom.attachIfNeeded()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            gridController?.zoom.attachIfNeeded()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            gridController?.zoom?.viewportChanged()
        }

        override func mouseDown(with event: NSEvent) {
            gridController?.zoom.finishForInteraction()
            super.mouseDown(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            gridController?.zoom.finishForInteraction()
            super.scrollWheel(with: event)
        }

        override func keyDown(with event: NSEvent) {
            switch event.charactersIgnoringModifiers {
            case "+", "=": gridController?.zoom.step(1)
            case "-": gridController?.zoom.step(-1)
            default:
                gridController?.zoom.finishForInteraction()
                super.keyDown(with: event)
            }
        }

        override func indexPathForItem(at point: NSPoint) -> IndexPath? {
            // Layout cells also include the padding around proportionally scaled artwork.
            guard let indexPath = super.indexPathForItem(at: point),
                  let thumbnailView = item(at: indexPath)?.view as? ThumbnailItemView,
                  thumbnailView.containsThumbnail(at: thumbnailView.convert(point, from: self)) else {
                return nil
            }
            return indexPath
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            gridController?.contextMenu(for: event)
        }
    }

    private let collectionView: GridCollectionView
    private let dataSource: NSCollectionViewDiffableDataSource<String, String>
    private var items: [ThumbnailGridItem] = []
    private var requestedItems: [ThumbnailGridItem] = []
    private var requestedIDs = Set<String>()
    private var itemByID: [String: ThumbnailGridItem] = [:]
    private var selectedIDs: Set<String> = []
    private var isApplyingSelection = false
    private var onSelectionChange: ((Set<String>) -> Void)?
    private var makeContextMenu: (() -> NSMenu?)?
    private var sharingServicePicker: NSSharingServicePicker?
    private var exportSession: NSDraggingSession?
    private var snapshotGeneration = 0
    private(set) var zoom: ThumbnailGridZoomController!

    var nsCollectionView: NSCollectionView { collectionView }
    var hasPresentedItems: Bool { !items.isEmpty }
    var onPresentationChange: (() -> Void)?

    init(sectionInset: NSEdgeInsets = ThumbnailCollectionStyle.sectionInset) {
        let collectionView = GridCollectionView()
        self.collectionView = collectionView
        self.dataSource = NSCollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { collectionView, indexPath, itemID in
            let item = collectionView.makeItem(withIdentifier: ThumbnailCollectionItem.identifier, for: indexPath)
            guard let thumbnailItem = item as? ThumbnailCollectionItem,
                  let gridItem = (collectionView as? GridCollectionView)?.gridController?.itemByID[itemID] else {
                return item
            }
            (collectionView as? GridCollectionView)?.gridController?.zoom.prepareBadgeAppearance(for: thumbnailItem)
            thumbnailItem.configure(with: gridItem.url, status: gridItem.status, mediaKind: gridItem.mediaKind, contentVersion: gridItem.contentVersion, unavailableMessage: gridItem.unavailableMessage)
            thumbnailItem.onCompositionPresentationEnded = { [weak grid = (collectionView as? GridCollectionView)?.gridController] in
                // Reuse can happen inside a snapshot application; refresh on the next turn.
                Task { @MainActor [weak grid] in
                    guard let grid else { return }
                    grid.updateItems(grid.requestedItems)
                }
            }
            thumbnailItem.setSelectedAppearance(
                (collectionView as? GridCollectionView)?.gridController?.selectedIDs.contains(itemID) == true
            )
            return thumbnailItem
        }
        super.init()
        collectionView.gridController = self
        collectionView.delegate = self
        ThumbnailCollectionStyle.prepare(collectionView, sectionInset: sectionInset)
        zoom = ThumbnailGridZoomController(collection: collectionView, items: { [weak self] in self?.items ?? [] },
                                           sectionInset: sectionInset)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
    }

    func updateItems(_ newItems: [ThumbnailGridItem], animatingDifferences: Bool = true, defersCompletionRemoval: Bool = true) {
        requestedItems = newItems
        requestedIDs = Set(newItems.map(\.id))
        var presentedItems = newItems
        if defersCompletionRemoval {
            // Keep visible completed rows through their minimum playback and dissolve,
            // including rows removed from the queue or the "not composed" filter.
            for (index, old) in items.enumerated() where !requestedIDs.contains(old.id) {
                guard let path = dataSource.indexPath(for: old.id),
                      let cell = collectionView.item(at: path) as? ThumbnailCollectionItem,
                      cell.isPresentingComposition else { continue }
                let completed = ThumbnailGridItem(id: old.id, url: old.url, status: .finished,
                    mediaKind: old.mediaKind, contentVersion: old.contentVersion,
                    unavailableMessage: old.unavailableMessage, resourceURLs: old.resourceURLs)
                presentedItems.insert(completed, at: min(index, presentedItems.count))
            }
        }
        guard presentedItems != items else { return }
        let previousIDs = items.map(\.id)
        let presentedIDs = presentedItems.map(\.id)
        if previousIDs != presentedIDs {
            let remainingIDs = Set(presentedIDs)
            let isRemoval = presentedIDs.count < previousIDs.count
                && previousIDs.filter { remainingIDs.contains($0) } == presentedIDs
            zoom.itemsWillChange(count: presentedItems.count, preservesRowStart: isRemoval)
        }
        itemByID = Dictionary(uniqueKeysWithValues: presentedItems.map { ($0.id, $0) })
        items = presentedItems

        // reloadItems discards the bitmap and interrupts the mesh, then starts a
        // second thumbnail fade-in. Reconfigure the existing cell for status updates.
        updateVisibleItems()
        guard previousIDs != presentedItems.map(\.id) else {
            applySelection(selectedIDs)
            return
        }

        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections([Section.main])
        snapshot.appendItems(presentedItems.map(\.id), toSection: Section.main)

        // The first native snapshot must open at the newest end immediately;
        // animating an insertion from an empty document briefly reveals its top.
        let shouldAnimate = animatingDifferences && !previousIDs.isEmpty
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        snapshotGeneration += 1
        let generation = snapshotGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ThumbnailCollectionAnimation.duration(animated: shouldAnimate)
            dataSource.apply(snapshot, animatingDifferences: shouldAnimate) { [weak self] in
                guard let self, self.snapshotGeneration == generation else { return }
                self.zoom.itemsDidChange()
                self.updateVisibleItems()
            }
        }
        applySelection(selectedIDs)
        onPresentationChange?()
    }

    private func updateVisibleItems() {
        for case let cell as ThumbnailCollectionItem in collectionView.visibleItems() {
            guard let path = collectionView.indexPath(for: cell),
                  let id = dataSource.itemIdentifier(for: path), let item = itemByID[id] else { continue }
            zoom.prepareBadgeAppearance(for: cell)
            cell.configure(with: item.url, status: item.status, mediaKind: item.mediaKind,
                           contentVersion: item.contentVersion, unavailableMessage: item.unavailableMessage)
        }
    }

    func updateSectionInset(_ inset: NSEdgeInsets) {
        zoom.attachIfNeeded()
        zoom.updateSectionInset(inset)
    }

    func setSelectionHandler(_ handler: @escaping (Set<String>) -> Void) {
        onSelectionChange = handler
    }

    func setContextMenuProvider(_ provider: @escaping () -> NSMenu?) {
        makeContextMenu = provider
    }

    func applySelection(_ ids: Set<String>) {
        selectedIDs = ids.intersection(requestedIDs)
        let indexPaths = Set(selectedIDs.compactMap { dataSource.indexPath(for: $0) })
        guard collectionView.selectionIndexPaths != indexPaths else {
            updateVisibleSelectionAppearance()
            return
        }
        isApplyingSelection = true
        collectionView.deselectItems(at: collectionView.selectionIndexPaths.subtracting(indexPaths))
        collectionView.selectItems(at: indexPaths, scrollPosition: [])
        isApplyingSelection = false
        updateVisibleSelectionAppearance()
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateSelectionAppearance(at: indexPaths, isSelected: true)
        syncSelectionFromCollectionView()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateSelectionAppearance(at: indexPaths, isSelected: false)
        syncSelectionFromCollectionView()
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        guard exportSession == nil else { return false }
        let draggingItems = nativeDraggingItems(at: indexPaths)
        guard !draggingItems.isEmpty else { return false }
        applySelection(Set(indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }))
        syncSelectionFromCollectionView()
        let session = collectionView.beginDraggingSession(with: draggingItems, event: event, source: self)
        exportSession = session
        session.animatesToStartingPositionsOnCancelOrFail = true
        // AppKit still owns tracking, destination negotiation and slide-back.
        // Decline the collection's item-moving session, which hides source cells.
        return false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        exportSession = nil
    }

    /// Prepare independent native drag visuals before the collection can lift its cells.
    func nativeDraggingItems(at indexPaths: Set<IndexPath>) -> [NSDraggingItem] {
        let paths = indexPaths.sorted()
        let ids = Set(paths.compactMap { dataSource.itemIdentifier(for: $0) })
        guard ids.count == paths.count, !resourceURLs(forIDs: ids).isEmpty else { return [] }
        let anchor = paths.compactMap { collectionView.item(at: $0)?.view }
            .first.map { $0.convert($0.bounds, to: collectionView) } ?? .zero
        let originals = paths.compactMap { path -> NSDraggingItem? in
            guard let id = dataSource.itemIdentifier(for: path), let item = itemByID[id] else { return nil }
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url.standardizedFileURL as NSURL)
            if let cell = collectionView.item(at: path) {
                let components = cell.draggingImageComponents
                draggingItem.draggingFrame = cell.view.convert(cell.view.bounds, to: collectionView)
                draggingItem.imageComponentsProvider = components.isEmpty ? nil : { components }
            } else {
                // Offscreen selections carry their files without inventing another image.
                draggingItem.draggingFrame = anchor
            }
            return draggingItem
        }
        return expandedDraggingItems(originals)
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = itemByID[id],
              let url = NativeMediaResources.readableURLs(for: item).first else { return nil }
        return url as NSURL
    }

    func resourceURLs(forIDs ids: Set<String>) -> [URL] {
        NativeMediaResources.readableURLs(for: items.filter { ids.contains($0.id) && requestedIDs.contains($0.id) })
    }

    /// Expand each native collection drag item into its exact source resources.
    /// A Live Photo contributes two standard file-URL pasteboard items.
    func expandedDraggingItems(_ originalItems: [NSDraggingItem]) -> [NSDraggingItem] {
        var exported = Set<URL>()
        var result: [NSDraggingItem] = []
        for original in originalItems {
            guard let primaryURL = original.item as? NSURL,
                  let item = items.first(where: {
                      requestedIDs.contains($0.id)
                          && $0.url.standardizedFileURL == (primaryURL as URL).standardizedFileURL
                  }) else { continue }
            let resources = NativeMediaResources.readableURLs(for: item)
            guard !resources.isEmpty else { return [] }
            for (index, url) in resources.enumerated() where exported.insert(url).inserted {
                if index == 0 {
                    result.append(original)
                } else {
                    let resource = NSDraggingItem(pasteboardWriter: url as NSURL)
                    // The motion file travels with its still; it needs no second
                    // visual or synchronous filesystem icon lookup on drag start.
                    resource.draggingFrame = original.draggingFrame
                    resource.imageComponentsProvider = nil
                    result.append(resource)
                }
            }
        }
        return result
    }

    func addShareItem(to menu: NSMenu) {
        let urls = resourceURLs(forIDs: selectedIDs)
        if !urls.isEmpty {
            let standardItem = NSSharingServicePicker(items: urls).standardShareMenuItem
            let share = NSMenuItem(title: standardItem.title,
                                   action: #selector(shareFromContextMenu(_:)), keyEquivalent: "")
            share.image = standardItem.image
            share.target = self
            share.representedObject = selectedIDs
            menu.addItem(share)
        } else {
            let share = NSMenuItem(title: "共享", action: nil, keyEquivalent: "")
            share.isEnabled = false
            menu.addItem(share)
        }
        menu.addItem(.separator())
    }

    /// Anchor to artwork in display order, independent of selection or right-click order.
    /// Skip offscreen items so a scrolled multi-selection still points at a visible file.
    func sharingAnchorRect(forIDs ids: Set<String>) -> NSRect? {
        collectionView.layoutSubtreeIfNeeded()
        for item in items where ids.contains(item.id) && requestedIDs.contains(item.id) {
            guard let path = dataSource.indexPath(for: item.id),
                  let view = collectionView.item(at: path)?.view as? ThumbnailItemView else { continue }
            view.layoutSubtreeIfNeeded()
            let artwork = view.imageView?.frame ?? .zero
            let rect = view.convert(artwork.isEmpty ? view.bounds : artwork, to: collectionView)
                .intersection(collectionView.visibleRect)
            if !rect.isEmpty { return rect }
        }
        return nil
    }

    @objc private func shareFromContextMenu(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? Set<String> else { return }
        // Present after the contextual menu finishes tracking; otherwise its
        // dismissal can also dismiss the share popover or become its anchor.
        Task { @MainActor [weak self] in
            guard let self, self.collectionView.window != nil,
                  ids.isSubset(of: self.requestedIDs),
                  let rect = self.sharingAnchorRect(forIDs: ids) else { return }
            let urls = self.resourceURLs(forIDs: ids)
            guard !urls.isEmpty else { return }
            self.sharingServicePicker?.close()
            let picker = NSSharingServicePicker(items: urls)
            self.sharingServicePicker = picker
            picker.show(relativeTo: rect, of: self.collectionView, preferredEdge: .minX)
        }
    }

    private func syncSelectionFromCollectionView() {
        guard !isApplyingSelection else { return }
        let ids = Set(collectionView.selectionIndexPaths.compactMap { indexPath in
            dataSource.itemIdentifier(for: indexPath).flatMap { requestedIDs.contains($0) ? $0 : nil }
        })
        selectedIDs = ids
        onSelectionChange?(ids)
        updateVisibleSelectionAppearance()
    }

    private func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        guard let clickedIndexPath = collectionView.indexPathForItem(at: point),
              let clickedID = dataSource.itemIdentifier(for: clickedIndexPath),
              requestedIDs.contains(clickedID) else {
            return nil
        }

        if !collectionView.selectionIndexPaths.contains(clickedIndexPath) {
            isApplyingSelection = true
            collectionView.deselectItems(at: collectionView.selectionIndexPaths)
            collectionView.selectItems(at: [clickedIndexPath], scrollPosition: [])
            isApplyingSelection = false
        }
        // Opening a menu must publish the current selection even when AppKit
        // already selected the clicked item. A download refresh can have
        // changed model selection since the last collection-view callback.
        syncSelectionFromCollectionView()
        return makeContextMenu?()
    }

    private func updateVisibleSelectionAppearance() {
        for visibleItem in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: visibleItem),
                  let id = dataSource.itemIdentifier(for: indexPath),
                  let item = visibleItem as? ThumbnailCollectionItem else {
                continue
            }
            item.setSelectedAppearance(selectedIDs.contains(id))
        }
    }

    private func updateSelectionAppearance(at indexPaths: Set<IndexPath>, isSelected: Bool) {
        for indexPath in indexPaths {
            (collectionView.item(at: indexPath) as? ThumbnailCollectionItem)?.setSelectedAppearance(isSelected)
        }
    }
}
