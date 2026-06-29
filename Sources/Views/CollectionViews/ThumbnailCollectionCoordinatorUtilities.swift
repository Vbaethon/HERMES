import AppKit

@MainActor
final class ThumbnailCollectionUpdateState<Item: Identifiable & Equatable> where Item.ID: Hashable {
    var isApplyingAnimatedItems = false
    var pendingItems: [Item]?
    var pendingResetsScrollPosition = false
}

@MainActor
enum ThumbnailCollectionCoordinatorUtilities {
    static func handleScrollToTopRequest(
        currentRequestID: inout Int,
        newRequestID: Int,
        collectionView: NSCollectionView?,
        scrollPosition: ThumbnailScrollPositionController
    ) {
        guard currentRequestID != newRequestID else { return }
        currentRequestID = newRequestID
        guard let collectionView else { return }
        scrollPosition.scrollToDefaultStart(collectionView: collectionView)
    }

    static func applySelection<Item: Identifiable>(
        items: [Item],
        selectedIDs: Set<Item.ID>,
        collectionView: NSCollectionView?,
        isApplyingSelection: inout Bool
    ) where Item.ID: Hashable {
        guard let collectionView else { return }
        let indexPaths = ThumbnailCollectionSelection.indexPaths(for: items, selectedIDs: selectedIDs)
        guard collectionView.selectionIndexPaths != indexPaths else { return }
        isApplyingSelection = true
        ThumbnailCollectionSelection.apply(indexPaths, to: collectionView)
        isApplyingSelection = false
    }

    static func selectedIDs<Item: Identifiable>(
        in collectionView: NSCollectionView,
        items: [Item],
        isApplyingSelection: Bool
    ) -> Set<Item.ID>? where Item.ID: Hashable {
        guard !isApplyingSelection else { return nil }
        return ThumbnailCollectionSelection.selectedIDs(in: collectionView, items: items)
    }

    static func contextMenu(
        for collectionView: NSCollectionView,
        event: NSEvent,
        itemCount: Int,
        syncSelection: () -> Void,
        applySelection: () -> Void,
        makeMenu: () -> NSMenu?
    ) -> NSMenu? {
        guard ThumbnailCollectionSelection.selectClickedItemForContextMenu(
            in: collectionView,
            event: event,
            itemCount: itemCount,
            syncSelection: syncSelection,
            applySelection: applySelection
        ) else {
            return nil
        }
        return makeMenu()
    }

    static func updateSelectionAppearance(
        in collectionView: NSCollectionView,
        at indexPaths: Set<IndexPath>,
        isSelected: Bool,
        syncSelection: () -> Void
    ) {
        for indexPath in indexPaths {
            (collectionView.item(at: indexPath) as? ThumbnailCollectionItem)?.setSelectedAppearance(isSelected)
        }
        syncSelection()
    }

    static func applyAnimatedItems<Item: Identifiable & Equatable>(
        currentItems: [Item],
        newItems: [Item],
        setItems: @escaping ([Item]) -> Void,
        currentItemsProvider: @escaping () -> [Item],
        collectionView: NSCollectionView?,
        scrollPosition: ThumbnailScrollPositionController,
        updateState: ThumbnailCollectionUpdateState<Item>,
        resetsScrollPosition: Bool = false,
        reloadIndexPaths: (Dictionary<Item.ID, Item>, [Item]) -> Set<IndexPath> = { _, _ in [] },
        performVisibleUpdate: @escaping () -> Void = {},
        applySelection: @escaping () -> Void,
        replay: @escaping ([Item], Bool) -> Void
    ) {
        guard let collectionView else {
            setItems(newItems)
            return
        }
        guard !updateState.isApplyingAnimatedItems else {
            updateState.pendingItems = newItems
            updateState.pendingResetsScrollPosition = updateState.pendingResetsScrollPosition || resetsScrollPosition
            return
        }

        let oldIDs = currentItems.map(\.id)
        let newIDs = newItems.map(\.id)
        guard oldIDs != newIDs else {
            setItems(newItems)
            performVisibleUpdate()
            return
        }
        if resetsScrollPosition {
            setItems(newItems)
            collectionView.reloadData()
            collectionView.layoutSubtreeIfNeeded()
            scrollPosition.scrollToDefaultStart(collectionView: collectionView)
            applySelection()
            return
        }

        var workingIDs = oldIDs
        let preservedScrollOriginY = scrollPosition.currentOriginY()

        let deletedIndexPaths = Set(oldIDs.enumerated().compactMap { index, id in
            newIDs.contains(id) ? nil : IndexPath(item: index, section: 0)
        })
        for indexPath in deletedIndexPaths.sorted(by: { $0.item > $1.item }) {
            workingIDs.remove(at: indexPath.item)
        }

        var insertedIndexPaths = Set<IndexPath>()
        for (index, id) in newIDs.enumerated() where !workingIDs.contains(id) {
            workingIDs.insert(id, at: index)
            insertedIndexPaths.insert(IndexPath(item: index, section: 0))
        }

        var moves: [(from: IndexPath, to: IndexPath)] = []
        for (targetIndex, id) in newIDs.enumerated()
            where workingIDs.indices.contains(targetIndex) && workingIDs[targetIndex] != id {
            guard let sourceIndex = workingIDs.firstIndex(of: id) else { continue }
            moves.append((
                from: IndexPath(item: sourceIndex, section: 0),
                to: IndexPath(item: targetIndex, section: 0)
            ))
            workingIDs.moveElement(from: sourceIndex, toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex)
        }

        let oldItemsByID = Dictionary(uniqueKeysWithValues: currentItems.map { ($0.id, $0) })
        let reloadedIndexPaths = reloadIndexPaths(oldItemsByID, newItems)

        setItems(newItems)
        updateState.isApplyingAnimatedItems = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            context.allowsImplicitAnimation = true
            collectionView.performBatchUpdates {
                collectionView.deleteItems(at: deletedIndexPaths)
                collectionView.insertItems(at: insertedIndexPaths)
                for move in moves {
                    collectionView.moveItem(at: move.from, to: move.to)
                }
                if !reloadedIndexPaths.isEmpty {
                    collectionView.reloadItems(at: reloadedIndexPaths)
                }
            } completionHandler: { _ in
                updateState.isApplyingAnimatedItems = false
                performVisibleUpdate()
                applySelection()
                if !resetsScrollPosition {
                    scrollPosition.restore(to: preservedScrollOriginY)
                }
                if let pendingItems = updateState.pendingItems {
                    let pendingResetsScrollPosition = updateState.pendingResetsScrollPosition
                    updateState.pendingItems = nil
                    updateState.pendingResetsScrollPosition = false
                    if currentItemsProvider() != pendingItems {
                        replay(pendingItems, pendingResetsScrollPosition)
                    }
                }
            }
        }
    }
}
