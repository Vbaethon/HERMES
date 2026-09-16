import AppKit
import Darwin
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
    private static let downloadOutputFolderDefaultsKey = "DownloadOutputFolderPath.v1"
    private static let downloadOutputFolderBookmarkDefaultsKey = "DownloadOutputFolderBookmark.v1"
    private static let downloadCompletedRecordsDefaultsKey = "DownloadCompletedRecords.v1"
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
            downloadPresentationIsDirty = true
        }
    }
    @Published var downloadPairs: [PairItem] = [] { didSet { downloadPresentationIsDirty = true } }
    @Published var downloadPhotos: [URL] = [] { didSet { downloadPresentationIsDirty = true } }
    @Published var downloadVideos: [URL] = [] { didSet { downloadPresentationIsDirty = true } }
    @Published var downloadCompleted: [CompletedItem] = [] { didSet { downloadPresentationIsDirty = true } }
    @Published private(set) var visibleDownloadItemsCache: [DownloadGridItem] = []
    @Published var selectedDownloadItemIDs = Set<DownloadGridItem.ID>()
    @Published var downloadFilter: DownloadFilter = .all {
        didSet {
            guard downloadFilter != oldValue else { return }
            if downloadPresentationIsDirty { rebuildVisibleDownloadItems() }
            else { applyDownloadFilter() }
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

    @Published private(set) var operationNotices: [SidebarSection: String] = [:]
    private var lastDownloadFailure: String?

    func dismissOperationNotice(for page: SidebarSection) {
        operationNotices.removeValue(forKey: page)
        if page == .downloads { lastDownloadFailure = nil }
    }

    func recordDownloadFailures(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        lastDownloadFailure = [lastDownloadFailure, failures.joined(separator: "\n")].compactMap { $0 }.joined(separator: "\n")
        operationNotices[.downloads] = "下载存在失败：\n" + (lastDownloadFailure ?? "")
    }
    // Internal seams let regression tests suspend operations without touching Photos or the network.
    var compositionRunner: @Sendable (PairItem, URL) async -> ToolRunResult = { await LivePhotoToolRunner.run(for: $0, outputFolder: $1) }
    var photoPairImporter: (CompletedItem, String?) async -> PhotoImportResult = { await PhotoLibraryImporter.importLivePhotoPair($0, albumName: $1) }
    var trashFiles: ([URL]) -> String? = { FileSystemUtilities.trashGroup($0) }
    var moveFile: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    private var fileOperationsBusy: Bool { isProcessing || isProcessingDownloads || isImportingCompleted || isImportingDownloadMedia }
    private var completedMutationVersion = 0
    private var needsAnotherCompletedRefresh = false
    private var isRefreshingCompleted = false
    private var isRefreshingDownloads = false
    private var needsAnotherDownloadRefresh = false
    private var downloadModifiedTimesByPath: [String: TimeInterval] = [:] { didSet { downloadPresentationIsDirty = true } }
    private var downloadPresentationIsDirty = true
    private var allDownloadItemsCache: [DownloadGridItem] = []
    private var completedDownloadPairIDsCache = Set<PairItem.ID>()
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
    var canClearQueue: Bool { !fileOperationsBusy && (!files.isEmpty || !pairs.isEmpty) }
    var canProcessSelectedPairs: Bool { !fileOperationsBusy && !pairs.isEmpty }
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
    var canClearVisibleCompleted: Bool { !fileOperationsBusy && !visibleCompleted.isEmpty }
    var queueSubtitle: String {
        "已识别 \(imageCount) 张照片，\(videoCount) 个视频，已配对 \(pairs.count) 组。"
    }
    var downloadComposedFolder: URL {
        downloadOutputFolder.appendingPathComponent("已合成", isDirectory: true)
    }
    var visibleDownloadItems: [DownloadGridItem] {
        visibleDownloadItemsCache
    }

    private func completedDownloadPairIDs() -> Set<PairItem.ID> {
        if downloadPresentationIsDirty { rebuildVisibleDownloadItems() }
        return completedDownloadPairIDsCache
    }

    private func validatedCompletedDownloadPairIDs() -> Set<PairItem.ID> {
        let records = Dictionary(grouping: downloadCompleted.filter { $0.sourceImagePath != nil && $0.sourceVideoPath != nil }) {
            ($0.sourceImagePath ?? "") + "\n" + ($0.sourceVideoPath ?? "")
        }
        return Set(downloadPairs.compactMap { pair in
            records[pair.id]?.contains(where: { $0.represents(pair) }) == true ? pair.id : nil
        })
    }

    private func rebuildVisibleDownloadItems() {
        let completedIDs = validatedCompletedDownloadPairIDs()
        let pairItems = downloadPairs.map { pair in
            let isCompleted = completedIDs.contains(pair.id)
            let path = pair.imageURL.standardizedFileURL.path
            return DownloadGridItem(
                id: "pair:\(pair.id)",
                imageURL: pair.imageURL,
                modifiedTime: downloadModifiedTimesByPath[path] ?? .leastNonzeroMagnitude,
                status: pair.status == .failed ? .failed : (isCompleted ? .finished : pair.status),
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
        allDownloadItemsCache = allItems
        completedDownloadPairIDsCache = completedIDs
        downloadPresentationIsDirty = false
        applyDownloadFilter()
    }

    // Filtering an existing snapshot performs no filesystem validation or re-sorting.
    private func applyDownloadFilter() {
        let visible: [DownloadGridItem]
        switch downloadFilter {
        case .notComposed: visible = allDownloadItemsCache.filter { !$0.isCompleted }
        case .composed: visible = allDownloadItemsCache.filter(\.isCompleted)
        case .all: visible = allDownloadItemsCache
        }
        if visibleDownloadItemsCache != visible { visibleDownloadItemsCache = visible }
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
        guard !fileOperationsBusy, !isDownloading else { return false }
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
    var canClearVisibleDownloads: Bool { !fileOperationsBusy && !isDownloading && !visibleDownloadItems.isEmpty }
    var downloadSubtitle: String { downloadOutputFolder.path }
    private var processableVisibleDownloadPairIDs: Set<PairItem.ID> {
        guard downloadFilter != .composed else { return [] }
        let completedIDs = completedDownloadPairIDs()
        return Set(downloadPairs.compactMap { completedIDs.contains($0.id) ? nil : $0.id })
    }
    init(refreshOnInit: Bool = true) {
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
        completed = completed.map(Self.validateLegacyRecord)
        // Legacy source links cannot be inferred safely from a filename.
        downloadCompleted = downloadCompleted.map(Self.validateLegacyRecord)
        if refreshOnInit {
            refreshCompleted()
            refreshDownloads()
        }
    }

    private var importScanGeneration = 0
    private var pendingImportScans = 0
    var importFileScanner: ([URL]) async -> [URL] = { urls in
        await Task.detached(priority: .userInitiated) {
            urls.flatMap(ImporterModel.mediaFiles)
        }.value
    }

    func addFiles(_ urls: [URL]) async {
        let generation = importScanGeneration
        pendingImportScans += 1
        defer { pendingImportScans -= 1 }
        let scanned = await importFileScanner(urls)
        guard generation == importScanGeneration, !Task.isCancelled else { return }
        // Merge into the current collection after suspension, not a stale snapshot.
        var existing = Set(files.map(\.standardizedFileURL))
        let additions = scanned
            .filter { FileSystemUtilities.isImage($0) || FileSystemUtilities.isVideo($0) }
            .map(\.standardizedFileURL)
            .filter { existing.insert($0).inserted }

        files.append(contentsOf: additions)
        rebuildPairs()
    }

    func clear(deleteFiles: Bool = false) {
        guard !fileOperationsBusy else { return }
        let selectedIDs = selectedPairIDs
        if selectedIDs.isEmpty { importScanGeneration += 1 }
        let targets = selectedIDs.isEmpty ? pairs : pairs.filter { selectedIDs.contains($0.id) }
        var removedIDs = Set<PairItem.ID>()
        var removedURLs = Set<URL>()
        var errors: [String] = []
        for pair in targets {
            let urls = [pair.imageURL, pair.videoURL]
            if deleteFiles, let error = trashManagedFiles(urls) { errors.append(error); continue }
            removedIDs.insert(pair.id)
            removedURLs.formUnion(urls.map(\.standardizedFileURL))
        }
        // Unpaired files remain visible in the counts, and can also be cleared safely.
        if selectedIDs.isEmpty {
            let pairedURLs = Set(pairs.flatMap { [$0.imageURL, $0.videoURL] }.map(\.standardizedFileURL))
            for url in files where !pairedURLs.contains(url.standardizedFileURL) {
                if deleteFiles, let error = trashManagedFiles([url]) { errors.append(error); continue }
                removedURLs.insert(url.standardizedFileURL)
            }
        }
        ThumbnailCollectionAnimation.perform {
            files.removeAll { removedURLs.contains($0.standardizedFileURL) }
            pairs.removeAll { removedIDs.contains($0.id) }
        }
        selectedPairIDs.subtract(removedIDs)
        statusText = Self.clearMessage(count: removedURLs.count, deleteFiles: deleteFiles, errors: errors)
        operationNotices[.queue] = errors.isEmpty ? nil : statusText
    }

    private func trashManagedFiles(_ urls: [URL]) -> String? {
        Self.withSecurityScopedAccess(to: outputFolder) {
            Self.withSecurityScopedAccess(to: downloadOutputFolder) { trashFiles(urls) }
        }
    }

    private static func clearMessage(count: Int, deleteFiles: Bool, errors: [String]) -> String {
        let result = deleteFiles ? "已将 \(count) 个项目的文件移到废纸篓。" : "已移除 \(count) 个项目。"
        return errors.isEmpty ? result : result + "\n以下项目未移除，已保留记录：\n" + errors.joined(separator: "\n")
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
        // Best-effort cleanup is only used for empty download folders, never user-selected files.
        _ = FileSystemUtilities.trashGroup([url])
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
        let page = selection ?? .queue
        guard !fileOperationsBusy, !isDownloading, activeDownloadTask == nil, pendingDownloadTasks.isEmpty,
              !isRefreshingCompleted, !isRefreshingDownloads, pendingImportScans == 0 else {
            statusText = "请等待下载、合成、导入和刷新结束后，再移动导出文件夹。"
            operationNotices[page] = statusText
            return
        }
        let fm = FileManager.default
        let access = [outputFolder, parentFolder].filter { $0.startAccessingSecurityScopedResource() }
        defer { access.forEach { $0.stopAccessingSecurityScopedResource() } }
        let source = outputFolder.standardizedFileURL
        let destination = parentFolder.resolvingSymlinksInPath().appendingPathComponent(Self.outputFolderName, isDirectory: true).standardizedFileURL
        guard source != destination else { return }
        var createdDestination = false
        do {
            let resolvedSource = source.resolvingSymlinksInPath()
            guard !Self.contains(destination, in: resolvedSource), !Self.contains(resolvedSource, in: destination) else {
                throw NSError(domain: "HERMES.Migration", code: 2, userInfo: [NSLocalizedDescriptionKey: "新旧导出目录不能互相包含，请选择其他位置。"])
            }
            if let attributes = try? fm.attributesOfItem(atPath: source.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw NSError(domain: "HERMES.Migration", code: 3, userInfo: [NSLocalizedDescriptionKey: "当前导出位置是符号链接，请先使用真实目录后再移动。"])
            }
            let detachedFiles = try movableCompletedRecordFiles(from: source, to: destination)
            let sourceItems = try fm.fileExists(atPath: source.path) ? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted { $0.path < $1.path } : []
            let moves = (sourceItems + detachedFiles).map { (source: $0, destination: destination.appendingPathComponent($0.lastPathComponent)) }
            for item in moves where fm.fileExists(atPath: item.destination.path) {
                throw NSError(domain: "HERMES.Migration", code: 4, userInfo: [NSLocalizedDescriptionKey: "目标文件夹中已经存在“\(item.destination.lastPathComponent)”，未移动任何文件。"])
            }
            let allRecords = completed + downloadCompleted
            let currentOutputs = Set(allRecords.filter(\.outputIsCurrent))
            let currentSources = Set(allRecords.filter { record in
                guard let image = record.sourceImagePath, let movie = record.sourceVideoPath,
                      let revision = record.sourceRevision else { return false }
                return revision == MediaPairRevision(image: URL(fileURLWithPath: image), movie: URL(fileURLWithPath: movie))
            })
            if !fm.fileExists(atPath: destination.path) {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                createdDestination = true
            }
            try FileSystemUtilities.moveTransaction(moves, move: moveFile)
            let detachedPaths = Dictionary(detachedFiles.map { ($0.standardizedFileURL.path, destination.appendingPathComponent($0.lastPathComponent).path) }, uniquingKeysWith: { first, _ in first })
            func path(_ value: String) -> String {
                detachedPaths[URL(fileURLWithPath: value).standardizedFileURL.path] ?? Self.relocatedPath(value, from: source, to: destination)
            }
            func url(_ value: URL) -> URL { URL(fileURLWithPath: path(value.path)) }
            func pair(_ value: PairItem) -> PairItem {
                PairItem(imageURL: url(value.imageURL), videoURL: url(value.videoURL), status: value.status, message: value.message)
            }
            func record(_ value: CompletedItem) -> CompletedItem {
                var updated = value
                updated.imagePath = path(value.imagePath)
                updated.moviePath = value.moviePath.map(path)
                updated.sourceImagePath = value.sourceImagePath.map(path)
                updated.sourceVideoPath = value.sourceVideoPath.map(path)
                if currentOutputs.contains(value), let movie = updated.movieURL {
                    updated.revision = MediaPairRevision(image: updated.imageURL, movie: movie)
                    updated.importedToPhotos = value.importedToPhotos && updated.revision != nil
                } else {
                    updated.revision = nil
                    updated.importedToPhotos = false
                }
                if currentSources.contains(value), let image = updated.sourceImagePath, let movie = updated.sourceVideoPath {
                    updated.sourceRevision = MediaPairRevision(image: URL(fileURLWithPath: image), movie: URL(fileURLWithPath: movie))
                } else { updated.sourceRevision = nil }
                return updated
            }
            selectedCompletedIDs = Set(completed.filter { selectedCompletedIDs.contains($0.id) }.map { path($0.imagePath) })
            selectedPairIDs = Set(pairs.filter { selectedPairIDs.contains($0.id) }.map { pair($0).id })
            var downloadIDs: [String: String] = [:]
            for item in downloadPairs { downloadIDs["pair:\(item.id)"] = "pair:\(pair(item).id)" }
            for item in downloadPhotos { downloadIDs["photo:\(item.standardizedFileURL.path)"] = "photo:\(url(item).standardizedFileURL.path)" }
            for item in downloadVideos { downloadIDs["video:\(item.standardizedFileURL.path)"] = "video:\(url(item).standardizedFileURL.path)" }
            selectedDownloadItemIDs = Set(selectedDownloadItemIDs.compactMap { downloadIDs[$0] })
            files = files.map(url)
            pairs = pairs.map(pair)
            downloadPairs = downloadPairs.map(pair)
            downloadPhotos = downloadPhotos.map(url)
            downloadVideos = downloadVideos.map(url)
            completed = completed.map(record)
            downloadCompleted = downloadCompleted.map(record)
            downloadModifiedTimesByPath = Dictionary(downloadModifiedTimesByPath.map { (path($0.key), $0.value) }, uniquingKeysWith: { _, next in next })
            completedMutationVersion += 1
            outputFolder = destination
            Self.saveOutputFolderBookmark(for: destination)
            let relocatedDownloadFolder = url(downloadOutputFolder)
            if relocatedDownloadFolder.standardizedFileURL != downloadOutputFolder.standardizedFileURL {
                downloadOutputFolder = relocatedDownloadFolder
                Self.saveDownloadOutputFolderBookmark(for: relocatedDownloadFolder)
            }
            saveCompletedRecords()
            saveDownloadCompletedRecords()
            // Remove only an empty directory; a concurrent external write must never be deleted.
            if source.lastPathComponent == Self.outputFolderName { _ = rmdir(source.path) }
            rebuildVisibleDownloadItems()
            refreshCompleted()
            refreshDownloads()
            statusText = "导出文件夹已移动到“\(destination.path)”，相关文件位置已同步。"
            operationNotices.removeValue(forKey: page)
        } catch {
            if createdDestination { _ = rmdir(destination.path) }
            statusText = "移动导出文件夹失败：\(error.localizedDescription)"
            operationNotices[page] = statusText
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
        if !isDownloading { dismissOperationNotice(for: .downloads) }
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

        recordDownloadFailures(failures)
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
                self.cleanupEmptyDownloadFolders()
            } while self.needsAnotherDownloadRefresh
            self.isRefreshingDownloads = false
        }
    }

    private func applyDownloadedItems(_ scannedItems: DownloadScanResult) {
        let oldPairs = Dictionary(downloadPairs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        downloadPairs = scannedItems.pairs.map { pair in
            var updated = pair
            if let existing = oldPairs[pair.id] {
                updated.status = existing.status
                updated.message = existing.message
            }
            return updated
        }
        downloadPhotos = scannedItems.photos
        downloadVideos = scannedItems.videos
        downloadModifiedTimesByPath = scannedItems.modifiedTimesByPath
        // A scan describes what is currently available, not the lifetime of a record.
        // Retain legacy, temporarily missing and other-directory records; only validated
        // current source/output revisions contribute to the composed filter.
        rebuildVisibleDownloadItems()
        retainVisibleDownloadSelection()
        let composedCount = completedDownloadPairIDs().count
        let itemCount = downloadPairs.count + downloadPhotos.count + downloadVideos.count
        let summary = itemCount == 0 ? "输入分享链接开始下载。" : "已识别 \(itemCount) 个素材，已合成 \(composedCount) 组。"
        downloadStatusText = lastDownloadFailure.map { "下载存在失败：\($0)\n\(summary)" } ?? summary
    }

    private func cleanupEmptyDownloadFolders() {
        let folder = downloadOutputFolder
        let composedFolder = downloadComposedFolder

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            guard url.hasDirectoryPath else { continue }
            let standardized = url.standardizedFileURL
            let composedStandardized = composedFolder.standardizedFileURL
            if standardized == composedStandardized || standardized.path.hasPrefix(composedStandardized.path + "/") {
                enumerator.skipDescendants()
                continue
            }
            directories.append(url)
        }

        // 按路径深度倒序（最深优先），确保子目录先处理
        directories.sort { $0.path.components(separatedBy: "/").count > $1.path.components(separatedBy: "/").count }

        for dir in directories {
            if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
               contents.isEmpty {
                Self.moveToTrash(dir)
            }
        }
    }

    func processDownloadPairs() async {
        guard !fileOperationsBusy, !isDownloading else { return }
        rebuildVisibleDownloadItems() // Revalidate files at the action boundary.
        let visibleIDs = processableVisibleDownloadPairIDs
        let selectedIDs = Set(selectedDownloadItemIDs.compactMap(Self.downloadPairID))
        let targetIDs = selectedDownloadItemIDs.isEmpty ? visibleIDs : selectedIDs.intersection(visibleIDs)
        let targets = downloadPairs.filter { targetIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        isProcessingDownloads = true
        defer { isProcessingDownloads = false; resumeCompletedRefreshIfNeeded() }
        downloadStatusText = "正在合成..."
        await compose(targets, fromDownloads: true)
    }

    func importSelectedDownloadMediaToPhotos(addToAlbum: Bool) async {
        let mediaURLs = selectedDownloadMediaURLs
        guard !isImportingDownloadMedia, !mediaURLs.isEmpty else { return }
        guard mediaURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            downloadStatusText = "未找到源文件。"
            return
        }

        isImportingDownloadMedia = true
        defer { isImportingDownloadMedia = false; resumeCompletedRefreshIfNeeded() }

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
        guard !fileOperationsBusy, !isDownloading else { return }
        let selectedIDs = selectedDownloadItemIDs
        let targets = selectedIDs.isEmpty ? visibleDownloadItems : visibleDownloadItems.filter { selectedIDs.contains($0.id) }
        var removedIDs = Set<DownloadGridItem.ID>()
        var removedPairIDs = Set<PairItem.ID>()
        var errors: [String] = []
        for item in targets {
            let urls: [URL]
            switch item.kind {
            case .pair(let id):
                guard let pair = downloadPairs.first(where: { $0.id == id }) else { continue }
                urls = [pair.imageURL, pair.videoURL]
            case .photo, .video: urls = [item.imageURL]
            }
            if deleteFiles, let error = trashManagedFiles(urls) { errors.append(error); continue }
            removedIDs.insert(item.id)
            if case .pair(let id) = item.kind { removedPairIDs.insert(id) }
        }
        let removedPairs = downloadPairs.filter { removedPairIDs.contains($0.id) }
        let recordIDs = Set(downloadCompleted.filter { record in
            removedPairs.contains { pair in
                record.sourceImagePath == pair.imageURL.path && record.sourceVideoPath == pair.videoURL.path
            }
        }.map(\.id))
        ThumbnailCollectionAnimation.perform {
            downloadPairs.removeAll { removedPairIDs.contains($0.id) }
            downloadPhotos.removeAll { removedIDs.contains("photo:\($0.standardizedFileURL.path)") }
            downloadVideos.removeAll { removedIDs.contains("video:\($0.standardizedFileURL.path)") }
            downloadCompleted.removeAll { recordIDs.contains($0.id) }
        }
        for item in targets where removedIDs.contains(item.id) {
            downloadModifiedTimesByPath.removeValue(forKey: item.imageURL.standardizedFileURL.path)
        }
        rebuildVisibleDownloadItems()
        selectedDownloadItemIDs.subtract(removedIDs)
        saveDownloadCompletedRecords()
        downloadStatusText = Self.clearMessage(count: removedIDs.count, deleteFiles: deleteFiles, errors: errors)
        if !errors.isEmpty { operationNotices[.downloads] = downloadStatusText }
    }

    func importCompletedToPhotos(addToAlbum targetAddToAlbum: Bool? = nil) async {
        let selectedItems = selectedCompletedItems
        guard !fileOperationsBusy, !selectedItems.isEmpty else { return }
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
        defer { isImportingCompleted = false; resumeCompletedRefreshIfNeeded() }

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
            let importedByID = Dictionary(selectedItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in completed.indices {
                guard let original = importedByID[completed[index].id], original.outputIsCurrent,
                      original.revision == completed[index].revision else { continue }
                completed[index].importedToPhotos = true
            }
            saveCompletedRecords()
            retainVisibleCompletedSelection()
        case .failure(let message):
            statusText = "导入失败：\(message)"
        }
    }

    func processPairs() async {
        guard !fileOperationsBusy else { return }
        let targetIDs = selectedPairIDs.isEmpty ? Set(pairs.map(\.id)) : selectedPairIDs
        let targets = pairs.filter { targetIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        isProcessing = true
        defer { isProcessing = false; resumeCompletedRefreshIfNeeded() }
        statusText = "正在合成..."
        await compose(targets, fromDownloads: false)
    }

    private func compose(_ targets: [PairItem], fromDownloads: Bool) async {
        let folder = outputFolder
        let shouldImport = importToPhotos
        let album = addToAlbum ? Self.appDisplayName : nil
        let revisions = Dictionary(targets.compactMap { pair -> (String, MediaPairRevision)? in
            MediaPairRevision(image: pair.imageURL, movie: pair.videoURL).map { (pair.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let ids = Set(targets.map(\.id))
        if fromDownloads { setDownloadPairStatus(for: ids, status: .running); rebuildVisibleDownloadItems() }
        else { setPairStatus(for: ids, status: .running) }
        let results = await runCompositionTasks(for: targets, outputFolder: folder)
        var failures = 0
        for result in results {
            let pair = result.pair
            switch result.result {
            case .failure(let message):
                failures += 1
                updatePair(pair.id, fromDownloads: fromDownloads, status: .failed, message: message)
            case .success(let message):
                guard var item = Self.completedItem(from: message),
                      let originalRevision = revisions[pair.id],
                      originalRevision == MediaPairRevision(image: pair.imageURL, movie: pair.videoURL) else {
                    failures += 1
                    updatePair(pair.id, fromDownloads: fromDownloads, status: .failed, message: "源文件已变化或合成结果不完整，请检查文件后重试。")
                    continue
                }
                item.sourceImagePath = pair.imageURL.standardizedFileURL.path
                item.sourceVideoPath = pair.videoURL.standardizedFileURL.path
                item.sourceRevision = originalRevision
                // Record the valid local result even if Photos import fails.
                mergeCompletedItem(item)
                if fromDownloads { mergeDownloadCompletedItem(item) }
                if shouldImport {
                    switch await photoPairImporter(item, album) {
                    case .success:
                        guard item.outputIsCurrent else {
                            failures += 1
                            updatePair(pair.id, fromDownloads: fromDownloads, status: .failed, message: "导入期间导出文件已变化，请检查结果。")
                            continue
                        }
                        item.importedToPhotos = true
                        mergeCompletedItem(item)
                        if fromDownloads { mergeDownloadCompletedItem(item) }
                    case .failure(let error):
                        failures += 1
                        updatePair(pair.id, fromDownloads: fromDownloads, status: .failed, message: "合成已保存，导入失败：\(error)。可在已完成页重试导入。")
                        continue
                    }
                }
                // No array index survives an await. The ID remains valid after sorting/removal.
                updatePair(pair.id, fromDownloads: fromDownloads, status: .finished, message: "已完成。")
                if fromDownloads { selectedDownloadItemIDs.remove("pair:\(pair.id)") }
                else {
                    removeQueuedFiles(for: pair)
                    selectedPairIDs.remove(pair.id)
                    pairs.removeAll { $0.id == pair.id }
                }
            }
        }
        let summary = failures == 0 ? "合成已完成。" : "完成，\(failures) 组失败，请查看项目状态。"
        let failedItems = (fromDownloads ? downloadPairs : pairs).filter { ids.contains($0.id) && $0.status == .failed }
        let page: SidebarSection = fromDownloads ? .downloads : .queue
        if failures > 0 {
            let details = summary + "\n" + failedItems.map { $0.imageURL.lastPathComponent + "：" + $0.message }.joined(separator: "\n")
            operationNotices[page] = [operationNotices[page], details].compactMap { $0 }.joined(separator: "\n")
        } else if !fromDownloads || lastDownloadFailure == nil { operationNotices.removeValue(forKey: page) }
        if fromDownloads {
            rebuildVisibleDownloadItems(); retainVisibleDownloadSelection(); downloadStatusText = summary
        } else { retainSelectedPairIDs(); statusText = summary }
    }

    private func updatePair(_ id: PairItem.ID, fromDownloads: Bool, status: PairItem.Status, message: String) {
        if fromDownloads {
            guard let index = downloadPairs.firstIndex(where: { $0.id == id }) else { return }
            downloadPairs[index].status = status
            downloadPairs[index].message = message
        } else {
            guard let index = pairs.firstIndex(where: { $0.id == id }) else { return }
            pairs[index].status = status
            pairs[index].message = message
        }
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

        let runner = compositionRunner
        await withTaskGroup(of: LivePhotoCompositionResult.self) { group in
            var nextIndex = 0

            func enqueueNextTask() {
                guard nextIndex < targetPairs.count else { return }
                let pair = targetPairs[nextIndex]
                nextIndex += 1
                group.addTask(priority: .userInitiated) {
                    let result = await runner(pair, outputFolder)
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

        let resultByID = Dictionary(results.map { ($0.pairID, $0) }, uniquingKeysWith: { first, _ in first })
        return targetPairs.compactMap { resultByID[$0.id] }
    }

    private func mergeCompletedItem(_ item: CompletedItem) {
        completedMutationVersion += 1
        completed = Self.merging(item, into: completed)
        saveCompletedRecords()
        retainVisibleCompletedSelection()
    }

    private func mergeDownloadCompletedItem(_ item: CompletedItem) {
        downloadCompleted = Self.merging(item, into: downloadCompleted)
        saveDownloadCompletedRecords()
        rebuildVisibleDownloadItems()
        retainVisibleDownloadSelection()
    }

    private static func merging(_ item: CompletedItem, into records: [CompletedItem]) -> [CompletedItem] {
        var byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next = item
        if let previous = byID[item.id], let revision = item.revision, previous.revision == revision {
            next.importedToPhotos = previous.importedToPhotos || item.importedToPhotos
        }
        byID[item.id] = next
        return sortedCompletedItems(Array(byID.values))
    }

    private static func validateLegacyRecord(_ record: CompletedItem) -> CompletedItem {
        var item = record
        guard let movieURL = item.movieURL, let current = MediaPairRevision(image: item.imageURL, movie: movieURL) else {
            item.importedToPhotos = false
            return item
        }
        if let revision = item.revision {
            if revision != current { item.importedToPhotos = false }
        } else {
            // Legacy exports stamped both resources together. Never use a bare filename to migrate.
            let matchesRecordedExport = item.modifiedTime > 0
                && abs(current.image.modified - item.modifiedTime) < 0.001
                && abs(current.movie.modified - item.modifiedTime) < 0.001
            item.importedToPhotos = item.importedToPhotos && matchesRecordedExport
            item.revision = current
        }
        return item
    }

    private func resumeCompletedRefreshIfNeeded() {
        if needsAnotherCompletedRefresh { needsAnotherCompletedRefresh = false; refreshCompleted() }
    }

    func refreshCompleted() {
        guard !fileOperationsBusy else { needsAnotherCompletedRefresh = true; return }
        guard !isRefreshingCompleted else { needsAnotherCompletedRefresh = true; return }
        guard let folder = authorizedOutputFolderForUserAction() else { return }
        isRefreshingCompleted = true
        let mutationVersion = completedMutationVersion
        Task {
            let scannedItems = await Self.completedItems(in: folder)
            self.isRefreshingCompleted = false
            guard self.outputFolder == folder, self.completedMutationVersion == mutationVersion, !self.fileOperationsBusy else {
                self.needsAnotherCompletedRefresh = true
                if !self.fileOperationsBusy { self.resumeCompletedRefreshIfNeeded() }
                return
            }

            let existingByID = Dictionary(uniqueKeysWithValues: self.completed.map { ($0.id, $0) })
            let refreshedItems = Self.sortedCompletedItems(scannedItems.map { scannedItem in
                var mergedItem = scannedItem
                if let existingItem = existingByID[scannedItem.id], let revision = scannedItem.revision,
                   existingItem.revision == revision {
                    mergedItem.importedToPhotos = existingItem.importedToPhotos
                    mergedItem.sourceImagePath = existingItem.sourceImagePath
                    mergedItem.sourceVideoPath = existingItem.sourceVideoPath
                    mergedItem.sourceRevision = existingItem.sourceRevision
                }
                return mergedItem
            })

            if refreshedItems != self.completed {
                self.completed = refreshedItems
                self.saveCompletedRecords()
                self.retainVisibleCompletedSelection()
            }
            self.resumeCompletedRefreshIfNeeded()
        }
    }

    func retainVisibleCompletedSelection() {
        let visibleIDs = Set(visibleCompleted.map(\.id))
        let retained = selectedCompletedIDs.intersection(visibleIDs)
        if retained != selectedCompletedIDs { selectedCompletedIDs = retained }
    }

    func retainSelectedPairIDs() {
        let visibleIDs = Set(pairs.map(\.id))
        selectedPairIDs = selectedPairIDs.intersection(visibleIDs)
    }

    func retainVisibleDownloadSelection() {
        let visibleIDs = Set(visibleDownloadItems.map(\.id))
        let retained = selectedDownloadItemIDs.intersection(visibleIDs)
        if retained != selectedDownloadItemIDs { selectedDownloadItemIDs = retained }
    }

    func clearVisibleCompleted(deleteFiles: Bool) {
        guard !fileOperationsBusy else { return }
        completedMutationVersion += 1
        let selectedIDs = selectedCompletedIDs
        let targets = selectedIDs.isEmpty ? visibleCompleted : visibleCompleted.filter { selectedIDs.contains($0.id) }
        var removedIDs = Set<CompletedItem.ID>()
        var errors: [String] = []
        for item in targets {
            let urls = [item.imageURL] + (item.movieURL.map { [$0] } ?? [])
            if deleteFiles, let error = trashManagedFiles(urls) { errors.append(error); continue }
            removedIDs.insert(item.id)
        }
        ThumbnailCollectionAnimation.perform {
            completed.removeAll { removedIDs.contains($0.id) }
            if deleteFiles { downloadCompleted.removeAll { removedIDs.contains($0.id) } }
        }
        selectedCompletedIDs.subtract(removedIDs)
        saveCompletedRecords()
        if deleteFiles {
            saveDownloadCompletedRecords()
            rebuildVisibleDownloadItems()
            retainVisibleDownloadSelection()
        }
        statusText = Self.clearMessage(count: removedIDs.count, deleteFiles: deleteFiles, errors: errors)
        operationNotices[.completed] = errors.isEmpty ? nil : statusText
    }

    private nonisolated static func completedStem(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }

    private nonisolated static func completedItem(from message: String) -> CompletedItem? {
        guard let line = message.components(separatedBy: "\n").first(where: { $0.hasPrefix("HERMES_RESULT:") }),
              let data = String(line.dropFirst("HERMES_RESULT:".count)).data(using: .utf8),
              let result = try? JSONDecoder().decode([String: String].self, from: data),
              let imagePath = result["imagePath"], let moviePath = result["moviePath"] else { return nil }
        let image = URL(fileURLWithPath: imagePath), movie = URL(fileURLWithPath: moviePath)
        guard let revision = MediaPairRevision(image: image, movie: movie) else { return nil }
        return CompletedItem(imagePath: image.path, moviePath: movie.path, modifiedTime: revision.image.modified, revision: revision)
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
                            modifiedTime: image.date.timeIntervalSince1970,
                            revision: movieByStem[stem].flatMap { MediaPairRevision(image: image.url, movie: $0) }
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
        let defaults = UserDefaults.standard
        let backupKey = "DownloadCompletedRecords.BeforeRecovery.v1"
        if defaults.data(forKey: backupKey) == nil,
           let previous = defaults.data(forKey: Self.downloadCompletedRecordsDefaultsKey) {
            defaults.set(previous, forKey: backupKey)
        }
        defaults.set(data, forKey: Self.downloadCompletedRecordsDefaultsKey)
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
        let old = Dictionary(pairs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ url: URL) -> String {
            url.deletingLastPathComponent().standardizedFileURL.path + "/" + url.deletingPathExtension().lastPathComponent.lowercased()
        }
        let images = Dictionary(grouping: files.filter(FileSystemUtilities.isImage), by: key)
        let videos = Dictionary(grouping: files.filter(FileSystemUtilities.isVideo), by: key)
        pairs = images.keys.sorted().compactMap { name in
            guard let stills = images[name], stills.count == 1, let movies = videos[name], movies.count == 1 else { return nil }
            let pair = PairItem(imageURL: stills[0], videoURL: movies[0])
            return old[pair.id] ?? pair
        }
        retainSelectedPairIDs()
        let unmatched = files.count - pairs.count * 2
        if operationNotices[.queue] == statusText { operationNotices.removeValue(forKey: .queue) }
        statusText = "已准备 \(pairs.count) 组 Live Photo。" + (unmatched > 0 ? "\(unmatched) 个文件未配对，请将同组照片和视频放在同一文件夹并使用相同名称。" : "")
        if unmatched > 0 { operationNotices[.queue] = statusText }
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
            return "下载抖音媒体…"
        } else if isXHSShareText(entry) {
            return "下载小红书媒体…"
        } else if isDewuShareText(entry) {
            return "下载得物媒体…"
        }
        return "下载媒体文件…"
    }

    private nonisolated static func downloadProgressDetail(for entry: String, fraction: CGFloat) -> String {
        if fraction < 0.04 {
            return "解析链接…"
        }
        if fraction < 0.10 {
            return "获取媒体信息…"
        }
        if fraction < DownloadProgressMilestone.scanEnd {
            return "扫描本地缓存…"
        }
        if fraction < 0.50 {
            return "准备下载资源…"
        }
        if fraction < DownloadProgressMilestone.downloadEnd {
            return downloadProgressDownloadDetail(for: entry)
        }
        return "整理文件…"
    }

    private nonisolated static func downloadShareEntries(from text: String) -> [String] {
        let pattern = #"(?i)(?:https?://)?(?:www\.)?(?:xhslink\.(?:com|cn)|xiaohongshu\.com|dw4\.co|dewu\.com|v\.douyin\.com|douyin\.com|iesdouyin\.com)/[^\s"<>\\^`{|}，。；！？、【】《》]+"#
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
            || lowered.contains("xhslink.cn")
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
