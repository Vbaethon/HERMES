import AppKit

enum PairCollectionView {
    @MainActor
    static func make(
        items: [PairItem],
        model: ImporterModel,
        scrollToTopRequestID: Int,
        isVisible: Bool
    ) -> (NSScrollView, Coordinator) {
        let coordinator = Coordinator(scrollToTopRequestID: scrollToTopRequestID)
        let collectionView = PairNSCollectionView()
        ThumbnailCollectionStyle.prepare(collectionView)
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.selectionCoordinator = coordinator
        collectionView.contextMenuCoordinator = coordinator

        let scrollView = NSScrollView()
        ThumbnailCollectionStyle.prepare(scrollView, documentView: collectionView)

        coordinator.collectionView = collectionView
        coordinator.items = items
        coordinator.model = model
        coordinator.scrollPosition.attach(
            scrollView: scrollView,
            initialOffset: model.queueScrollOriginY,
            writeScrollOffset: { [weak model] in model?.queueScrollOriginY = $0 },
            isActive: isVisible
        )
        coordinator.applySelection()
        return (scrollView, coordinator)
    }

    @MainActor
    static func update(
        scrollView: NSScrollView,
        coordinator: Coordinator,
        items: [PairItem],
        model: ImporterModel,
        scrollToTopRequestID: Int,
        isVisible: Bool
    ) {
        ThumbnailCollectionStyle.updateGlassExtension(for: scrollView)
        coordinator.model = model
        coordinator.scrollPosition.update(
            externalOffsetY: model.queueScrollOriginY,
            writeScrollOffset: { [weak model] in model?.queueScrollOriginY = $0 }
        )
        coordinator.scrollPosition.setActive(isVisible)
        coordinator.handleScrollToTopRequest(scrollToTopRequestID)
        if coordinator.items != items {
            coordinator.applyItems(items)
        }
        coordinator.applySelection()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
        var items: [PairItem] = []
        weak var model: ImporterModel?
        weak var collectionView: NSCollectionView?
        let scrollPosition = ThumbnailScrollPositionController()
        private var scrollToTopRequestID: Int
        private var isApplyingSelection = false
        private let updateState = ThumbnailCollectionUpdateState<PairItem>()

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

        func applyItems(_ newItems: [PairItem]) {
            ThumbnailCollectionCoordinatorUtilities.applyAnimatedItems(
                currentItems: items,
                newItems: newItems,
                setItems: { [weak self] in self?.items = $0 },
                currentItemsProvider: { [weak self] in self?.items ?? [] },
                collectionView: collectionView,
                scrollPosition: scrollPosition,
                updateState: updateState,
                performVisibleUpdate: { [weak self] in self?.updateVisibleItems() },
                applySelection: { [weak self] in self?.applySelection() },
                replay: { [weak self] pendingItems, _ in self?.applyItems(pendingItems) }
            )
        }

        private func updateVisibleItems() {
            guard let collectionView else { return }
            for visibleItem in collectionView.visibleItems() {
                guard let indexPath = collectionView.indexPath(for: visibleItem),
                      items.indices.contains(indexPath.item),
                      let item = visibleItem as? ThumbnailCollectionItem else {
                    continue
                }
                let pair = items[indexPath.item]
                item.configure(with: pair.imageURL, status: pair.status, mediaKind: .livePhoto)
                item.setSelectedAppearance(model?.selectedPairIDs.contains(pair.id) == true)
            }
        }

        func applySelection() {
            ThumbnailCollectionCoordinatorUtilities.applySelection(
                items: items,
                selectedIDs: model?.selectedPairIDs ?? [],
                collectionView: collectionView,
                isApplyingSelection: &isApplyingSelection
            )
        }

        func syncSelection(from collectionView: NSCollectionView) {
            guard let selectedIDs = ThumbnailCollectionCoordinatorUtilities.selectedIDs(
                in: collectionView,
                items: items,
                isApplyingSelection: isApplyingSelection
            ) else { return }
            model?.selectedPairIDs = selectedIDs
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
            let selectedCount = model.selectedPairIDs.count
            let menu = NSMenu()
            menu.autoenablesItems = false

            menu.addItem(ThumbnailCollectionContextMenu.item(
                title: ThumbnailContextMenuItem.composeTitle(count: selectedCount),
                symbolName: AppSymbol.composeLivePhoto.normal,
                target: self,
                action: #selector(composeFromContextMenu(_:)),
                isEnabled: selectedCount > 0 && !model.isProcessing
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
                action: #selector(disabledContextMenuItem(_:)),
                isEnabled: false
            ))
            menu.addItem(ThumbnailCollectionContextMenu.item(
                title: ThumbnailContextMenuItem.importToAlbumTitle(count: selectedCount),
                symbolName: AppSymbol.addToAlbum.normal,
                target: self,
                action: #selector(disabledContextMenuItem(_:)),
                isEnabled: false
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
            model?.openSelectedPairLocations()
        }

        @objc private func removeFromContextMenu(_ sender: NSMenuItem) {
            model?.clear(deleteFiles: false)
        }

        @objc private func deleteSourceFilesFromContextMenu(_ sender: NSMenuItem) {
            model?.clear(deleteFiles: true)
        }

        @objc private func disabledContextMenuItem(_ sender: NSMenuItem) {
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailCollectionItem.identifier, for: indexPath)
            guard let thumbnailItem = item as? ThumbnailCollectionItem else { return item }
            guard items.indices.contains(indexPath.item) else { return item }
            let pair = items[indexPath.item]
            thumbnailItem.configure(with: pair.imageURL, status: pair.status, mediaKind: .livePhoto)
            thumbnailItem.setSelectedAppearance(model?.selectedPairIDs.contains(pair.id) == true)
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
    }
}

final class PairNSCollectionView: NSCollectionView {
    weak var selectionCoordinator: PairCollectionView.Coordinator?
    weak var contextMenuCoordinator: PairCollectionView.Coordinator?

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
