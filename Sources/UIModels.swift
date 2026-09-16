import Foundation

enum AppPreferenceKey {
    static let importToPhotos = "ImportToPhotosPreference.v1"
    static let addToAlbum = "AddToAlbumPreference.v1"
    static let completedAddToAlbum = "CompletedAddToAlbumPreference.v1"
}

enum AppSymbol {
    struct Stateful {
        let normal: String
        let fill: String
        let disabled: String

        init(_ normal: String, fill: String, disabled: String? = nil) {
            self.normal = normal
            self.fill = fill
            self.disabled = disabled ?? normal
        }

        func name(isActive: Bool, isPressed: Bool = false, isEnabled: Bool = true) -> String {
            if !isEnabled {
                return disabled
            }
            return (isActive || isPressed) ? fill : normal
        }
    }

    static let queue = Stateful("pointer.arrow.ipad.rays", fill: "pointer.arrow.ipad.rays")
    static let completed = Stateful("photo.stack", fill: "photo.stack.fill")
    static let download = Stateful("arrow.down.circle", fill: "arrow.down.circle.fill")
    static let importToPhotos = Stateful("photo.badge.plus", fill: "photo.badge.plus.fill")
    static let importCompleted = Stateful("arrow.down", fill: "arrow.down")
    static let addToAlbum = Stateful("rectangle.stack.badge.plus", fill: "rectangle.stack.fill.badge.plus")
    static let refresh = Stateful("arrow.trianglehead.clockwise.rotate.90", fill: "arrow.trianglehead.clockwise.rotate.90")
    static let openFolder = Stateful("folder", fill: "folder.fill")
    static let chooseFolder = Stateful("folder.badge.gearshape", fill: "folder.fill.badge.gearshape")
    static let clear = Stateful("trash", fill: "trash.fill")
    static let addFiles = Stateful("plus", fill: "plus")
    static let composeLivePhoto = Stateful("livephoto", fill: "livephoto")
    static let removeItems = "xmark.circle"
    static let deleteSourceFiles = "trash"
    static let dropZone = "tray.and.arrow.down"
}

enum ThumbnailContextMenuItem {
    static func composeTitle(count: Int) -> String { "合成 Live Photo" }
    static func openLocationTitle(count: Int) -> String { "在访达中显示 \(count) 个项目" }
    static func importTitle(count: Int) -> String { "将 \(count) 个项目导入“照片”" }
    static func importToAlbumTitle(count: Int) -> String { "将 \(count) 个项目导入 HERMES 相簿" }
    static func removeTitle(count: Int) -> String { "从列表移除 \(count) 个项目" }
    static func deleteSourceTitle(count: Int) -> String { "将 \(count) 个项目的文件移到废纸篓" }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case queue
    case downloads
    case completed

    static let allCases: [SidebarSection] = [.queue, .downloads, .completed]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: "开始"
        case .downloads: "下载器"
        case .completed: "已完成"
        }
    }

    var symbolName: String {
        switch self {
        case .queue:
            AppSymbol.queue.normal
        case .downloads:
            AppSymbol.download.normal
        case .completed:
            AppSymbol.completed.normal
        }
    }
}

struct PairItem: Identifiable, Hashable, Sendable {
    let imageURL: URL
    let videoURL: URL
    var status: Status = .waiting
    var message: String = ""
    var id: String { imageURL.standardizedFileURL.path + "\n" + videoURL.standardizedFileURL.path }

    enum Status: Hashable {
        case waiting
        case running
        case finished
        case failed
    }
}

struct CompletedItem: Identifiable, Hashable, Codable {
    var imagePath: String
    var moviePath: String?
    var importedToPhotos = false
    var modifiedTime: TimeInterval = 0
    var revision: MediaPairRevision?
    var sourceImagePath: String?
    var sourceVideoPath: String?
    var sourceRevision: MediaPairRevision?

    var outputIsCurrent: Bool {
        guard let movieURL, let revision else { return false }
        return revision == MediaPairRevision(image: imageURL, movie: movieURL)
    }

    func represents(_ pair: PairItem) -> Bool {
        guard sourceImagePath == pair.imageURL.standardizedFileURL.path,
              sourceVideoPath == pair.videoURL.standardizedFileURL.path,
              let sourceRevision, outputIsCurrent else { return false }
        return sourceRevision == MediaPairRevision(image: pair.imageURL, movie: pair.videoURL)
    }

    var id: String { imagePath }
    var imageURL: URL { URL(fileURLWithPath: imagePath) }
    var movieURL: URL? { moviePath.map(URL.init(fileURLWithPath:)) }
    var sourceExists: Bool {
        FileManager.default.fileExists(atPath: imagePath)
            && moviePath.map { FileManager.default.fileExists(atPath: $0) } == true
    }
}

enum ThumbnailMediaKind: Hashable {
    case photo
    case livePhoto
    case video

    var showsDuration: Bool {
        self == .video
    }

    func formatBadgeText(for url: URL) -> String? {
        guard self == .photo else { return nil }
        let fileExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileExtension.isEmpty else { return nil }
        return fileExtension.uppercased()
    }
}

enum CompletedFilter: String, CaseIterable, Identifiable {
    case notAdded
    case added
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notAdded: "未导入"
        case .added: "已导入"
        case .all: "全部项目"
        }
    }
}

enum DownloadFilter: String, CaseIterable, Identifiable {
    case notComposed
    case composed
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notComposed: "未合成"
        case .composed: "已合成"
        case .all: "全部项目"
        }
    }
}

struct DownloadGridItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case pair(PairItem.ID)
        case photo(String)
        case video(String)
    }

    let id: String
    let imageURL: URL
    let modifiedTime: TimeInterval
    let status: PairItem.Status
    let kind: Kind
    let isCompleted: Bool
    let mediaKind: ThumbnailMediaKind
}

struct DownloadScanResult: Hashable {
    var pairs: [PairItem]
    var photos: [URL]
    var videos: [URL]
    var modifiedTimesByPath: [String: TimeInterval] = [:]
}

enum ToolRunResult: Sendable {
    case success(String)
    case failure(String)
}

struct LivePhotoCompositionResult: Sendable {
    let pairID: PairItem.ID
    let pair: PairItem
    let result: ToolRunResult
}

enum PhotoImportResult {
    case success(Int)
    case failure(String)
}

enum PreparedPhotoImportPairsResult {
    case success(pairs: [(URL, URL)], folder: URL)
    case failure(String)
}


/// A path is not a content version. Include both resources and their filesystem revisions.
struct MediaFileRevision: Codable, Hashable, Sendable {
    let size: UInt64
    let modified: TimeInterval
    let created: TimeInterval
    let fileNumber: UInt64

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.size = size.uint64Value
        self.modified = modified.timeIntervalSince1970
        self.created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        self.fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

struct MediaPairRevision: Codable, Hashable, Sendable {
    let image: MediaFileRevision
    let movie: MediaFileRevision
    init?(image: URL, movie: URL) {
        guard let still = MediaFileRevision(image), let video = MediaFileRevision(movie) else { return nil }
        self.image = still
        self.movie = video
    }
}
