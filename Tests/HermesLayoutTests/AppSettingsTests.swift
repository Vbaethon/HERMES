import Foundation
import XCTest
@testable import HermesThumbnailUI

final class AppSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "HermesAppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testExistingPreferencesKeepTheirKeysAndRecordsWhenOpened() {
        let defaults = defaults()
        defaults.set(false, forKey: "ImportToPhotosPreference.v1")
        defaults.set(true, forKey: "AddToAlbumPreference.v1")
        defaults.set(true, forKey: "CompletedAddToAlbumPreference.v1")
        defaults.set(true, forKey: "HERMESInspectorVisible.v1")
        defaults.set("completed", forKey: "SettingsSelectedPane.v1")
        defaults.set("/existing/output", forKey: "OutputFolderPath")
        defaults.set("/existing/download", forKey: "DownloadOutputFolderPath.v1")
        let records = Data("existing-records".utf8)
        defaults.set(records, forKey: "CompletedRecords.v1")
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.importToPhotos)
        XCTAssertFalse(settings.addToAlbum)
        XCTAssertTrue(settings.completedAddToAlbum)
        XCTAssertTrue(settings.inspectorVisible)
        XCTAssertEqual(settings.selectedSettingsPane, .completed)
        XCTAssertEqual(settings.folderPath(for: .output), "/existing/output")
        XCTAssertEqual(settings.folderPath(for: .download), "/existing/download")
        XCTAssertEqual(defaults.data(forKey: "CompletedRecords.v1"), records)
        XCTAssertTrue(defaults.bool(forKey: "AddToAlbumPreference.v1"), "Reading does not rewrite stored preferences")
    }

    func testAllPreferencesRoundTripThroughANewStore() {
        let defaults = defaults()
        let settings = AppSettings(defaults: defaults)
        settings.importToPhotos = true
        settings.addToAlbum = true
        settings.completedAddToAlbum = true
        settings.inspectorVisible = true
        settings.selectedSettingsPane = .completed
        settings.selectedPage = .downloads
        settings.completedFilter = .added
        settings.downloadFilter = .notComposed
        settings.setFolderPath("/saved/output", for: .output)
        settings.setFolderPath("/saved/download", for: .download)
        settings.dewuDataRootPath = "/saved/authorized-root"
        settings.dewuDataRootBookmark = Data([1, 2, 3])
        for (page, columns) in zip(SidebarSection.allCases, [9, 7, 3]) {
            settings.setThumbnailColumns(columns, for: page)
        }
        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.importToPhotos && restored.addToAlbum && restored.completedAddToAlbum)
        XCTAssertTrue(restored.inspectorVisible)
        XCTAssertEqual(restored.selectedSettingsPane, .completed)
        XCTAssertEqual(restored.selectedPage, .downloads)
        XCTAssertEqual(restored.completedFilter, .added)
        XCTAssertEqual(restored.downloadFilter, .notComposed)
        XCTAssertEqual(restored.folderPath(for: .output), "/saved/output")
        XCTAssertEqual(restored.folderPath(for: .download), "/saved/download")
        XCTAssertEqual(restored.dewuDataRootPath, "/saved/authorized-root")
        XCTAssertEqual(restored.dewuDataRootBookmark, Data([1, 2, 3]))
        for (page, columns) in zip(SidebarSection.allCases, [9, 7, 3]) {
            XCTAssertEqual(restored.thumbnailColumns(for: page), columns)
        }
        restored.importToPhotos = false
        XCTAssertFalse(restored.addToAlbum)
        XCTAssertFalse(defaults.bool(forKey: AppPreferenceKey.addToAlbum))
        XCTAssertTrue(restored.completedAddToAlbum, "Manual import remains independent")
    }

    func testMissingAndInvalidValuesUseTheExistingDefaultsAndStoresStayIsolated() {
        let defaults = defaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.importToPhotos)
        XCTAssertFalse(settings.addToAlbum || settings.completedAddToAlbum || settings.inspectorVisible)
        defaults.set("removed", forKey: AppPreferenceKey.selectedPage)
        defaults.set("removed", forKey: AppPreferenceKey.selectedSettingsPane)
        defaults.set("removed", forKey: AppPreferenceKey.completedFilter)
        defaults.set("removed", forKey: AppPreferenceKey.downloadFilter)
        defaults.set(100, forKey: AppPreferenceKey.thumbnailColumns(for: .downloads))
        XCTAssertEqual(settings.selectedPage, .queue)
        XCTAssertEqual(settings.selectedSettingsPane, .synthesis)
        XCTAssertEqual(settings.completedFilter, .all)
        XCTAssertEqual(settings.downloadFilter, .all)
        XCTAssertEqual(settings.thumbnailColumns(for: .downloads), 5)
        settings.setThumbnailColumns(-1, for: .downloads)
        XCTAssertEqual(settings.thumbnailColumns(for: .downloads), 5)
        settings.setThumbnailColumns(3, for: .downloads)
        let separate = AppSettings(defaults: self.defaults())
        XCTAssertEqual(separate.thumbnailColumns(for: .downloads), 5)
        XCTAssertEqual(settings.thumbnailColumns(for: .queue), 5)
    }

    func testFolderBookmarksResolveAndCorruptBookmarksKeepTheirPathFallback() throws {
        let defaults = defaults()
        let settings = AppSettings(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in [AppSettings.Folder.output, .download] {
            settings.saveFolderBookmark(for: root, folder: folder)
            XCTAssertEqual(settings.resolveFolderBookmark(for: folder), root.standardizedFileURL)
            XCTAssertEqual(settings.folderPath(for: folder), root.path)
        }
        defaults.set(Data([0, 1]), forKey: "OutputFolderBookmark.v1")
        XCTAssertNil(settings.resolveFolderBookmark(for: .output))
        XCTAssertNil(defaults.data(forKey: "OutputFolderBookmark.v1"))
        XCTAssertEqual(settings.folderPath(for: .output), root.path)
        XCTAssertEqual(settings.resolveFolderBookmark(for: .download), root.standardizedFileURL)
    }
}
