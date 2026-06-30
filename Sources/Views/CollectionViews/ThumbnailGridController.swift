import AppKit

struct ThumbnailGridItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let status: PairItem.Status
    let mediaKind: ThumbnailMediaKind
    let contentVersion: TimeInterval
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

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if indexPathForItem(at: point) == nil {
                deselectItems(at: selectionIndexPaths)
                gridController?.syncSelectionFromCollectionView()
                super.mouseDown(with: event)
                return
            }
            super.mouseDown(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            gridController?.contextMenu(for: event)
        }
    }

    private let collectionView: GridCollectionView
    private let dataSource: NSCollectionViewDiffableDataSource<String, String>
    private var items: [ThumbnailGridItem] = []
    private var itemByID: [String: ThumbnailGridItem] = [:]
    private var selectedIDs: Set<String> = []
    private var isApplyingSelection = false
    private var onSelectionChange: ((Set<String>) -> Void)?
    private var makeContextMenu: (() -> NSMenu?)?

    var nsCollectionView: NSCollectionView { collectionView }

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
            thumbnailItem.configure(with: gridItem.url, status: gridItem.status, mediaKind: gridItem.mediaKind)
            thumbnailItem.setSelectedAppearance(
                (collectionView as? GridCollectionView)?.gridController?.selectedIDs.contains(itemID) == true
            )
            return thumbnailItem
        }
        super.init()
        collectionView.gridController = self
        collectionView.delegate = self
        ThumbnailCollectionStyle.prepare(collectionView, sectionInset: sectionInset)
    }

    func updateItems(_ newItems: [ThumbnailGridItem], animatingDifferences: Bool = true) {
        itemByID = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
        items = newItems

        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections([Section.main])
        snapshot.appendItems(newItems.map(\.id), toSection: Section.main)

        let shouldAnimate = animatingDifferences && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        dataSource.apply(snapshot, animatingDifferences: shouldAnimate)
        applySelection(selectedIDs)
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
        selectedIDs = ids
        let indexPaths = Set(items.enumerated().compactMap { index, item in
            ids.contains(item.id) ? IndexPath(item: index, section: 0) : nil
        })
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
        false
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        nil
    }

    private func syncSelectionFromCollectionView() {
        guard !isApplyingSelection else { return }
        let ids = Set(collectionView.selectionIndexPaths.compactMap { indexPath in
            items.indices.contains(indexPath.item) ? items[indexPath.item].id : nil
        })
        selectedIDs = ids
        onSelectionChange?(ids)
        updateVisibleSelectionAppearance()
    }

    private func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        guard let clickedIndexPath = collectionView.indexPathForItem(at: point),
              items.indices.contains(clickedIndexPath.item) else {
            return nil
        }

        if !collectionView.selectionIndexPaths.contains(clickedIndexPath) {
            collectionView.deselectItems(at: collectionView.selectionIndexPaths)
            collectionView.selectItems(at: [clickedIndexPath], scrollPosition: [])
            syncSelectionFromCollectionView()
        }
        return makeContextMenu?()
    }

    private func updateVisibleSelectionAppearance() {
        for visibleItem in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: visibleItem),
                  items.indices.contains(indexPath.item),
                  let item = visibleItem as? ThumbnailCollectionItem else {
                continue
            }
            item.setSelectedAppearance(selectedIDs.contains(items[indexPath.item].id))
        }
    }

    private func updateSelectionAppearance(at indexPaths: Set<IndexPath>, isSelected: Bool) {
        for indexPath in indexPaths {
            (collectionView.item(at: indexPath) as? ThumbnailCollectionItem)?.setSelectedAppearance(isSelected)
        }
    }
}
