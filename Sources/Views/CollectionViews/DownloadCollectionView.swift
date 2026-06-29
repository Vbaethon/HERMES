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
        private var isApplyingAnimatedItems = false
        private var pendingItems: [DownloadGridItem]?
        private var pendingResetsScrollPosition = false

        init(scrollToTopRequestID: Int) {
            self.scrollToTopRequestID = scrollToTopRequestID
        }

        func handleScrollToTopRequest(_ newRequestID: Int) {
            guard scrollToTopRequestID != newRequestID else { return }
            scrollToTopRequestID = newRequestID
            guard let collectionView else { return }
            scrollPosition.scrollToDefaultStart(collectionView: collectionView)
        }

        func applySelection() {
            guard let collectionView else { return }
            let selectedIDs = model?.selectedDownloadItemIDs ?? []
            let indexPaths = ThumbnailCollectionSelection.indexPaths(for: items, selectedIDs: selectedIDs)
            guard collectionView.selectionIndexPaths != indexPaths else { return }
            isApplyingSelection = true
            ThumbnailCollectionSelection.apply(indexPaths, to: collectionView)
            isApplyingSelection = false
        }

        func applyAnimatedItems(_ newItems: [DownloadGridItem], resetsScrollPosition: Bool = false) {
            guard let collectionView else {
                items = newItems
                return
            }
            guard !isApplyingAnimatedItems else {
                pendingItems = newItems
                pendingResetsScrollPosition = pendingResetsScrollPosition || resetsScrollPosition
                return
            }

            let oldIDs = items.map(\.id)
            let newIDs = newItems.map(\.id)
            if resetsScrollPosition {
                items = newItems
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

            let oldItemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let reloadedIndexPaths = Set(newItems.enumerated().compactMap { index, item -> IndexPath? in
                guard let oldItem = oldItemsByID[item.id], oldItem != item else { return nil }
                if oldItem.imageURL != item.imageURL || oldItem.modifiedTime != item.modifiedTime {
                    thumbnailCache.remove(item.imageURL)
                    thumbnailFailureCache.remove(item.imageURL)
                }
                return IndexPath(item: index, section: 0)
            })

            items = newItems
            isApplyingAnimatedItems = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
                context.allowsImplicitAnimation = true
                collectionView.performBatchUpdates {
                    collectionView.deleteItems(at: deletedIndexPaths)
                    collectionView.insertItems(at: insertedIndexPaths)
                    for move in moves {
                        collectionView.moveItem(at: move.from, to: move.to)
                    }
                    collectionView.reloadItems(at: reloadedIndexPaths)
                } completionHandler: { [weak self] _ in
                    guard let self else { return }
                    self.isApplyingAnimatedItems = false
                    self.applySelection()
                    if !resetsScrollPosition {
                        self.scrollPosition.restore(to: preservedScrollOriginY)
                    }
                    if let pendingItems = self.pendingItems {
                        let pendingResetsScrollPosition = self.pendingResetsScrollPosition
                        self.pendingItems = nil
                        self.pendingResetsScrollPosition = false
                        if self.items != pendingItems {
                            self.applyAnimatedItems(pendingItems, resetsScrollPosition: pendingResetsScrollPosition)
                        }
                    }
                }
            }
        }

        func syncSelection(from collectionView: NSCollectionView) {
            guard !isApplyingSelection else { return }
            model?.selectedDownloadItemIDs = ThumbnailCollectionSelection.selectedIDs(in: collectionView, items: items)
        }

        func contextMenu(for collectionView: NSCollectionView, event: NSEvent) -> NSMenu? {
            guard ThumbnailCollectionSelection.selectClickedItemForContextMenu(
                in: collectionView,
                event: event,
                itemCount: items.count,
                syncSelection: { syncSelection(from: collectionView) },
                applySelection: { applySelection() }
            ) else {
                return nil
            }

            return makeContextMenu()
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
            for indexPath in indexPaths {
                (collectionView.item(at: indexPath) as? ThumbnailCollectionItem)?.setSelectedAppearance(true)
            }
            syncSelection(from: collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            for indexPath in indexPaths {
                (collectionView.item(at: indexPath) as? ThumbnailCollectionItem)?.setSelectedAppearance(false)
            }
            syncSelection(from: collectionView)
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
