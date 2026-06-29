import AppKit

enum DownloadCollectionView {
    @MainActor
    static func make(
        items: [DownloadGridItem],
        filter: DownloadFilter,
        model: ImporterModel,
        scrollToTopRequestID: Int,
        bottomContentInset: CGFloat,
        isVisible: Bool
    ) -> (NSScrollView, Coordinator) {
        let coordinator = Coordinator(scrollToTopRequestID: scrollToTopRequestID)
        let collectionView = DownloadNSCollectionView()
        ThumbnailCollectionStyle.prepare(collectionView, sectionInset: downloadSectionInset(bottomContentInset: bottomContentInset))
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.selectionCoordinator = coordinator
        collectionView.contextMenuCoordinator = coordinator

        let scrollView = NSScrollView()
        ThumbnailCollectionStyle.prepare(scrollView, documentView: collectionView)

        coordinator.collectionView = collectionView
        coordinator.items = items
        coordinator.filter = filter
        coordinator.model = model
        coordinator.scrollPosition.attach(
            scrollView: scrollView,
            initialOffset: model.downloadScrollOriginY,
            writeScrollOffset: { [weak model] in model?.downloadScrollOriginY = $0 },
            isActive: isVisible
        )
        coordinator.applySelection()
        return (scrollView, coordinator)
    }

    @MainActor
    static func update(
        scrollView: NSScrollView,
        coordinator: Coordinator,
        items: [DownloadGridItem],
        filter: DownloadFilter,
        model: ImporterModel,
        scrollToTopRequestID: Int,
        bottomContentInset: CGFloat,
        isVisible: Bool
    ) {
        ThumbnailCollectionStyle.updateGlassExtension(for: scrollView)
        if let collectionView = scrollView.documentView as? NSCollectionView {
            applyDownloadSectionInset(to: collectionView, bottomContentInset: bottomContentInset)
        }
        coordinator.scrollPosition.update(
            externalOffsetY: model.downloadScrollOriginY,
            writeScrollOffset: { [weak model] in model?.downloadScrollOriginY = $0 }
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
    private static func downloadSectionInset(bottomContentInset: CGFloat) -> NSEdgeInsets {
        ThumbnailCollectionStyle.sectionInset(additionalBottomInset: bottomContentInset)
    }

    @MainActor
    private static func applyDownloadSectionInset(to collectionView: NSCollectionView, bottomContentInset: CGFloat) {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let newInset = downloadSectionInset(bottomContentInset: bottomContentInset)
        guard !ThumbnailCollectionStyle.insetsEqual(layout.sectionInset, newInset) else { return }
        layout.sectionInset = newInset
        layout.invalidateLayout()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
        var items: [DownloadGridItem] = []
        var filter: DownloadFilter?
        weak var model: ImporterModel?
        weak var collectionView: NSCollectionView?
        let scrollPosition = ThumbnailScrollPositionController()
        private var scrollToTopRequestID: Int
        private var isApplyingSelection = false
        private let updateState = ThumbnailCollectionUpdateState<DownloadGridItem>()

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
                selectedIDs: model?.selectedDownloadItemIDs ?? [],
                collectionView: collectionView,
                isApplyingSelection: &isApplyingSelection
            )
        }

        func applyAnimatedItems(_ newItems: [DownloadGridItem], resetsScrollPosition: Bool = false) {
            ThumbnailCollectionCoordinatorUtilities.applyAnimatedItems(
                currentItems: items,
                newItems: newItems,
                setItems: { [weak self] in self?.items = $0 },
                currentItemsProvider: { [weak self] in self?.items ?? [] },
                collectionView: collectionView,
                scrollPosition: scrollPosition,
                updateState: updateState,
                resetsScrollPosition: resetsScrollPosition,
                reloadIndexPaths: { oldItemsByID, newItems in
                    Set(newItems.enumerated().compactMap { index, item -> IndexPath? in
                        guard let oldItem = oldItemsByID[item.id], oldItem != item else { return nil }
                        if oldItem.imageURL != item.imageURL || oldItem.modifiedTime != item.modifiedTime {
                            thumbnailCache.remove(item.imageURL)
                            thumbnailFailureCache.remove(item.imageURL)
                        }
                        return IndexPath(item: index, section: 0)
                    })
                },
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
            model?.selectedDownloadItemIDs = selectedIDs
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
            let selectedCount = model.selectedDownloadItemIDs.count
            let menu = NSMenu()
            menu.autoenablesItems = false

            menu.addItem(ThumbnailCollectionContextMenu.item(
                title: ThumbnailContextMenuItem.composeTitle(count: selectedCount),
                symbolName: AppSymbol.composeLivePhoto.normal,
                target: self,
                action: #selector(composeFromContextMenu(_:)),
                isEnabled: model.canProcessDownloadPairs
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
                action: #selector(importToPhotosFromContextMenu(_:)),
                isEnabled: model.canImportSelectedDownloadMedia
            ))
            menu.addItem(ThumbnailCollectionContextMenu.item(
                title: ThumbnailContextMenuItem.importToAlbumTitle(count: selectedCount),
                symbolName: AppSymbol.addToAlbum.normal,
                target: self,
                action: #selector(importToAlbumFromContextMenu(_:)),
                isEnabled: model.canImportSelectedDownloadMedia
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
            Task { await model?.processDownloadPairs() }
        }

        @objc private func openLocationsFromContextMenu(_ sender: NSMenuItem) {
            model?.openSelectedDownloadItemLocations()
        }

        @objc private func importToPhotosFromContextMenu(_ sender: NSMenuItem) {
            Task { await model?.importSelectedDownloadMediaToPhotos(addToAlbum: false) }
        }

        @objc private func importToAlbumFromContextMenu(_ sender: NSMenuItem) {
            Task { await model?.importSelectedDownloadMediaToPhotos(addToAlbum: true) }
        }

        @objc private func removeFromContextMenu(_ sender: NSMenuItem) {
            model?.clearVisibleDownloads(deleteFiles: false)
        }

        @objc private func deleteSourceFilesFromContextMenu(_ sender: NSMenuItem) {
            model?.clearVisibleDownloads(deleteFiles: true)
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailCollectionItem.identifier, for: indexPath)
            guard let thumbnailItem = item as? ThumbnailCollectionItem else { return item }
            guard items.indices.contains(indexPath.item) else { return item }
            let gridItem = items[indexPath.item]
            thumbnailItem.configure(with: gridItem.imageURL, status: gridItem.status, mediaKind: gridItem.mediaKind)
            thumbnailItem.setSelectedAppearance(model?.selectedDownloadItemIDs.contains(gridItem.id) == true)
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

final class DownloadNSCollectionView: NSCollectionView {
    weak var selectionCoordinator: DownloadCollectionView.Coordinator?
    weak var contextMenuCoordinator: DownloadCollectionView.Coordinator?

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
