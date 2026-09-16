import Foundation
import Photos
import UniformTypeIdentifiers

enum PhotoLibraryImporter {
    static func importMediaFiles(_ urls: [URL], albumName: String?) async -> PhotoImportResult {
        let mediaFiles = urls.filter { FileSystemUtilities.isImage($0) || FileSystemUtilities.isVideo($0) }
        guard !mediaFiles.isEmpty else { return .success(0) }

        return await performPhotoLibraryChanges {
            var placeholders: [PHObjectPlaceholder] = []
            for url in mediaFiles {
                let request = PHAssetCreationRequest.forAsset()
                let resourceType: PHAssetResourceType = FileSystemUtilities.isVideo(url) ? .video : .photo
                request.addResource(with: resourceType, fileURL: url, options: nil)
                if let placeholder = request.placeholderForCreatedAsset {
                    placeholders.append(placeholder)
                }
            }
            add(placeholders: placeholders, toAlbumNamed: albumName)
            return .success(placeholders.count)
        }
    }

    static func importLivePhotoPair(_ item: CompletedItem, albumName: String?) async -> PhotoImportResult {
        guard let movieURL = item.movieURL else { return .failure("未找到源文件。") }
        return await importLivePhotoPairs([(item.imageURL, movieURL)], albumName: albumName)
    }

    static func importLivePhotoPairs(_ pairs: [(URL, URL)], albumName: String?) async -> PhotoImportResult {
        guard !pairs.isEmpty else { return .success(0) }

        let preparedPairs: [(URL, URL)]
        let temporaryImportFolder: URL?
        switch LivePhotoToolRunner.prepareUniquePairsForPhotosImport(pairs) {
        case .success(let pairs, let folder):
            preparedPairs = pairs
            temporaryImportFolder = folder
        case .failure(let message):
            return .failure(message)
        }
        defer {
            if let temporaryImportFolder {
                try? FileManager.default.removeItem(at: temporaryImportFolder)
            }
        }

        return await performPhotoLibraryChanges {
            var placeholders: [PHObjectPlaceholder] = []
            for (imageURL, movieURL) in preparedPairs {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: imageURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: nil)
                guard let placeholder = request.placeholderForCreatedAsset else {
                    return .failure(NSError(
                        domain: "HERMES.PhotoLibraryImporter",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Photos 没有创建这组 Live Photo。"]
                    ))
                }
                placeholders.append(placeholder)
            }
            add(placeholders: placeholders, toAlbumNamed: albumName)
            return .success(placeholders.count)
        }
    }

    private static func performPhotoLibraryChanges(_ changes: @escaping () -> Result<Int, Error>) async -> PhotoImportResult {
        let status = await authorizationStatus()
        guard status == .authorized || status == .limited else {
            return .failure("没有照片图库添加权限。请在系统设置中允许 HERMES 添加照片。")
        }

        var changeResult: Result<Int, Error> = .success(0)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                changeResult = changes()
            }
            switch changeResult {
            case .success(let count):
                return .success(count)
            case .failure(let error):
                return .failure(error.localizedDescription)
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func authorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    private static func add(placeholders: [PHObjectPlaceholder], toAlbumNamed albumName: String?) {
        guard let albumName, !albumName.isEmpty, !placeholders.isEmpty else { return }
        let album = fetchAlbum(named: albumName)
        let request: PHAssetCollectionChangeRequest?
        if let album {
            request = PHAssetCollectionChangeRequest(for: album)
        } else {
            request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
        }
        request?.addAssets(placeholders as NSArray)
    }

    private static func fetchAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", name)
        return PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: options
        ).firstObject
    }
}
