import AppKit

enum PairCollectionView {
    @MainActor
    static func make(
        items: [PairItem],
        model: ImporterModel
    ) -> (NSScrollView, Coordinator) {
        let coordinator = Coordinator()
        let gridController = ThumbnailGridController()
        let scrollView = NSScrollView()
        ThumbnailCollectionStyle.prepare(scrollView, documentView: gridController.nsCollectionView)

        coordinator.gridController = gridController
        coordinator.collectionView = gridController.nsCollectionView
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
        items: [PairItem],
        model: ImporterModel
    ) {
        coordinator.model = model
        coordinator.applyItems(items)
        coordinator.applySelection()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var model: ImporterModel?
        weak var collectionView: NSCollectionView?
        var gridController: ThumbnailGridController?
        private var items: [PairItem] = []

        override init() {}

        func configureGridCallbacks() {
            gridController?.setSelectionHandler { [weak self] selectedIDs in
                self?.model?.selectedPairIDs = selectedIDs
            }
            gridController?.setContextMenuProvider { [weak self] in
                self?.makeContextMenu()
            }
        }

        func applyItems(_ newItems: [PairItem], animatingDifferences: Bool = true) {
            items = newItems
            gridController?.updateItems(newItems.map(Self.gridItem), animatingDifferences: animatingDifferences)
        }

        func applySelection() {
            gridController?.applySelection(model?.selectedPairIDs ?? [])
        }

        private static func gridItem(for item: PairItem) -> ThumbnailGridItem {
            ThumbnailGridItem(
                id: item.id,
                url: item.imageURL,
                status: item.status,
                mediaKind: .livePhoto,
                contentVersion: 0
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
    }
}
