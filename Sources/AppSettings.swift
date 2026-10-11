import Foundation

enum AppPreferenceKey {
    // Keep the existing keys so upgrades preserve the user's preferences.
    static let importToPhotos = "ImportToPhotosPreference.v1"
    static let addToAlbum = "AddToAlbumPreference.v1"
    static let completedAddToAlbum = "CompletedAddToAlbumPreference.v1"
    static let inspectorVisible = "HERMESInspectorVisible.v1"
    static let selectedSettingsPane = "SettingsSelectedPane.v1"
    static let selectedPage = "SelectedPage.v1"
    static let completedFilter = "CompletedFilter.v1"
    static let downloadFilter = "DownloadFilter.v1"

    static func thumbnailColumns(for page: SidebarSection) -> String {
        "ThumbnailColumns.\(page.rawValue).v1"
    }
}

/// All app-owned preferences use this store. UserDefaults is thread-safe;
/// this wrapper has no mutable cached state. AppKit still owns window and
/// split-view autosave, and media records retain their separate lifecycle.
final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()
    private let defaults: UserDefaults

    enum Pane: String, CaseIterable { case synthesis, completed }
    enum Folder {
        case output, download

        fileprivate var pathKey: String {
            self == .output ? "OutputFolderPath" : "DownloadOutputFolderPath.v1"
        }
        fileprivate var bookmarkKey: String {
            self == .output ? "OutputFolderBookmark.v1" : "DownloadOutputFolderBookmark.v1"
        }
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var importToPhotos: Bool {
        get { defaults.object(forKey: AppPreferenceKey.importToPhotos) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: AppPreferenceKey.importToPhotos)
            if !newValue { addToAlbum = false }
        }
    }
    var addToAlbum: Bool {
        get { importToPhotos && (defaults.object(forKey: AppPreferenceKey.addToAlbum) as? Bool ?? false) }
        set { defaults.set(newValue && importToPhotos, forKey: AppPreferenceKey.addToAlbum) }
    }
    var completedAddToAlbum: Bool {
        get { defaults.object(forKey: AppPreferenceKey.completedAddToAlbum) as? Bool ?? false }
        set { defaults.set(newValue, forKey: AppPreferenceKey.completedAddToAlbum) }
    }
    var inspectorVisible: Bool {
        get { defaults.bool(forKey: AppPreferenceKey.inspectorVisible) }
        set { defaults.set(newValue, forKey: AppPreferenceKey.inspectorVisible) }
    }
    var selectedSettingsPane: Pane {
        get { value(forKey: AppPreferenceKey.selectedSettingsPane, fallback: .synthesis) }
        set { defaults.set(newValue.rawValue, forKey: AppPreferenceKey.selectedSettingsPane) }
    }
    var selectedPage: SidebarSection {
        get { value(forKey: AppPreferenceKey.selectedPage, fallback: .queue) }
        set { defaults.set(newValue.rawValue, forKey: AppPreferenceKey.selectedPage) }
    }
    var completedFilter: CompletedFilter {
        get { value(forKey: AppPreferenceKey.completedFilter, fallback: .all) }
        set { defaults.set(newValue.rawValue, forKey: AppPreferenceKey.completedFilter) }
    }
    var downloadFilter: DownloadFilter {
        get { value(forKey: AppPreferenceKey.downloadFilter, fallback: .all) }
        set { defaults.set(newValue.rawValue, forKey: AppPreferenceKey.downloadFilter) }
    }

    func thumbnailColumns(for page: SidebarSection) -> Int {
        let columns = defaults.object(forKey: AppPreferenceKey.thumbnailColumns(for: page)) as? Int
        return columns.flatMap { [9, 7, 5, 3].contains($0) ? $0 : nil } ?? 5
    }

    func setThumbnailColumns(_ columns: Int, for page: SidebarSection) {
        guard [9, 7, 5, 3].contains(columns), columns != thumbnailColumns(for: page) else { return }
        defaults.set(columns, forKey: AppPreferenceKey.thumbnailColumns(for: page))
    }

    func folderPath(for folder: Folder) -> String? { defaults.string(forKey: folder.pathKey) }
    func setFolderPath(_ path: String, for folder: Folder) { defaults.set(path, forKey: folder.pathKey) }

    func resolveFolderBookmark(for folder: Folder) -> URL? {
        guard let data = defaults.data(forKey: folder.bookmarkKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &isStale).standardizedFileURL
            if isStale { saveFolderBookmark(for: url, folder: folder) }
            setFolderPath(url.path, for: folder)
            return url
        } catch {
            defaults.removeObject(forKey: folder.bookmarkKey)
            return nil
        }
    }

    func saveFolderBookmark(for url: URL, folder: Folder) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                          includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: folder.bookmarkKey)
        }
        setFolderPath(url.path, for: folder)
    }

    // The downloader continues to own permission checks and bookmark resolution.
    var dewuDataRootPath: String? {
        get { defaults.string(forKey: "DewuAuthorizedDataRootPath.v1") }
        set { defaults.set(newValue, forKey: "DewuAuthorizedDataRootPath.v1") }
    }
    var dewuDataRootBookmark: Data? {
        get { defaults.data(forKey: "DewuAuthorizedDataRootBookmark.v1") }
        set { defaults.set(newValue, forKey: "DewuAuthorizedDataRootBookmark.v1") }
    }

    private func value<T: RawRepresentable>(forKey key: String, fallback: T) -> T where T.RawValue == String {
        defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }
}
