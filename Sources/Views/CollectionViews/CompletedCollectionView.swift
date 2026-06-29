import AppKit

enum CompletedCollectionView {
    @MainActor
    static func make(
        items: [CompletedItem],
        filter: CompletedFilter,
        model: ImporterModel,
        scrollToTopRequestID: Int,
        isVisible: Bool
    ) -> (NSScrollView, Coordinator) {
        let coordinator = Coordinator(scrollToTopRequestID: scrollToTopRequestID)
        let collectionView = CompletedNSCollectionView()
        ThumbnailCollectionStyle.prepare(collectionView)
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.selectionCoordinator = coordinator
        collectionView.contextMenuCoordinator = coordinator

        let scrollView = NSScrollView()
        ThumbnailCollectionStyle.prepare(scrollView, documentView: collectionView)

        coordinator.collectionView = collectionView
        coordinator.scrollView = scrollView
        coordinator.items = items
        coordinator.filter = filter
        coordinator.model = model
        coordinator.scrollPosition.attach(
            scrollView: scrollView,
            initialOffset: model.completedScrollOriginY,
            writeScrollOffset: { [weak model] in model?.completedScrollOriginY = $0 },
            isActive: isVisible
        )
        coordinator.applySelection()
        return (scrollView, coordinator)
    }

    @MainActor
    static func update(
        scrollView: NSScrollView,
        coordinator: Coordinator,
        items: [CompletedItem],
        filter: CompletedFilter,
        model: ImporterModel,
        scrollToTopRequestID: Int,
        isVisible: Bool
    ) {
        ThumbnailCollectionStyle.updateGlassExtension(for: scrollView)
        coordinator.scrollPosition.update(
            externalOffsetY: model.completedScrollOriginY,
            writeScrollOffset: { [weak model] in model?.completedScrollOriginY = $0 }
        )
        coordinator.scrollPosition.setActive(isVisible)
        let filterChanged = coordinator.filter != filter
        coordinator.filter = filter
        coordinator.model = model
        coordinator.handleScrollToTopRequest(scrollToTopRequestID)
        if coordinator.items == items {
            coordinator.applySelection()
            if filterChanged {
                coordinator.scrollPosition.restoreToInitialTop()
            }
            return
        }
        coordinator.applyAnimatedItems(items, resetsScrollPosition: filterChanged)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
        var items: [CompletedItem] = []
        var filter: CompletedFilter?
        weak var model: ImporterModel?
        weak var collectionView: NSCollectionView?
        weak var scrollView: NSScrollView?
        let scrollPosition = ThumbnailScrollPositionController()
        private var scrollToTopRequestID: Int
        private var isApplyingSelection = false
        private let updateState = ThumbnailCollectionUpdateState<CompletedItem>()

        init(scrollToTopRequestID: Int) {
            self.scrollToTopRequestID = scrollToTopRequestID
        }

        func handleScrollToTopRequest(_ newRequestID: Int) {
            ThumbnailCollectionCoordinatorUtilities.handleScrollToTopRequest(
                currentRequestID: &scrollToTopRequestID,
                newRequestID: newRequestID,
                collectionView: collectionView,
                scrollPosition: scrollPosition
            )
        }

        func applySelection() {
            ThumbnailCollectionCoordinatorUtilities.applySelection(
                items: items,
                selectedIDs: model?.selectedCompletedIDs ?? [],
                collectionView: collectionView,
                isApplyingSelection: &isApplyingSelection
            )
        }

        func applyAnimatedItems(_ newItems: [CompletedItem], resetsScrollPosition: Bool = false) {
            ThumbnailCollectionCoordinatorUtilities.applyAnimatedItems(
                currentItems: items,
                newItems: newItems,
                setItems: { [weak self] in self?.items = $0 },
                currentItemsProvider: { [weak self] in self?.items ?? [] },
                collectionView: collectionView,
                scrollPosition: scrollPosition,
                updateState: updateState,
                resetsScrollPosition: resetsScrollPosition,
                applySelection: { [weak self] in self?.applySelection() },
                replay: { [weak self] pendingItems, pendingResetsScrollPosition in
                    self?.applyAnimatedItems(pendingItems, resetsScrollPosition: pendingResetsScrollPosition)
                }
            )
        }

        func syncSelection(from collectionView: NSCollectionView) {
            guard let selectedIDs = ThumbnailCollectionCoordinatorUtilities.selectedIDs(
                in: collectionView,
                items: items,
                isApplyingSelection: isApplyingSelection
            ) else { return }
            model?.selectedCompletedIDs = selectedIDs
        }

        func contextMenu(for collectionView: NSCollectionView, event: NSEvent) -> NSMenu? {
            ThumbnailCollectionCoordinatorUtilities.contextMenu(
                for: collectionView,
                event: event,
                itemCount: items.count,
                syncSelection: { syncSelection(from: collectionView) },
                applySelection: { applySelection() },
                makeMenu: { makeContextMenu() }
            )
        }

        private func makeContextMenu() -> NSMenu? {
            guard let model else { return nil }
            let selectedCount = model.selectedCompletedIDs.count
            let menu = NSMenu()
            menu.autoenablesItems = false

            menu.addItem(ThumbnailCollectionContextMenu.item(
                title: ThumbnailContextMenuItem.composeTitle(count: model.pairs.count),
                symbolName: AppSymbol.composeLivePhoto.normal,
                target: self,
                action: #selector(composeFromContextMenu(_:)),
                isEnabled: false
            ))
            menu.addItem(.separator())
            menu.addItem(ThumbnailCollectionContextMenu.item(
                title: ThumbnailContextMenuItem.openLocationTitle(count: selectedCount),
                symbolName: AppSymbol.openFolder.normal,
                target: self,
                action: #selector(openLocationsFromContextMenu(_:)),
                isEnabled: selectedCount > 0
            ))
            menu.addItem(.separator())
            menu.addItem(ThumbnailCollectionContextMenu.item(
                title: ThumbnailContextMenuItem.importTitle(count: selectedCount),
                symbolName: AppSymbol.importCompleted.normal,
                target: self,
                action: #selector(importFromContextMenu(_:)),
                isEnabled: selectedCount > 0 && !model.isImportingCompleted
            ))
            menu.addItem(ThumbnailCollectionContextMenu.item(
                title: ThumbnailContextMenuItem.importToAlbumTitle(count: selectedCount),
                symbolName: AppSymbol.addToAlbum.normal,
                target: self,
                action: #selector(importToAlbumFromContextMenu(_:)),
                isEnabled: selectedCount > 0 && !model.isImportingCompleted
            ))
            menu.addItem(.separator())
            menu.addItem(ThumbnailCollectionContextMenu.item(
                title: ThumbnailContextMenuItem.removeTitle(count: selectedCount),
                symbolName: AppSymbol.removeItems,
                target: self,
                action: #selector(removeFromContextMenu(_:)),
                isEnabled: selectedCount > 0
            ))
            menu.addItem(ThumbnailCollectionContextMenu.item(
                title: ThumbnailContextMenuItem.deleteSourceTitle(count: selectedCount),
                symbolName: AppSymbol.deleteSourceFiles,
                target: self,
                action: #selector(deleteSourceFilesFromContextMenu(_:)),
                isEnabled: selectedCount > 0
            ))

            return menu
        }

        @objc private func composeFromContextMenu(_ sender: NSMenuItem) {
            Task { await model?.processPairs() }
        }

        @objc private func openLocationsFromContextMenu(_ sender: NSMenuItem) {
            model?.openSelectedCompletedItemLocations()
        }

        @objc private func importFromContextMenu(_ sender: NSMenuItem) {
            Task { await model?.importCompletedToPhotos(addToAlbum: false) }
        }

        @objc private func importToAlbumFromContextMenu(_ sender: NSMenuItem) {
            Task { await model?.importCompletedToPhotos(addToAlbum: true) }
        }

        @objc private func removeFromContextMenu(_ sender: NSMenuItem) {
            model?.clearVisibleCompleted(deleteFiles: false)
        }

        @objc private func deleteSourceFilesFromContextMenu(_ sender: NSMenuItem) {
            model?.clearVisibleCompleted(deleteFiles: true)
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailCollectionItem.identifier, for: indexPath)
            guard let thumbnailItem = item as? ThumbnailCollectionItem else { return item }
            guard items.indices.contains(indexPath.item) else { return item }
            let itemModel = items[indexPath.item]
            thumbnailItem.configure(
                with: itemModel.imageURL,
                mediaKind: itemModel.movieURL == nil ? .photo : .livePhoto
            )
            thumbnailItem.setSelectedAppearance(model?.selectedCompletedIDs.contains(itemModel.id) == true)
            return thumbnailItem
        }

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            false
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            nil
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            ThumbnailCollectionCoordinatorUtilities.updateSelectionAppearance(
                in: collectionView,
                at: indexPaths,
                isSelected: true,
                syncSelection: { syncSelection(from: collectionView) }
            )
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            ThumbnailCollectionCoordinatorUtilities.updateSelectionAppearance(
                in: collectionView,
                at: indexPaths,
                isSelected: false,
                syncSelection: { syncSelection(from: collectionView) }
            )
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
    }
}

final class CompletedNSCollectionView: NSCollectionView {
    weak var selectionCoordinator: CompletedCollectionView.Coordinator?
    weak var contextMenuCoordinator: CompletedCollectionView.Coordinator?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if indexPathForItem(at: point) == nil {
            deselectItems(at: selectionIndexPaths)
            selectionCoordinator?.syncSelection(from: self)
            super.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuCoordinator?.contextMenu(for: self, event: event)
    }
}
