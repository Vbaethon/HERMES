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
final class ThumbnailGridController: NSObject, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    private enum Section {
        static let main = "main"
    }

    private final class GridCollectionView: NSCollectionView {
        weak var gridController: ThumbnailGridController?

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
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

        override func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent,
                                           source: any NSDraggingSource) -> NSDraggingSession {
            let resources = gridController?.expandedDraggingItems(items) ?? items
            return super.beginDraggingSession(with: resources, event: event, source: source)
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

        let shouldAnimate = animatingDifferences && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        dataSource.apply(snapshot, animatingDifferences: shouldAnimate) { [weak self] in
            self?.updateVisibleItems()
        }
        applySelection(selectedIDs)
        onPresentationChange?()
    }

    private func updateVisibleItems() {
        for case let cell as ThumbnailCollectionItem in collectionView.visibleItems() {
            guard let path = collectionView.indexPath(for: cell),
                  let id = dataSource.itemIdentifier(for: path), let item = itemByID[id] else { continue }
            cell.configure(with: item.url, status: item.status, mediaKind: item.mediaKind,
                           contentVersion: item.contentVersion, unavailableMessage: item.unavailableMessage)
        }
    }

    func updateSectionInset(_ inset: NSEdgeInsets) {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout,
              !ThumbnailCollectionStyle.insetsEqual(layout.sectionInset, inset) else {
            return
        }
        layout.sectionInset = inset
        layout.invalidateLayout()
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
        !resourceURLs(forIDs: Set(indexPaths.compactMap { dataSource.itemIdentifier(for: $0) })).isEmpty
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
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    resource.setDraggingFrame(original.draggingFrame.offsetBy(dx: 8, dy: -8), contents: icon)
                    result.append(resource)
                }
            }
        }
        return result
    }

    func addShareItem(to menu: NSMenu) {
        let urls = resourceURLs(forIDs: selectedIDs)
        if !urls.isEmpty {
            let picker = NSSharingServicePicker(items: urls)
            sharingServicePicker = picker
            menu.addItem(picker.standardShareMenuItem)
        } else {
            let share = NSMenuItem(title: "共享", action: nil, keyEquivalent: "")
            share.isEnabled = false
            menu.addItem(share)
        }
        menu.addItem(.separator())
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
