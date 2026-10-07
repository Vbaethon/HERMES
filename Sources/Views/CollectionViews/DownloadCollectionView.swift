import AppKit

enum DownloadCollectionView {
    @MainActor
    static func make(
        items: [DownloadGridItem],
        filter: DownloadFilter,
        model: ImporterModel,
        bottomContentInset: CGFloat
    ) -> (NSScrollView, Coordinator) {
        let coordinator = Coordinator()
        let gridController = ThumbnailGridController(sectionInset: downloadSectionInset(bottomContentInset: bottomContentInset))
        let scrollView = NSScrollView()
        ThumbnailCollectionStyle.prepare(scrollView, documentView: gridController.nsCollectionView)

        coordinator.gridController = gridController
        coordinator.collectionView = gridController.nsCollectionView
        coordinator.filter = filter
        coordinator.model = model
        coordinator.configureGridCallbacks()
        coordinator.applyItems(items, animatingDifferences: false)
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
        bottomContentInset: CGFloat
    ) {
        coordinator.gridController?.updateSectionInset(downloadSectionInset(bottomContentInset: bottomContentInset))
        let filterChanged = coordinator.filter != filter
        coordinator.filter = filter
        coordinator.model = model
        coordinator.applyItems(items, defersCompletionRemoval: !filterChanged)
        coordinator.applySelection()
    }

    @MainActor
    private static func downloadSectionInset(bottomContentInset: CGFloat) -> NSEdgeInsets {
        ThumbnailCollectionStyle.sectionInset(additionalBottomInset: bottomContentInset)
    }

    @MainActor
    final class Coordinator: NSObject {
        var filter: DownloadFilter?
        weak var model: ImporterModel?
        weak var collectionView: NSCollectionView?
        var gridController: ThumbnailGridController?
        private var items: [DownloadGridItem] = []
        private var hasAppliedItems = false
        private var appliedDeletionRevision = 0

        override init() {}

        func configureGridCallbacks() {
            gridController?.setSelectionHandler { [weak self] selectedIDs in
                self?.model?.selectedDownloadItemIDs = selectedIDs
            }
            gridController?.setContextMenuProvider { [weak self] in
                self?.makeContextMenu()
            }
        }

        func applyItems(_ newItems: [DownloadGridItem], animatingDifferences: Bool = true, defersCompletionRemoval: Bool = true) {
            let revision = model?.thumbnailDeletionRevision ?? 0
            let explicitlyRemoved = revision != appliedDeletionRevision
            // Input sizing and unrelated model updates can reload the page.
            // Preserve its native cells and in-flight zoom when content is the
            // same; explicit filter changes still finish deferred removals.
            if hasAppliedItems, items == newItems, defersCompletionRemoval, !explicitlyRemoved { return }
            hasAppliedItems = true
            items = newItems
            appliedDeletionRevision = revision
            // PairItem.id standardizes both file URLs. Resolve each pair once
            // instead of repeating a filesystem-backed linear search per cell.
            var resourcesByPairID: [String: [URL]] = [:]
            for pair in model?.downloadPairs ?? [] {
                let id = pair.id
                if resourcesByPairID[id] == nil { resourcesByPairID[id] = [pair.imageURL, pair.videoURL] }
            }
            gridController?.updateItems(newItems.map { gridItem(for: $0, resourcesByPairID: resourcesByPairID) },
                animatingDifferences: animatingDifferences, defersCompletionRemoval: defersCompletionRemoval && !explicitlyRemoved)
        }

        func applySelection() {
            gridController?.applySelection(model?.selectedDownloadItemIDs ?? [])
        }

        private func gridItem(for item: DownloadGridItem, resourcesByPairID: [String: [URL]]) -> ThumbnailGridItem {
            let resources: [URL]
            if case .pair(let id) = item.kind, let pairResources = resourcesByPairID[id] {
                resources = pairResources
            } else {
                resources = [item.imageURL]
            }
            return ThumbnailGridItem(
                id: item.id,
                url: item.imageURL,
                status: item.status,
                mediaKind: item.mediaKind,
                contentVersion: item.modifiedTime,
                unavailableMessage: item.unavailableMessage,
                resourceURLs: resources
            )
        }

        private func makeContextMenu() -> NSMenu? {
            guard let model else { return nil }
            let selectedCount = model.selectedDownloadItemIDs.count
            let menu = NSMenu()
            menu.autoenablesItems = false
            gridController?.addShareItem(to: menu)

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
                isEnabled: selectedCount > 0 && model.canClearVisibleDownloads
            ))
            menu.addItem(ThumbnailCollectionContextMenu.item(
                title: ThumbnailContextMenuItem.deleteSourceTitle(count: selectedCount),
                symbolName: AppSymbol.deleteSourceFiles,
                target: self,
                action: #selector(deleteSourceFilesFromContextMenu(_:)),
                isEnabled: selectedCount > 0 && model.canClearVisibleDownloads
            ))

            return menu
        }

        @objc private func composeFromContextMenu(_ sender: NSMenuItem) {
            guard let model else { return }
            let selection = model.selectedDownloadItemIDs
            Task { await model.processDownloadPairs(selection: selection) }
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
    }
}
