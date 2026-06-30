import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

extension Array {
    mutating func moveElement(from sourceIndex: Int, toOffset destinationOffset: Int) {
        guard indices.contains(sourceIndex) else { return }
        let element = remove(at: sourceIndex)
        let adjustedDestination = destinationOffset > sourceIndex ? destinationOffset - 1 : destinationOffset
        insert(element, at: Swift.max(0, Swift.min(adjustedDestination, count)))
    }
}

@MainActor
final class ImporterModel: ObservableObject {
    private static let outputFolderDefaultsKey = "OutputFolderPath"
    private static let outputFolderBookmarkDefaultsKey = "OutputFolderBookmark.v1"
    private static let completedRecordsDefaultsKey = "CompletedRecords.v1"
    private static let importedCompletedStemsDefaultsKey = "ImportedCompletedStems.v1"
    private static let downloadOutputFolderDefaultsKey = "DownloadOutputFolderPath.v1"
    private static let downloadOutputFolderBookmarkDefaultsKey = "DownloadOutputFolderBookmark.v1"
    private static let downloadCompletedRecordsDefaultsKey = "DownloadCompletedRecords.v1"
    private static let importedDownloadCompletedStemsDefaultsKey = "ImportedDownloadCompletedStems.v1"
    private static var appDisplayName: String {
        let bundle = Bundle.main
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }
        return "HERMES"
    }
    private static let outputFolderName = "HERMES"
    private static var defaultOutputFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(outputFolderName, isDirectory: true)
    }
    private static var defaultDownloadOutputFolder: URL {
        defaultOutputFolder.appendingPathComponent("Downloader", isDirectory: true)
    }

    @Published var selection: SidebarSection? = .queue
    @Published var files: [URL] = []
    @Published var pairs: [PairItem] = []
    @Published var selectedPairIDs = Set<PairItem.ID>()
    @Published var completed: [CompletedItem] = []
    @Published var selectedCompletedIDs = Set<CompletedItem.ID>()
    @Published var completedFilter: CompletedFilter = .all {
        didSet {
            retainVisibleCompletedSelection()
        }
    }
    @Published var outputFolder: URL {
        didSet {
            UserDefaults.standard.set(outputFolder.path, forKey: Self.outputFolderDefaultsKey)
        }
    }
    @Published var importToPhotos = true {
        didSet {
            UserDefaults.standard.set(importToPhotos, forKey: AppPreferenceKey.importToPhotos)
            if !importToPhotos {
                addToAlbum = false
                completedAddToAlbum = false
            }
        }
    }
    @Published var addToAlbum = false {
        didSet {
            UserDefaults.standard.set(addToAlbum, forKey: AppPreferenceKey.addToAlbum)
        }
    }
    @Published var completedAddToAlbum = false {
        didSet {
            UserDefaults.standard.set(completedAddToAlbum, forKey: AppPreferenceKey.completedAddToAlbum)
        }
    }
    @Published var isProcessing = false
    @Published var statusText = "拖入照片和视频，或点击添加文件。"
    @Published var isImportingCompleted = false
    @Published var downloadShareText = ""
    @Published var downloadOutputFolder: URL {
        didSet {
            UserDefaults.standard.set(downloadOutputFolder.path, forKey: Self.downloadOutputFolderDefaultsKey)
        }
    }
    @Published var downloadPairs: [PairItem] = []
    @Published var downloadPhotos: [URL] = []
    @Published var downloadVideos: [URL] = []
    @Published var downloadCompleted: [CompletedItem] = []
    @Published private(set) var visibleDownloadItemsCache: [DownloadGridItem] = []
    @Published var selectedDownloadItemIDs = Set<DownloadGridItem.ID>()
    @Published var downloadFilter: DownloadFilter = .all {
        didSet {
            rebuildVisibleDownloadItems()
            retainVisibleDownloadSelection()
        }
    }
    @Published var isDownloading = false
    @Published var isProcessingDownloads = false
    @Published var isImportingDownloadMedia = false
    @Published var downloadStatusText = "输入分享链接开始下载。"
    @Published private(set) var downloadProgressItems: [DownloadProgressItem] = []
    @Published private(set) var downloadInputResetID = 0
    var needsDewuLogAccessForCurrentDownload: Bool {
        let shareText = downloadShareText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.shouldPrepareDewuLogAccess(for: shareText) && !DewuLogStore.hasDataRootAccess()
    }

    private var isRefreshingCompleted = false
    private var importedCompletedStems = Set<String>()
    private var isRefreshingDownloads = false
    private var needsAnotherDownloadRefresh = false
    private var importedDownloadCompletedStems = Set<String>()
    private var downloadModifiedTimesByPath: [String: TimeInterval] = [:]
    private var pendingDownloadTasks: [DownloadQueueTask] = []
    private var activeDownloadTask: DownloadQueueTask?
    private var activeDownloadProgressState: DownloadProgressState?

    private struct DownloadQueueTask {
        let id: UUID
        let shareText: String
        let entries: [String]
        let outputRoot: URL
        let title: String
    }

    /// 下载进度里程碑常量 — 集中定义进度条各阶段的锚点值，替换分散的硬编码魔术数字。
    private enum DownloadProgressMilestone {
        /// 扫描阶段结束时的进度比例（缓存扫描 / 解析链接等前期工作）。
        /// Douyin 缓存扫描会在此区间内实时上报真实进度。
        static let scanEnd: CGFloat = 0.20
        /// 下载阶段结束时的进度比例。剩余 0.04 留给"整理下载结果"阶段。
        static let downloadEnd: CGFloat = 0.96
    }
    private static let completedDownloadProgressHoldNanoseconds: UInt64 = 460_000_000

    private struct DownloadProgressState {
        var completedCount: Int
        var detail: String
        var unitProgress: CGFloat
    }

    var imageCount: Int { files.filter(FileSystemUtilities.isImage).count }
    var videoCount: Int { files.filter(FileSystemUtilities.isVideo).count }
    var canClearQueue: Bool { !isProcessing && (!files.isEmpty || !pairs.isEmpty) }
    var canProcessSelectedPairs: Bool { !isProcessing && !pairs.isEmpty }
    var albumName: String { Self.appDisplayName }
    var visibleCompleted: [CompletedItem] {
        switch completedFilter {
        case .notAdded:
            completed.filter { !$0.importedToPhotos }
        case .added:
            completed.filter(\.importedToPhotos)
        case .all:
            completed
        }
    }
    var selectedCompletedItems: [CompletedItem] {
        completed.filter { selectedCompletedIDs.contains($0.id) }
    }
    var selectedPairs: [PairItem] {
        pairs.filter { selectedPairIDs.contains($0.id) }
    }
    var canClearVisibleCompleted: Bool { !visibleCompleted.isEmpty }
    var queueSubtitle: String {
        "已识别 \(imageCount) 张照片，\(videoCount) 个视频，已配对 \(pairs.count) 组。"
    }
    var downloadComposedFolder: URL {
        downloadOutputFolder.appendingPathComponent("已合成", isDirectory: true)
    }
    var visibleDownloadItems: [DownloadGridItem] {
        visibleDownloadItemsCache
    }

    private func rebuildVisibleDownloadItems() {
        let completedStems = Set(downloadCompleted.map { Self.completedStem(for: $0.imageURL) })
        let pairItems = downloadPairs.map { pair in
            let isCompleted = completedStems.contains(Self.completedStem(for: pair.imageURL))
            let path = pair.imageURL.standardizedFileURL.path
            return DownloadGridItem(
                id: "pair:\(pair.id)",
                imageURL: pair.imageURL,
                modifiedTime: downloadModifiedTimesByPath[path] ?? .leastNonzeroMagnitude,
                status: isCompleted ? .finished : pair.status,
                kind: .pair(pair.id),
                isCompleted: isCompleted,
                mediaKind: .livePhoto
            )
        }
        let photoItems = downloadPhotos.map { photoURL in
            let standardizedURL = photoURL.standardizedFileURL
            return DownloadGridItem(
                id: "photo:\(standardizedURL.path)",
                imageURL: standardizedURL,
                modifiedTime: downloadModifiedTimesByPath[standardizedURL.path] ?? .leastNonzeroMagnitude,
                status: .finished,
                kind: .photo(standardizedURL.path),
                isCompleted: false,
                mediaKind: .photo
            )
        }
        let videoItems = downloadVideos.map { videoURL in
            let standardizedURL = videoURL.standardizedFileURL
            return DownloadGridItem(
                id: "video:\(standardizedURL.path)",
                imageURL: standardizedURL,
                modifiedTime: downloadModifiedTimesByPath[standardizedURL.path] ?? .leastNonzeroMagnitude,
                status: .finished,
                kind: .video(standardizedURL.path),
                isCompleted: false,
                mediaKind: .video
            )
        }
        let unsortedItems = pairItems + photoItems + videoItems
        let itemGroups = Dictionary(grouping: unsortedItems) {
            Self.downloadPostGroupKey(for: $0.imageURL, root: downloadOutputFolder)
        }
        let groupModifiedTimes = itemGroups.mapValues { items in
            items.map(\.modifiedTime).max() ?? .leastNonzeroMagnitude
        }
        let allItems = unsortedItems.sorted {
            let lhsGroup = Self.downloadPostGroupKey(for: $0.imageURL, root: downloadOutputFolder)
            let rhsGroup = Self.downloadPostGroupKey(for: $1.imageURL, root: downloadOutputFolder)
            if lhsGroup != rhsGroup {
                let lhsDate = groupModifiedTimes[lhsGroup] ?? .leastNonzeroMagnitude
                let rhsDate = groupModifiedTimes[rhsGroup] ?? .leastNonzeroMagnitude
                if lhsDate == rhsDate {
                    return lhsGroup.localizedStandardCompare(rhsGroup) == .orderedAscending
                }
                return lhsDate > rhsDate
            }
            return $0.imageURL.lastPathComponent.localizedStandardCompare($1.imageURL.lastPathComponent) == .orderedAscending
        }
        switch downloadFilter {
        case .notComposed:
            visibleDownloadItemsCache = allItems.filter { !$0.isCompleted }
        case .composed:
            visibleDownloadItemsCache = allItems.filter(\.isCompleted)
        case .all:
            visibleDownloadItemsCache = allItems
        }
    }
    var selectedDownloadPairs: [PairItem] {
        let selectedPairIDs = Set(selectedDownloadItemIDs.compactMap(Self.downloadPairID))
        return downloadPairs.filter { selectedPairIDs.contains($0.id) }
    }
    var selectedDownloadMediaURLs: [URL] {
        let selectedIDs = selectedDownloadItemIDs
        guard !selectedIDs.isEmpty else { return [] }
        let selectedPhotoPaths = Set(selectedIDs.compactMap { Self.downloadMediaPath(from: $0, prefix: "photo:") })
        let selectedVideoPaths = Set(selectedIDs.compactMap { Self.downloadMediaPath(from: $0, prefix: "video:") })
        return downloadPhotos.filter { selectedPhotoPaths.contains($0.standardizedFileURL.path) }
            + downloadVideos.filter { selectedVideoPaths.contains($0.standardizedFileURL.path) }
    }
    var canProcessDownloadPairs: Bool {
        guard !isProcessingDownloads, !isDownloading else { return false }
        let processablePairIDs = processableVisibleDownloadPairIDs
        if selectedDownloadItemIDs.isEmpty {
            return !processablePairIDs.isEmpty
        }
        return selectedDownloadItemIDs
            .compactMap(Self.downloadPairID)
            .contains { processablePairIDs.contains($0) }
    }
    var canImportSelectedDownloadMedia: Bool {
        !isDownloading && !isProcessingDownloads && !isImportingDownloadMedia && !selectedDownloadMediaURLs.isEmpty
    }
    var canClearVisibleDownloads: Bool { !visibleDownloadItems.isEmpty }
    var downloadSubtitle: String { downloadOutputFolder.path }
    private var processableVisibleDownloadPairIDs: Set<PairItem.ID> {
        guard downloadFilter != .composed else { return [] }
        let completedStems = Set(downloadCompleted.map { Self.completedStem(for: $0.imageURL) })
        return Set(downloadPairs.compactMap { pair in
            completedStems.contains(Self.completedStem(for: pair.imageURL)) ? nil : pair.id
        })
    }
    init() {
        let defaults = UserDefaults.standard
        let preferredImportToPhotos = defaults.object(forKey: AppPreferenceKey.importToPhotos) as? Bool ?? true
        importToPhotos = preferredImportToPhotos
        addToAlbum = preferredImportToPhotos && (defaults.object(forKey: AppPreferenceKey.addToAlbum) as? Bool ?? false)
        completedAddToAlbum = defaults.object(forKey: AppPreferenceKey.completedAddToAlbum) as? Bool ?? false

        let resolvedOutputFolder: URL
        if let bookmarkedFolder = Self.resolveOutputFolderBookmark() {
            resolvedOutputFolder = bookmarkedFolder
        } else if let path = UserDefaults.standard.string(forKey: Self.outputFolderDefaultsKey), !path.isEmpty {
            resolvedOutputFolder = URL(fileURLWithPath: path)
        } else {
            resolvedOutputFolder = Self.defaultOutputFolder
        }
        outputFolder = resolvedOutputFolder

        let resolvedDownloadOutputFolder: URL
        if let bookmarkedDownloadFolder = Self.resolveDownloadOutputFolderBookmark() {
            resolvedDownloadOutputFolder = bookmarkedDownloadFolder
        } else if let path = Self.downloadOutputFolderPath(), !path.isEmpty {
            resolvedDownloadOutputFolder = URL(fileURLWithPath: path)
        } else {
            resolvedDownloadOutputFolder = Self.defaultDownloadOutputFolder
        }
        downloadOutputFolder = resolvedDownloadOutputFolder
        completed = Self.loadCompletedRecords()
        downloadCompleted = Self.loadDownloadCompletedRecords()
        importedCompletedStems = Self.loadImportedCompletedStems()
        importedDownloadCompletedStems = Self.loadImportedDownloadCompletedStems()
        importedCompletedStems.formUnion(
            completed
                .filter(\.importedToPhotos)
                .map { Self.completedStem(for: $0.imageURL) }
        )
        importedDownloadCompletedStems.formUnion(
            downloadCompleted
                .filter(\.importedToPhotos)
                .map { Self.completedStem(for: $0.imageURL) }
        )
        saveImportedCompletedStems()
        saveImportedDownloadCompletedStems()
        refreshCompleted()
        refreshDownloads()
    }

    func addFiles(_ urls: [URL]) {
        let existing = Set(files.map(\.standardizedFileURL))
        let additions = urls
            .flatMap(Self.mediaFiles)
            .filter { FileSystemUtilities.isImage($0) || FileSystemUtilities.isVideo($0) }
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0) }

        files.append(contentsOf: additions)
        rebuildPairs()
    }

    func clear(deleteFiles: Bool = false) {
        guard !isProcessing else { return }
        let selectedIDs = selectedPairIDs
        let pairsToClear = selectedIDs.isEmpty ? pairs : pairs.filter { selectedIDs.contains($0.id) }
        guard !pairsToClear.isEmpty || !files.isEmpty else { return }

        if deleteFiles {
            let sourceURLs = pairsToClear.flatMap { [$0.imageURL, $0.videoURL] }
            for url in sourceURLs {
                Self.moveToTrash(url)
            }
        }

        let urlsToClear = Set(pairsToClear.flatMap { [$0.imageURL.standardizedFileURL, $0.videoURL.standardizedFileURL] })
        ThumbnailCollectionAnimation.perform {
            if selectedIDs.isEmpty {
                files.removeAll()
                pairs.removeAll()
            } else {
                files.removeAll { urlsToClear.contains($0.standardizedFileURL) }
                pairs.removeAll { selectedIDs.contains($0.id) }
            }
        }
        selectedPairIDs.subtract(selectedIDs)
        if pairs.isEmpty {
            statusText = "拖入照片和视频，或点击添加文件。"
        } else if deleteFiles {
            statusText = "已将 \(pairsToClear.count) 张照片移到废纸篓。"
        } else {
            statusText = "已移除 \(pairsToClear.count) 张照片。"
        }
    }

    func selectOutputParentFolder(_ parentFolder: URL) {
        moveOutputFolder(to: parentFolder)
    }

    private func authorizedOutputFolderForUserAction() -> URL? {
        if let bookmarkedFolder = Self.resolveOutputFolderBookmark() {
            if outputFolder.standardizedFileURL != bookmarkedFolder.standardizedFileURL {
                outputFolder = bookmarkedFolder
            }
            return bookmarkedFolder
        }
        return outputFolder.standardizedFileURL
    }

    private func authorizedDownloadOutputFolderForUserAction() -> URL? {
        if let bookmarkedFolder = Self.resolveDownloadOutputFolderBookmark() {
            if downloadOutputFolder.standardizedFileURL != bookmarkedFolder.standardizedFileURL {
                downloadOutputFolder = bookmarkedFolder
            }
            return bookmarkedFolder
        }
        return downloadOutputFolder.standardizedFileURL
    }

    private static func resolveOutputFolderBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: outputFolderBookmarkDefaultsKey) else {
            return nil
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL
            if isStale {
                saveOutputFolderBookmark(for: url)
            }
            UserDefaults.standard.set(url.path, forKey: outputFolderDefaultsKey)
            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: outputFolderBookmarkDefaultsKey)
            return nil
        }
    }

    private static func saveOutputFolderBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: outputFolderBookmarkDefaultsKey)
            UserDefaults.standard.set(url.path, forKey: outputFolderDefaultsKey)
        } catch {
            UserDefaults.standard.set(url.path, forKey: outputFolderDefaultsKey)
        }
    }

    private static func resolveDownloadOutputFolderBookmark() -> URL? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: downloadOutputFolderBookmarkDefaultsKey) else {
            return nil
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL
            if isStale {
                saveDownloadOutputFolderBookmark(for: url)
            }
            defaults.set(url.path, forKey: downloadOutputFolderDefaultsKey)
            return url
        } catch {
            defaults.removeObject(forKey: downloadOutputFolderBookmarkDefaultsKey)
            return nil
        }
    }

    private static func saveDownloadOutputFolderBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: downloadOutputFolderBookmarkDefaultsKey)
            UserDefaults.standard.set(url.path, forKey: downloadOutputFolderDefaultsKey)
        } catch {
            UserDefaults.standard.set(url.path, forKey: downloadOutputFolderDefaultsKey)
        }
    }

    private static func downloadOutputFolderPath() -> String? {
        UserDefaults.standard.string(forKey: downloadOutputFolderDefaultsKey)
    }

    private nonisolated static func withSecurityScopedAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }

    private nonisolated static func withSecurityScopedAccess<T>(to url: URL, _ body: () async throws -> T) async rethrows -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await body()
    }

    private nonisolated static func moveToTrash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private static func openFileLocations(for urls: [URL]) {
        var seenPaths = Set<String>()
        let existingURLs = urls.compactMap { url -> URL? in
            let standardizedURL = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardizedURL.path), seenPaths.insert(standardizedURL.path).inserted else {
                return nil
            }
            return standardizedURL
        }
        guard !existingURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
    }

    func openSelectedPairLocations() {
        let urls = selectedPairs.map(\.imageURL)
        Self.openFileLocations(for: urls)
    }

    func openSelectedDownloadItemLocations() {
        let selectedIDs = selectedDownloadItemIDs
        let items = visibleDownloadItems.filter { selectedIDs.contains($0.id) }
        guard !items.isEmpty, let folder = authorizedDownloadOutputFolderForUserAction() else { return }
        Self.withSecurityScopedAccess(to: folder) {
            Self.openFileLocations(for: items.map(\.imageURL))
        }
    }

    func openSelectedCompletedItemLocations() {
        let items = selectedCompletedItems
        guard !items.isEmpty, let folder = authorizedOutputFolderForUserAction() else { return }
        Self.withSecurityScopedAccess(to: folder) {
            Self.openFileLocations(for: items.map(\.imageURL))
        }
    }

    private func moveOutputFolder(to parentFolder: URL) {
        guard !isProcessing, !isImportingCompleted else { return }

        let fileManager = FileManager.default
        let sourceFolder = outputFolder.standardizedFileURL
        let destinationFolder = parentFolder
            .appendingPathComponent(Self.outputFolderName, isDirectory: true)
            .standardizedFileURL

        guard sourceFolder != destinationFolder, sourceFolder != parentFolder.standardizedFileURL else {
            return
        }

        do {
            let detachedRecordFiles = try movableCompletedRecordFiles(
                from: sourceFolder,
                to: destinationFolder
            )
            if fileManager.fileExists(atPath: sourceFolder.path) {
                if fileManager.fileExists(atPath: destinationFolder.path) {
                    let sourceItems = try fileManager.contentsOfDirectory(
                        at: sourceFolder,
                        includingPropertiesForKeys: nil
                    )
                    let conflictingItem = sourceItems.first {
                        fileManager.fileExists(
                            atPath: destinationFolder.appendingPathComponent($0.lastPathComponent).path
                        )
                    }
                    guard conflictingItem == nil else {
                        throw NSError(
                            domain: "HERMES",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "目标文件夹中已经存在“\(conflictingItem!.lastPathComponent)”。"]
                        )
                    }
                    for item in sourceItems {
                        try fileManager.moveItem(
                            at: item,
                            to: destinationFolder.appendingPathComponent(item.lastPathComponent)
                        )
                    }
                    if sourceFolder.lastPathComponent == Self.outputFolderName {
                        try? fileManager.removeItem(at: sourceFolder)
                    }
                } else {
                    try fileManager.moveItem(at: sourceFolder, to: destinationFolder)
                }
            } else {
                try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            }

            let movedRecordPaths = try moveCompletedRecordFiles(
                detachedRecordFiles,
                to: destinationFolder
            )
            outputFolder = destinationFolder
            Self.saveOutputFolderBookmark(for: destinationFolder)
            relocateCompletedRecords(
                from: sourceFolder,
                to: destinationFolder,
                movedRecordPaths: movedRecordPaths
            )
            saveCompletedRecords()
            refreshCompleted()
            statusText = "导出文件夹已移动到“\(destinationFolder.path)”。"
        } catch {
            statusText = "移动导出文件夹失败：\(error.localizedDescription)"
        }
    }

    private func movableCompletedRecordFiles(from sourceFolder: URL, to destinationFolder: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let urls = completed
            .flatMap { [$0.imageURL, $0.movieURL].compactMap { $0 } }
            .map(\.standardizedFileURL)
        let movableURLs = Dictionary(grouping: urls, by: \.path)
            .values
            .compactMap(\.first)
            .filter {
                fileManager.fileExists(atPath: $0.path)
                    && !Self.contains($0, in: sourceFolder)
                    && !Self.contains($0, in: destinationFolder)
            }
        let movingNames = movableURLs.map(\.lastPathComponent)
        guard Set(movingNames).count == movingNames.count else {
            throw NSError(
                domain: "HERMES",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "旧记录中存在同名文件，无法自动移动。"]
            )
        }

        let destinationNames = try fileManager.fileExists(atPath: destinationFolder.path)
            ? Set(fileManager.contentsOfDirectory(atPath: destinationFolder.path))
            : []
        let sourceNames = try fileManager.fileExists(atPath: sourceFolder.path)
            ? Set(fileManager.contentsOfDirectory(atPath: sourceFolder.path))
            : []
        guard let conflictingName = movingNames.first(where: { destinationNames.contains($0) || sourceNames.contains($0) }) else {
            return movableURLs
        }
        throw NSError(
            domain: "HERMES",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "目标文件夹中已经存在“\(conflictingName)”。"]
        )
    }

    private func moveCompletedRecordFiles(_ urls: [URL], to destinationFolder: URL) throws -> [String: String] {
        let fileManager = FileManager.default
        var movedPaths: [String: String] = [:]
        for url in urls {
            let destinationURL = destinationFolder.appendingPathComponent(url.lastPathComponent)
            try fileManager.moveItem(at: url, to: destinationURL)
            movedPaths[url.path] = destinationURL.path
        }
        return movedPaths
    }

    private func relocateCompletedRecords(
        from sourceFolder: URL,
        to destinationFolder: URL,
        movedRecordPaths: [String: String]
    ) {
        var relocatedSelection = Set<CompletedItem.ID>()
        completed = completed.map { item in
            var relocatedItem = item
            relocatedItem.imagePath = movedRecordPaths[item.imageURL.standardizedFileURL.path] ?? Self.relocatedPath(
                item.imagePath,
                from: sourceFolder,
                to: destinationFolder
            )
            relocatedItem.moviePath = item.moviePath.map {
                let standardizedPath = URL(fileURLWithPath: $0).standardizedFileURL.path
                return movedRecordPaths[standardizedPath] ?? Self.relocatedPath($0, from: sourceFolder, to: destinationFolder)
            }
            if selectedCompletedIDs.contains(item.id) {
                relocatedSelection.insert(relocatedItem.id)
            }
            return relocatedItem
        }
        selectedCompletedIDs = relocatedSelection
    }

    private nonisolated static func contains(_ url: URL, in folder: URL) -> Bool {
        let folderPath = folder.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        return urlPath == folderPath || urlPath.hasPrefix(folderPath + "/")
    }

    private nonisolated static func relocatedPath(_ path: String, from sourceFolder: URL, to destinationFolder: URL) -> String {
        let sourcePath = sourceFolder.standardizedFileURL.path
        let filePath = URL(fileURLWithPath: path).standardizedFileURL.path
        let sourcePrefix = sourcePath + "/"
        guard filePath.hasPrefix(sourcePrefix) else { return path }
        return destinationFolder.appendingPathComponent(String(filePath.dropFirst(sourcePrefix.count))).path
    }

    func openOutputFolder() {
        guard let folder = authorizedOutputFolderForUserAction() else { return }
        NSWorkspace.shared.open(folder)
    }

    func openDownloadOutputFolder() {
        guard let folder = authorizedDownloadOutputFolderForUserAction() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func selectDownloadOutputFolder(_ folder: URL) {
        guard !isDownloading, !isProcessingDownloads else { return }
        let standardizedFolder = folder.standardizedFileURL
        downloadOutputFolder = standardizedFolder
        Self.saveDownloadOutputFolderBookmark(for: downloadOutputFolder)
        refreshDownloads()
        downloadStatusText = "下载文件夹已设置为“\(downloadOutputFolder.path)”。"
    }

    func downloadShare() async {
        let shareText = downloadShareText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shareText.isEmpty else { return }
        await enqueueDownloadShare(shareText: shareText)
    }

    private func enqueueDownloadShare(shareText: String) async {
        let entries = Self.downloadShareEntries(from: shareText)
        guard !entries.isEmpty else {
            downloadStatusText = "没有识别到支持的分享链接。"
            return
        }
        guard let outputRoot = authorizedDownloadOutputFolderForUserAction() else { return }
        if Self.shouldPrepareDewuLogAccess(for: shareText), !DewuLogStore.hasDataRootAccess() {
            downloadStatusText = "未授权得物日志文件夹，将只使用分享页公开媒体。"
        }
        let task = DownloadQueueTask(
            id: UUID(),
            shareText: shareText,
            entries: entries,
            outputRoot: outputRoot,
            title: Self.downloadTaskTitle(for: shareText, entries: entries)
        )
        pendingDownloadTasks.append(task)
        downloadShareText = ""
        downloadInputResetID += 1
        isDownloading = true
        downloadStatusText = task.entries.count == 1 ? "已加入下载任务。" : "已加入 \(task.entries.count) 条链接。"
        if activeDownloadTask == nil {
            startNextDownloadTaskIfNeeded()
        } else {
            rebuildDownloadProgressItems()
        }
    }

    private func startNextDownloadTaskIfNeeded() {
        guard activeDownloadTask == nil else { return }
        guard !pendingDownloadTasks.isEmpty else {
            isDownloading = false
            activeDownloadProgressState = nil
            rebuildDownloadProgressItems()
            return
        }
        let task = pendingDownloadTasks.removeFirst()
        activeDownloadTask = task
        isDownloading = true
        rebuildDownloadProgressItems(activeCompletedCount: 0, activeDetail: "解析分享链接", activeUnitProgress: 0)
        Task { await performQueuedDownloadTask(task) }
    }

    private func performQueuedDownloadTask(_ task: DownloadQueueTask) async {
        var messages: [String] = []
        var failures: [String] = []

        for (index, entry) in task.entries.enumerated() {
            rebuildDownloadProgressItems(
                activeCompletedCount: index,
                activeDetail: Self.downloadProgressDetail(for: entry, fraction: 0),
                activeUnitProgress: 0
            )
            let result = await Task.detached(priority: .userInitiated) {
                await Self.withSecurityScopedAccess(to: task.outputRoot) {
                    await Self.runSingleDownloader(shareText: entry, destinationRoot: task.outputRoot) { fraction in
                        let clampedFraction = min(max(fraction, 0), 1)
                        let unitProgress = clampedFraction * DownloadProgressMilestone.downloadEnd
                        let detail = Self.downloadProgressDetail(for: entry, fraction: clampedFraction)
                        await MainActor.run {
                            self.rebuildDownloadProgressItems(
                                activeCompletedCount: index,
                                activeDetail: detail,
                                activeUnitProgress: unitProgress
                            )
                        }
                    }
                }
            }.value
            switch result {
            case .success(let message):
                if !message.isEmpty {
                    messages.append(task.entries.count == 1 ? message : "第 \(index + 1) 个链接完成：\n\(message)")
                }
            case .failure(let message):
                failures.append(task.entries.count == 1 ? message : "第 \(index + 1) 个链接失败：\(message)")
            }
            rebuildDownloadProgressItems(activeCompletedCount: index + 1, activeDetail: "整理下载结果", activeUnitProgress: 0)
        }

        await holdCompletedDownloadProgress(for: task)

        if messages.isEmpty {
            downloadStatusText = failures.isEmpty ? "下载完成。" : "下载失败：\(failures.joined(separator: "\n"))"
        } else {
            if !failures.isEmpty {
                messages.append("部分链接失败：\n\(failures.joined(separator: "\n"))")
            }
            downloadStatusText = messages.joined(separator: "\n\n")
        }

        refreshDownloads()
        if activeDownloadTask?.id == task.id {
            activeDownloadTask = nil
        }
        startNextDownloadTaskIfNeeded()
    }

    private func holdCompletedDownloadProgress(for task: DownloadQueueTask) async {
        guard activeDownloadTask?.id == task.id,
              downloadProgressItems.first?.id == task.id,
              downloadProgressItems.first?.progress ?? 0 >= 1 else {
            return
        }
        try? await Task.sleep(nanoseconds: Self.completedDownloadProgressHoldNanoseconds)
    }

    private func rebuildDownloadProgressItems(
        activeCompletedCount: Int? = nil,
        activeDetail: String? = nil,
        activeUnitProgress: CGFloat? = nil
    ) {
        var items: [DownloadProgressItem] = []
        if let activeDownloadTask {
            let totalCount = max(activeDownloadTask.entries.count, 1)
            let previousState = activeDownloadProgressState
            let candidateState = DownloadProgressState(
                completedCount: activeCompletedCount ?? previousState?.completedCount ?? 0,
                detail: activeDetail ?? previousState?.detail ?? "等待下载",
                unitProgress: activeUnitProgress ?? previousState?.unitProgress ?? 0
            )
            let state: DownloadProgressState
            if let previousState,
               overallProgress(for: candidateState, totalCount: totalCount) < overallProgress(for: previousState, totalCount: totalCount) {
                state = DownloadProgressState(
                    completedCount: previousState.completedCount,
                    detail: candidateState.detail,
                    unitProgress: previousState.unitProgress
                )
            } else {
                state = candidateState
            }
            activeDownloadProgressState = state
            items.append(DownloadProgressItem(
                id: activeDownloadTask.id,
                title: activeDownloadTask.title,
                detail: state.detail,
                completedCount: state.completedCount,
                totalCount: totalCount,
                currentUnitProgress: min(max(state.unitProgress, 0), 1),
                isActive: true
            ))
        }
        for task in pendingDownloadTasks.prefix(2) {
            items.append(DownloadProgressItem(
                id: task.id,
                title: task.title,
                detail: "等待前一个任务",
                completedCount: 0,
                totalCount: max(task.entries.count, 1),
                currentUnitProgress: 0,
                isActive: false
            ))
        }
        downloadProgressItems = items
    }

    private func overallProgress(for state: DownloadProgressState, totalCount: Int) -> CGFloat {
        guard totalCount > 0 else { return 0 }
        let completed = min(max(state.completedCount, 0), totalCount)
        let unitProgress = min(max(state.unitProgress, 0), 1)
        return min((CGFloat(completed) + unitProgress) / CGFloat(totalCount), 1)
    }

    func refreshDownloads() {
        guard !isRefreshingDownloads else {
            needsAnotherDownloadRefresh = true
            return
        }
        guard let folder = authorizedDownloadOutputFolderForUserAction() else { return }
        isRefreshingDownloads = true
        Task {
            repeat {
                self.needsAnotherDownloadRefresh = false
                let scannedItems = await Self.downloadItems(in: folder, excluding: self.downloadComposedFolder)
                guard self.downloadOutputFolder == folder else {
                    self.isRefreshingDownloads = false
                    return
                }
                self.applyDownloadedItems(scannedItems)
            } while self.needsAnotherDownloadRefresh
            self.isRefreshingDownloads = false
        }
    }

    private func applyDownloadedItems(_ scannedItems: DownloadScanResult) {
        downloadPairs = scannedItems.pairs
        downloadPhotos = scannedItems.photos
        downloadVideos = scannedItems.videos
        downloadModifiedTimesByPath = scannedItems.modifiedTimesByPath

        let downloadedStems = Set(scannedItems.pairs.map { Self.completedStem(for: $0.imageURL) })
        downloadCompleted = Self.sortedCompletedItems(downloadCompleted.filter {
            downloadedStems.contains(Self.completedStem(for: $0.imageURL))
        })
        saveDownloadCompletedRecords()
        rebuildVisibleDownloadItems()
        retainVisibleDownloadSelection()
        let composedStems = Set(downloadCompleted.map { Self.completedStem(for: $0.imageURL) })
        let composedCount = downloadPairs.filter { pair in
            composedStems.contains(Self.completedStem(for: pair.imageURL))
        }.count
        let itemCount = downloadPairs.count + downloadPhotos.count + downloadVideos.count
        downloadStatusText = itemCount == 0
            ? "输入分享链接开始下载。"
            : "已识别 \(itemCount) 个素材，已合成 \(composedCount) 组。"
    }

    func processDownloadPairs() async {
        let visiblePairIDs = processableVisibleDownloadPairIDs
        let selectedPairIDs = Set(selectedDownloadItemIDs.compactMap(Self.downloadPairID))
        let targetIDs = selectedDownloadItemIDs.isEmpty ? visiblePairIDs : selectedPairIDs
        guard !isProcessingDownloads, !targetIDs.isEmpty else { return }

        isProcessingDownloads = true
        downloadStatusText = "正在合成..."

        let composedFolder = outputFolder
        let targetPairs = downloadPairs.filter { targetIDs.contains($0.id) }
        setDownloadPairStatus(for: targetIDs, status: .running)
        rebuildVisibleDownloadItems()
        let results = await runCompositionTasks(for: targetPairs, outputFolder: composedFolder)

        for compositionResult in results {
            let pair = compositionResult.pair
            guard let index = downloadPairs.firstIndex(where: { $0.id == compositionResult.pairID }) else {
                continue
            }
            switch compositionResult.result {
            case .success(let message):
                downloadPairs[index].status = .finished
                downloadPairs[index].message = message
                if var completedItem = Self.completedItem(for: pair, in: composedFolder) {
                    if importToPhotos {
                        let targetAlbumName = addToAlbum ? Self.appDisplayName : nil
                        switch await PhotoLibraryImporter.importLivePhotoPair(completedItem, albumName: targetAlbumName) {
                        case .success:
                            completedItem.importedToPhotos = true
                            importedDownloadCompletedStems.insert(Self.completedStem(for: pair.imageURL))
                            saveImportedDownloadCompletedStems()
                            importedCompletedStems.insert(Self.completedStem(for: pair.imageURL))
                            saveImportedCompletedStems()
                        case .failure(let message):
                            downloadPairs[index].status = .failed
                            downloadPairs[index].message = "导入失败：\(message)"
                            continue
                        }
                    }
                    mergeDownloadCompletedItem(completedItem)
                    mergeCompletedItem(completedItem)
                }
                selectedDownloadItemIDs.remove("pair:\(pair.id)")
            case .failure(let message):
                downloadPairs[index].status = .failed
                downloadPairs[index].message = message
            }
        }

        isProcessingDownloads = false
        rebuildVisibleDownloadItems()
        retainVisibleDownloadSelection()
        let failedCount = downloadPairs.filter { targetIDs.contains($0.id) && $0.status == .failed }.count
        downloadStatusText = failedCount == 0 ? "下载照片已完成。" : "完成，\(failedCount) 组失败。"
    }

    func importSelectedDownloadMediaToPhotos(addToAlbum: Bool) async {
        let mediaURLs = selectedDownloadMediaURLs
        guard !isImportingDownloadMedia, !mediaURLs.isEmpty else { return }
        guard mediaURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            downloadStatusText = "未找到源文件。"
            return
        }

        isImportingDownloadMedia = true
        defer { isImportingDownloadMedia = false }

        downloadStatusText = addToAlbum ? "正在导入并添加到相簿..." : "正在导入到系统相册..."
        let targetAlbumName = addToAlbum ? Self.appDisplayName : nil
        let result = await PhotoLibraryImporter.importMediaFiles(mediaURLs, albumName: targetAlbumName)

        switch result {
        case .success(let count):
            if count == 0 {
                downloadStatusText = "没有可导入的照片或视频。"
            } else if let targetAlbumName {
                downloadStatusText = "已导入 \(count) 个项目到系统相册，并添加到“\(targetAlbumName)”相簿。"
            } else {
                downloadStatusText = "已导入 \(count) 个项目到系统相册。"
            }
        case .failure(let message):
            downloadStatusText = "导入失败：\(message)"
        }
    }

    func clearVisibleDownloads(deleteFiles: Bool) {
        let selectedIDs = selectedDownloadItemIDs
        let itemsToClear = selectedIDs.isEmpty ? visibleDownloadItems : visibleDownloadItems.filter { selectedIDs.contains($0.id) }
        guard !itemsToClear.isEmpty else { return }

        let pairIDs = Set(itemsToClear.compactMap { item -> PairItem.ID? in
            if case .pair(let id) = item.kind { return id }
            return nil
        })
        let photoPaths = Set(itemsToClear.compactMap { item -> String? in
            if case .photo(let path) = item.kind { return path }
            return nil
        })
        let videoPaths = Set(itemsToClear.compactMap { item -> String? in
            if case .video(let path) = item.kind { return path }
            return nil
        })
        let removedPairStems = Set(downloadPairs
            .filter { pairIDs.contains($0.id) }
            .map { Self.completedStem(for: $0.imageURL) })

        if deleteFiles {
            if let folder = authorizedDownloadOutputFolderForUserAction() {
                Self.withSecurityScopedAccess(to: folder) {
                    for pair in downloadPairs where pairIDs.contains(pair.id) {
                        Self.moveToTrash(pair.imageURL)
                        Self.moveToTrash(pair.videoURL)
                    }
                    for photo in downloadPhotos where photoPaths.contains(photo.standardizedFileURL.path) {
                        Self.moveToTrash(photo)
                    }
                    for video in downloadVideos where videoPaths.contains(video.standardizedFileURL.path) {
                        Self.moveToTrash(video)
                    }
                }
            }
        }

        ThumbnailCollectionAnimation.perform {
            downloadPairs.removeAll { pairIDs.contains($0.id) }
            downloadPhotos.removeAll { photoPaths.contains($0.standardizedFileURL.path) }
            downloadVideos.removeAll { videoPaths.contains($0.standardizedFileURL.path) }
            downloadCompleted.removeAll { removedPairStems.contains(Self.completedStem(for: $0.imageURL)) }
        }
        for item in itemsToClear {
            downloadModifiedTimesByPath.removeValue(forKey: item.imageURL.standardizedFileURL.path)
        }
        rebuildVisibleDownloadItems()
        selectedDownloadItemIDs.subtract(Set(itemsToClear.map(\.id)))
        saveDownloadCompletedRecords()
        downloadStatusText = deleteFiles ? "已删除 \(itemsToClear.count) 个项目，并将源文件移到废纸篓。" : "已移除 \(itemsToClear.count) 个项目。"
    }

    func importCompletedToPhotos(addToAlbum targetAddToAlbum: Bool? = nil) async {
        let selectedItems = selectedCompletedItems
        guard !isImportingCompleted, !selectedItems.isEmpty else { return }
        guard selectedItems.allSatisfy(\.sourceExists) else {
            statusText = "未找到源文件。"
            return
        }
        let pairs = selectedItems.compactMap { item -> (URL, URL)? in
            guard let movieURL = item.movieURL else { return nil }
            return (item.imageURL, movieURL)
        }
        guard pairs.count == selectedItems.count else {
            statusText = "未找到源文件。"
            return
        }

        isImportingCompleted = true
        defer { isImportingCompleted = false }

        let targetAlbumName = (targetAddToAlbum ?? completedAddToAlbum) ? Self.appDisplayName : nil
        let result = await PhotoLibraryImporter.importLivePhotoPairs(pairs, albumName: targetAlbumName)

        switch result {
        case .success(let count):
            if count == 0 {
                statusText = "没有可导入的 Live Photo。"
            } else if let targetAlbumName {
                statusText = "已导入 \(count) 组到系统相册，并添加到“\(targetAlbumName)”相簿。"
            } else {
                statusText = "已导入 \(count) 组到系统相册。"
            }
            let importedIDs = Set(selectedItems.map(\.id))
            for index in completed.indices where importedIDs.contains(completed[index].id) {
                completed[index].importedToPhotos = true
            }
            importedCompletedStems.formUnion(selectedItems.map { Self.completedStem(for: $0.imageURL) })
            saveImportedCompletedStems()
            saveCompletedRecords()
            retainVisibleCompletedSelection()
        case .failure(let message):
            statusText = "导入失败：\(message)"
        }
    }

    func processPairs() async {
        let targetIDs = selectedPairIDs.isEmpty ? Set(pairs.map(\.id)) : selectedPairIDs
        guard !isProcessing, !targetIDs.isEmpty else { return }
        isProcessing = true
        statusText = "正在合成..."

        let targetPairs = pairs.filter { targetIDs.contains($0.id) }
        setPairStatus(for: targetIDs, status: .running)
        let results = await runCompositionTasks(for: targetPairs, outputFolder: outputFolder)

        for compositionResult in results {
            let pair = compositionResult.pair
            guard let index = pairs.firstIndex(where: { $0.id == compositionResult.pairID }) else {
                continue
            }
            switch compositionResult.result {
            case .success(let message):
                pairs[index].status = .finished
                pairs[index].message = message
                if var completedItem = Self.completedItem(for: pair, in: outputFolder) {
                    if importToPhotos {
                        let targetAlbumName = addToAlbum ? Self.appDisplayName : nil
                        switch await PhotoLibraryImporter.importLivePhotoPair(completedItem, albumName: targetAlbumName) {
                        case .success:
                            completedItem.importedToPhotos = true
                            importedCompletedStems.insert(Self.completedStem(for: pair.imageURL))
                            saveImportedCompletedStems()
                        case .failure(let message):
                            pairs[index].status = .failed
                            pairs[index].message = "导入失败：\(message)"
                            continue
                        }
                    }
                    mergeCompletedItem(completedItem)
                }
                removeQueuedFiles(for: pair)
                selectedPairIDs.remove(pair.id)
                pairs.remove(at: index)
            case .failure(let message):
                pairs[index].status = .failed
                pairs[index].message = message
            }
        }

        isProcessing = false
        retainSelectedPairIDs()
        let failedCount = pairs.filter { targetIDs.contains($0.id) && $0.status == .failed }.count
        statusText = failedCount == 0 ? "选中的照片已完成。" : "完成，\(failedCount) 组失败。"
    }

    private func removeQueuedFiles(for pair: PairItem) {
        let completedURLs = Set([pair.imageURL.standardizedFileURL, pair.videoURL.standardizedFileURL])
        files.removeAll { completedURLs.contains($0.standardizedFileURL) }
    }

    private func setPairStatus(for targetIDs: Set<PairItem.ID>, status: PairItem.Status) {
        for index in pairs.indices where targetIDs.contains(pairs[index].id) {
            pairs[index].status = status
        }
    }

    private func setDownloadPairStatus(for targetIDs: Set<PairItem.ID>, status: PairItem.Status) {
        for index in downloadPairs.indices where targetIDs.contains(downloadPairs[index].id) {
            downloadPairs[index].status = status
        }
    }

    private func runCompositionTasks(
        for targetPairs: [PairItem],
        outputFolder: URL
    ) async -> [LivePhotoCompositionResult] {
        guard !targetPairs.isEmpty else { return [] }
        let limit = min(Self.maxConcurrentLivePhotoCompositions, targetPairs.count)
        var results: [LivePhotoCompositionResult] = []
        results.reserveCapacity(targetPairs.count)

        await withTaskGroup(of: LivePhotoCompositionResult.self) { group in
            var nextIndex = 0

            func enqueueNextTask() {
                guard nextIndex < targetPairs.count else { return }
                let pair = targetPairs[nextIndex]
                nextIndex += 1
                group.addTask(priority: .userInitiated) {
                    let result = await LivePhotoToolRunner.run(for: pair, outputFolder: outputFolder)
                    return LivePhotoCompositionResult(pairID: pair.id, pair: pair, result: result)
                }
            }

            for _ in 0..<limit {
                enqueueNextTask()
            }

            while let result = await group.next() {
                results.append(result)
                enqueueNextTask()
            }
        }

        let resultByID = Dictionary(uniqueKeysWithValues: results.map { ($0.pairID, $0) })
        return targetPairs.compactMap { resultByID[$0.id] }
    }

    private func mergeCompletedItem(_ item: CompletedItem) {
        var mergedByID = Dictionary(uniqueKeysWithValues: completed.map { ($0.id, $0) })
        var mergedItem = mergedByID[item.id] ?? item
        mergedItem.moviePath = item.moviePath
        mergedItem.modifiedTime = item.modifiedTime
        mergedItem.importedToPhotos = mergedItem.importedToPhotos || item.importedToPhotos
        mergedByID[item.id] = mergedItem
        completed = Self.sortedCompletedItems(Array(mergedByID.values))
        saveCompletedRecords()
        retainVisibleCompletedSelection()
    }

    private func mergeDownloadCompletedItem(_ item: CompletedItem) {
        var mergedByID = Dictionary(uniqueKeysWithValues: downloadCompleted.map { ($0.id, $0) })
        var mergedItem = mergedByID[item.id] ?? item
        mergedItem.moviePath = item.moviePath
        mergedItem.modifiedTime = item.modifiedTime
        mergedItem.importedToPhotos = mergedItem.importedToPhotos || item.importedToPhotos
        mergedByID[item.id] = mergedItem
        downloadCompleted = Self.sortedCompletedItems(Array(mergedByID.values))
        saveDownloadCompletedRecords()
        rebuildVisibleDownloadItems()
        retainVisibleDownloadSelection()
    }

    func refreshCompleted() {
        guard !isRefreshingCompleted else { return }
        guard let folder = authorizedOutputFolderForUserAction() else { return }
        isRefreshingCompleted = true
        Task {
            let scannedItems = await Self.completedItems(in: folder)
            self.isRefreshingCompleted = false
            guard self.outputFolder == folder else { return }

            let existingByID = Dictionary(uniqueKeysWithValues: self.completed.map { ($0.id, $0) })
            let refreshedItems = Self.sortedCompletedItems(scannedItems.map { scannedItem in
                var mergedItem = scannedItem
                if let existingItem = existingByID[scannedItem.id] {
                    mergedItem.importedToPhotos = existingItem.importedToPhotos
                }
                if self.importedCompletedStems.contains(Self.completedStem(for: scannedItem.imageURL)) {
                    mergedItem.importedToPhotos = true
                }
                return mergedItem
            })

            if refreshedItems != self.completed {
                self.completed = refreshedItems
                self.saveCompletedRecords()
                self.retainVisibleCompletedSelection()
            }
        }
    }

    func retainVisibleCompletedSelection() {
        let visibleIDs = Set(visibleCompleted.map(\.id))
        selectedCompletedIDs = selectedCompletedIDs.intersection(visibleIDs)
    }

    func retainSelectedPairIDs() {
        let visibleIDs = Set(pairs.map(\.id))
        selectedPairIDs = selectedPairIDs.intersection(visibleIDs)
    }

    func retainVisibleDownloadSelection() {
        let visibleIDs = Set(visibleDownloadItems.map(\.id))
        selectedDownloadItemIDs = selectedDownloadItemIDs.intersection(visibleIDs)
    }

    func clearVisibleCompleted(deleteFiles: Bool) {
        let selectedIDs = selectedCompletedIDs
        let itemsToClear = selectedIDs.isEmpty ? visibleCompleted : visibleCompleted.filter { selectedIDs.contains($0.id) }
        guard !itemsToClear.isEmpty else { return }
        let clearedStems = Set(itemsToClear.map { Self.completedStem(for: $0.imageURL) })

        if deleteFiles {
            guard let folder = authorizedOutputFolderForUserAction() else { return }
            Self.withSecurityScopedAccess(to: folder) {
                for item in itemsToClear {
                    Self.moveToTrash(item.imageURL)
                    if let movieURL = item.movieURL {
                        Self.moveToTrash(movieURL)
                    }
                }
            }
        }

        let clearedIDs = Set(itemsToClear.map(\.id))
        ThumbnailCollectionAnimation.perform {
            completed.removeAll { clearedIDs.contains($0.id) }
            if deleteFiles {
                downloadCompleted.removeAll { clearedStems.contains(Self.completedStem(for: $0.imageURL)) }
            }
        }
        selectedCompletedIDs.subtract(clearedIDs)
        if deleteFiles {
            importedCompletedStems.subtract(clearedStems)
            importedDownloadCompletedStems.subtract(clearedStems)
        }
        saveCompletedRecords()
        if deleteFiles {
            saveImportedCompletedStems()
            saveDownloadCompletedRecords()
            saveImportedDownloadCompletedStems()
            rebuildVisibleDownloadItems()
            retainVisibleDownloadSelection()
        }
        if selectedIDs.isEmpty {
            statusText = deleteFiles ? "已清空 \(itemsToClear.count) 个完成项目，并将源文件移到废纸篓。" : "已清空 \(itemsToClear.count) 个完成项目。"
        } else {
            statusText = deleteFiles ? "已删除 \(itemsToClear.count) 个完成项目，并将源文件移到废纸篓。" : "已删除 \(itemsToClear.count) 个完成项目。"
        }
    }

    private nonisolated static func completedStem(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }

    private nonisolated static func completedItem(for pair: PairItem, in folder: URL) -> CompletedItem? {
        let fileManager = FileManager.default
        let stem = completedStem(for: pair.imageURL)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var imageURL: URL?
        var movieURL: URL?
        var modifiedDate = Date.distantPast
        for url in urls where completedStem(for: url) == stem {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }
            if FileSystemUtilities.isImage(url) {
                imageURL = url
                modifiedDate = values.contentModificationDate ?? modifiedDate
            } else if FileSystemUtilities.isVideo(url) {
                movieURL = url
            }
        }

        guard let imageURL else { return nil }
        return CompletedItem(
            imagePath: imageURL.path,
            moviePath: movieURL?.path,
            modifiedTime: modifiedDate.timeIntervalSince1970
        )
    }

    private nonisolated static func sortedCompletedItems(_ items: [CompletedItem]) -> [CompletedItem] {
        items.sorted { lhs, rhs in
            if lhs.modifiedTime == rhs.modifiedTime {
                return lhs.imageURL.lastPathComponent.localizedStandardCompare(rhs.imageURL.lastPathComponent) == .orderedAscending
            }
            return lhs.modifiedTime > rhs.modifiedTime
        }
    }

    private nonisolated static func completedItems(in folder: URL) async -> [CompletedItem] {
        await Task.detached(priority: .utility) { () -> [CompletedItem] in
            withSecurityScopedAccess(to: folder) {
                let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
                guard let urls = try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles]
                ) else {
                    return []
                }

                var imageByStem: [String: (url: URL, date: Date)] = [:]
                var movieByStem: [String: URL] = [:]
                for url in urls {
                    guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                          values.isRegularFile == true else {
                        continue
                    }
                    let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                    if FileSystemUtilities.isImage(url) {
                        imageByStem[stem] = (url, values.contentModificationDate ?? .distantPast)
                    } else if FileSystemUtilities.isVideo(url) {
                        movieByStem[stem] = url
                    }
                }

                return sortedCompletedItems(imageByStem
                    .map { stem, image in
                        CompletedItem(
                            imagePath: image.url.path,
                            moviePath: movieByStem[stem]?.path,
                            modifiedTime: image.date.timeIntervalSince1970
                        )
                    }
                )
            }
        }.value
    }

    private static func loadCompletedRecords() -> [CompletedItem] {
        guard let data = UserDefaults.standard.data(forKey: completedRecordsDefaultsKey),
              let records = try? JSONDecoder().decode([CompletedItem].self, from: data) else {
            return []
        }
        return records
    }

    private static func loadDownloadCompletedRecords() -> [CompletedItem] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: downloadCompletedRecordsDefaultsKey),
              let records = try? JSONDecoder().decode([CompletedItem].self, from: data) else {
            return []
        }
        return records
    }

    private func saveCompletedRecords() {
        guard let data = try? JSONEncoder().encode(completed) else { return }
        UserDefaults.standard.set(data, forKey: Self.completedRecordsDefaultsKey)
    }

    private func saveDownloadCompletedRecords() {
        guard let data = try? JSONEncoder().encode(downloadCompleted) else { return }
        UserDefaults.standard.set(data, forKey: Self.downloadCompletedRecordsDefaultsKey)
    }

    private static func loadImportedCompletedStems() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: importedCompletedStemsDefaultsKey) ?? [])
    }

    private static func loadImportedDownloadCompletedStems() -> Set<String> {
        Set(
            UserDefaults.standard.stringArray(forKey: importedDownloadCompletedStemsDefaultsKey)
                ?? []
        )
    }

    private func saveImportedCompletedStems() {
        UserDefaults.standard.set(importedCompletedStems.sorted(), forKey: Self.importedCompletedStemsDefaultsKey)
    }

    private func saveImportedDownloadCompletedStems() {
        UserDefaults.standard.set(importedDownloadCompletedStems.sorted(), forKey: Self.importedDownloadCompletedStemsDefaultsKey)
    }

    nonisolated static func opaqueSRGBImageForJPEG(from image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        )

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func rebuildPairs() {
        let images = files.filter(FileSystemUtilities.isImage).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let videos = files.filter(FileSystemUtilities.isVideo).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var usedVideos = Set<URL>()
        var newPairs: [PairItem] = []

        let videosByStem = Dictionary(grouping: videos, by: { $0.deletingPathExtension().lastPathComponent.lowercased() })
        for image in images {
            let stem = image.deletingPathExtension().lastPathComponent.lowercased()
            if let video = videosByStem[stem]?.first(where: { !usedVideos.contains($0) }) {
                usedVideos.insert(video)
                newPairs.append(PairItem(imageURL: image, videoURL: video))
            }
        }

        let unmatchedImages = images.filter { image in
            !newPairs.contains(where: { $0.imageURL == image })
        }
        let unmatchedVideos = videos.filter { !usedVideos.contains($0) }

        if unmatchedImages.count == unmatchedVideos.count {
            for (image, video) in zip(unmatchedImages, unmatchedVideos) {
                newPairs.append(PairItem(imageURL: image, videoURL: video))
            }
        }

        pairs = newPairs
        retainSelectedPairIDs()
        statusText = newPairs.isEmpty ? "拖入照片和视频，或点击添加文件。" : "已准备 \(newPairs.count) 组 Live Photo。"
    }

    private nonisolated static func runDewuDownloader(
        shareText: String,
        destinationRoot: URL,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async -> ToolRunResult {
        await DewuNativeDownloader.run(shareText: shareText, destinationRoot: destinationRoot, progress: progress)
    }

    private nonisolated static var maxConcurrentShareDownloads: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 6)
    }

    private nonisolated static var maxConcurrentLivePhotoCompositions: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount - 1, 2), 4)
    }

    private nonisolated static func downloadTaskTitle(for shareText: String, entries: [String]) -> String {
        let platform: String
        if isDouyinShareText(shareText) {
            platform = "抖音"
        } else if isXHSShareText(shareText) {
            platform = "小红书"
        } else if isDewuShareText(shareText) {
            platform = "得物"
        } else {
            platform = "下载"
        }

        guard entries.count > 1 else {
            return "\(platform)链接"
        }
        return "\(platform)链接 \(entries.count) 条"
    }

    private nonisolated static func downloadProgressDownloadDetail(for entry: String) -> String {
        if isDouyinShareText(entry) {
            return "保存抖音媒体"
        } else if isXHSShareText(entry) {
            return "保存小红书媒体"
        } else if isDewuShareText(entry) {
            return "保存得物媒体"
        }
        return "保存媒体文件"
    }

    private nonisolated static func downloadProgressDetail(for entry: String, fraction: CGFloat) -> String {
        if fraction < 0.04 {
            return "解析分享链接"
        }
        if fraction < DownloadProgressMilestone.scanEnd {
            if isDouyinShareText(entry) {
                return "查找抖音可用媒体"
            } else if isXHSShareText(entry) {
                return "读取小红书媒体信息"
            } else if isDewuShareText(entry) {
                return "读取得物媒体信息"
            }
            return "读取媒体信息"
        }
        if fraction < DownloadProgressMilestone.downloadEnd {
            return downloadProgressDownloadDetail(for: entry)
        }
        return "整理下载结果"
    }

    private nonisolated static func downloadShareEntries(from text: String) -> [String] {
        let pattern = #"(?i)(?:https?://)?(?:www\.)?(?:xhslink\.com|xiaohongshu\.com|dw4\.co|dewu\.com|v\.douyin\.com|douyin\.com|iesdouyin\.com)/[^\s"<>\\^`{|}，。；！？、【】《》]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var entries: [String] = []
        var seen = Set<String>()

        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let entry = normalizedDownloadShareEntry(String(text[matchRange]))
            guard !entry.isEmpty, seen.insert(entry).inserted else { continue }
            entries.append(entry)
        }
        return entries
    }

    private nonisolated static func shouldPrepareDewuLogAccess(for text: String) -> Bool {
        let entries = downloadShareEntries(from: text)
        guard !entries.isEmpty else { return false }
        return entries.contains { entry in
            let includesXHS = isXHSShareText(entry)
            let includesDouyin = isDouyinShareText(entry)
            return isDewuShareText(entry) || (!includesXHS && !includesDouyin)
        }
    }

    private nonisolated static func normalizedDownloadShareEntry(_ value: String) -> String {
        var entry = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = entry.unicodeScalars.last,
              CharacterSet(charactersIn: ".,，。；;！!？?、】》)）").contains(last) {
            entry.removeLast()
        }
        if !entry.lowercased().hasPrefix("http://"), !entry.lowercased().hasPrefix("https://") {
            entry = entry.lowercased().hasPrefix("xhslink.com")
                ? "http://\(entry)"
                : "https://\(entry)"
        }
        return entry
    }

    private nonisolated static func runSingleDownloader(
        shareText: String,
        destinationRoot: URL,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async -> ToolRunResult {
        let includesXHS = isXHSShareText(shareText)
        let includesDewu = isDewuShareText(shareText)
        let includesDouyin = isDouyinShareText(shareText)
        var messages: [String] = []

        if includesDouyin {
            switch await DouyinNativeDownloader.run(shareText: shareText, destinationRoot: destinationRoot, progress: progress) {
            case .success(let message):
                if !message.isEmpty { messages.append(message) }
            case .failure(let message):
                return .failure(message)
            }
        }

        if includesXHS {
            switch await XHSNativeDownloader.run(shareText: shareText, destinationRoot: destinationRoot, progress: progress) {
            case .success(let message):
                if !message.isEmpty { messages.append(message) }
            case .failure(let message):
                return .failure(message)
            }
        }

        if includesDewu || (!includesXHS && !includesDouyin) {
            switch await runDewuDownloader(shareText: shareText, destinationRoot: destinationRoot, progress: progress) {
            case .success(let message):
                if !message.isEmpty { messages.append(message) }
            case .failure(let message):
                return (includesXHS || includesDouyin) ? .success(messages.joined(separator: "\n\n")) : .failure(message)
            }
        }

        if messages.isEmpty {
            return .failure("没有识别到支持的分享链接。")
        }
        return .success(messages.joined(separator: "\n\n"))
    }

    private nonisolated static func isXHSShareText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("xhslink.com")
            || lowered.contains("xiaohongshu.com")
            || text.contains("小红书")
    }

    private nonisolated static func isDewuShareText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("dw4.co")
            || lowered.contains("dewu.com")
            || text.contains("得物")
    }

    private nonisolated static func isDouyinShareText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("v.douyin.com")
            || lowered.contains("douyin.com")
            || lowered.contains("iesdouyin.com")
            || text.contains("抖音")
    }

    private nonisolated static func downloadPairID(from gridItemID: DownloadGridItem.ID) -> PairItem.ID? {
        guard gridItemID.hasPrefix("pair:") else { return nil }
        return String(gridItemID.dropFirst(5))
    }

    private nonisolated static func downloadMediaPath(from gridItemID: DownloadGridItem.ID, prefix: String) -> String? {
        guard gridItemID.hasPrefix(prefix) else { return nil }
        return String(gridItemID.dropFirst(prefix.count))
    }

    private nonisolated static func downloadMediaURL(for item: DownloadGridItem) -> URL? {
        switch item.kind {
        case .pair:
            nil
        case .photo(let path), .video(let path):
            URL(fileURLWithPath: path)
        }
    }

    private nonisolated static func downloadPostGroupKey(for url: URL, root: URL) -> String {
        let itemURL = url.standardizedFileURL
        let parentURL = itemURL.deletingLastPathComponent().standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let parentPath = parentURL.path
        let stem = normalizedDownloadPostStem(itemURL.deletingPathExtension().lastPathComponent)
        if parentPath == rootPath {
            return parentPath + "/" + stem
        }
        return parentPath + "/" + stem
    }

    private nonisolated static func normalizedDownloadPostStem(_ stem: String) -> String {
        let pattern = #"_[0-9]{2,}$"#
        return stem.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private nonisolated static func downloadItems(in folder: URL, excluding excludedFolder: URL) async -> DownloadScanResult {
        await Task.detached(priority: .utility) { () -> DownloadScanResult in
            let fileManager = FileManager.default
            let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
            guard let enumerator = fileManager.enumerator(
                at: folder,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            ) else {
                return DownloadScanResult(pairs: [], photos: [], videos: [])
            }

            let excludedPath = excludedFolder.standardizedFileURL.path
            var images: [URL] = []
            var videos: [URL] = []
            var modifiedTimesByPath: [String: TimeInterval] = [:]
            while let url = enumerator.nextObject() as? URL {
                let standardizedURL = url.standardizedFileURL
                if standardizedURL.path == excludedPath || standardizedURL.path.hasPrefix(excludedPath + "/") {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? standardizedURL.resourceValues(forKeys: Set(resourceKeys)),
                      values.isRegularFile == true else {
                    continue
                }
                modifiedTimesByPath[standardizedURL.path] = (values.contentModificationDate ?? .distantPast).timeIntervalSince1970
                if FileSystemUtilities.isImage(standardizedURL) {
                    images.append(standardizedURL)
                } else if FileSystemUtilities.isVideo(standardizedURL) {
                    videos.append(standardizedURL)
                }
            }

            let sortedImages = images.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            let sortedVideos = videos.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            var usedVideos = Set<URL>()
            var usedImages = Set<URL>()
            var pairs: [PairItem] = []
            let videosByFolderAndStem = Dictionary(grouping: sortedVideos) {
                $0.deletingLastPathComponent().path + "/" + $0.deletingPathExtension().lastPathComponent.lowercased()
            }

            for image in sortedImages {
                let key = image.deletingLastPathComponent().path + "/" + image.deletingPathExtension().lastPathComponent.lowercased()
                if let video = videosByFolderAndStem[key]?.first(where: { !usedVideos.contains($0) }) {
                    usedImages.insert(image)
                    usedVideos.insert(video)
                    pairs.append(PairItem(imageURL: image, videoURL: video))
                }
            }

            let photos = sortedImages.filter { !usedImages.contains($0) }
            let unpairedVideos = sortedVideos.filter { !usedVideos.contains($0) }

            return DownloadScanResult(pairs: pairs, photos: photos, videos: unpairedVideos, modifiedTimesByPath: modifiedTimesByPath)
        }.value
    }

    nonisolated static func mediaFiles(in url: URL) -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            return [url]
        }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { itemURL in
            guard let values = try? itemURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  FileSystemUtilities.isImage(itemURL) || FileSystemUtilities.isVideo(itemURL) else {
                return nil
            }
            return itemURL
        }
    }
}
