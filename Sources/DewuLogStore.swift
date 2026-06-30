import Foundation
import SQLite3

enum DewuLogStore {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let authorizedRootBookmarkKey = "DewuAuthorizedDataRootBookmark.v1"
    private static let authorizedRootPathKey = "DewuAuthorizedDataRootPath.v1"
    private static let dbSubpath = "Library/DUCaches/logger/sqlite3/never/com.shizhuang.Logger.v2"

    static func dataRoots() -> [URL] {
        var roots: [URL] = []
        if let authorizedRoot = resolveAuthorizedDataRoot(), viableDataRoot(at: authorizedRoot) != nil {
            roots.append(authorizedRoot)
        }
        roots.append(contentsOf: discoveredDataRoots().filter { !roots.contains($0) })
        return roots.sorted { FileSystemUtilities.modificationDate($0) > FileSystemUtilities.modificationDate($1) }
    }

    static func hasDataRootAccess() -> Bool {
        // Only count authorized roots (security-scoped access).
        // Discovered roots may exist on disk but cannot actually be read
        // without security-scoped bookmark authorization.
        guard let authorizedRoot = resolveAuthorizedDataRoot(),
              viableDataRoot(at: authorizedRoot) != nil else {
            return false
        }
        // Verify we can actually read a database from this root
        let databases = logDatabases(root: authorizedRoot)
        for db in databases {
            if let copy = readableCopy(of: db) {
                if copy != db { try? FileManager.default.removeItem(at: copy) }
                return true
            }
        }
        return !databases.isEmpty && FileManager.default.isReadableFile(atPath: databases[0].path)
    }

    static func authorizeDataRoot(_ selectedURL: URL) -> Bool {
        guard let dataRoot = normalizedDataRoot(from: selectedURL), viableDataRoot(at: dataRoot) != nil else {
            return false
        }

        saveAuthorizedDataRoot(dataRoot)
        return true
    }

    static func logDatabases(roots: [URL], limit: Int? = nil) -> [URL] {
        if let limit {
            var databases: [URL] = []
            for root in roots {
                databases.append(contentsOf: logDatabases(root: root, limit: limit))
                if databases.count >= limit {
                    return Array(databases.sorted { FileSystemUtilities.modificationDate($0) > FileSystemUtilities.modificationDate($1) }.prefix(limit))
                }
            }
            return databases.sorted { FileSystemUtilities.modificationDate($0) > FileSystemUtilities.modificationDate($1) }
        }
        return roots.flatMap { logDatabases(root: $0) }.sorted { FileSystemUtilities.modificationDate($0) > FileSystemUtilities.modificationDate($1) }
    }

    static func query(db: URL, sql: String, bindings: [String]) -> [[String]] {
        guard let workingURL = readableCopy(of: db) else {
            return []
        }
        defer {
            if workingURL != db {
                try? FileManager.default.removeItem(at: workingURL)
            }
        }

        var handle: OpaquePointer?
        let uri = "file:\(workingURL.path)?mode=ro"
        let openResult = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        if openResult != SQLITE_OK {
            if let handle { sqlite3_close(handle) }
            return []
        }
        guard let handle else {
            return []
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient)
        }

        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columnCount = sqlite3_column_count(statement)
            var row: [String] = []
            for column in 0..<columnCount {
                if let text = sqlite3_column_text(statement, column) {
                    row.append(String(cString: text))
                } else {
                    row.append("")
                }
            }
            rows.append(row)
        }
        return rows
    }

    private static func discoveredDataRoots() -> [URL] {
        let containers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers", isDirectory: true)
        var roots: [URL] = []

        for bundleID in [
            "com.siwuai.duapp",
            "com.siwuai.duapp.DUNotificationService"
        ] {
            let dataURL = containers
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("Data", isDirectory: true)
            if let root = viableDataRoot(at: dataURL), !roots.contains(root) {
                roots.append(root)
            }
        }

        if roots.isEmpty {
            let fileManager = FileManager.default
            if let names = try? fileManager.contentsOfDirectory(atPath: containers.path) {
                for name in names {
                    let dataURL = containers
                        .appendingPathComponent(name, isDirectory: true)
                        .appendingPathComponent("Data", isDirectory: true)
                    if let root = viableDataRoot(at: dataURL), !roots.contains(root) {
                        roots.append(root)
                    }
                }
            }
        }

        if roots.isEmpty {
            let dataFolders = (try? FileManager.default.contentsOfDirectory(
                at: containers,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            roots = dataFolders
                .map { $0.appendingPathComponent("Data", isDirectory: true) }
                .compactMap(viableDataRoot)
        }

        return roots
    }

    private static func logDatabases(root: URL, limit: Int? = nil) -> [URL] {
        let base = root.appendingPathComponent(dbSubpath, isDirectory: true)
        let fileManager = FileManager.default
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var databases: [URL] = []
        let today = Date()
        let calendar = Calendar.current
        for daysAgo in 0..<14 {
            guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let dateStr = dateFormatter.string(from: date)
            let dbURL = base.appendingPathComponent(dateStr, isDirectory: true).appendingPathComponent("DuLog.db")
            if fileManager.fileExists(atPath: dbURL.path) {
                databases.append(dbURL)
            }
        }

        if databases.isEmpty {
            let groupNames: [String]
            if let urls = try? fileManager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                groupNames = urls.map { $0.lastPathComponent }
            } else if let names = try? fileManager.contentsOfDirectory(atPath: base.path) {
                groupNames = names
            } else {
                groupNames = []
            }
            databases = groupNames
                .map { base.appendingPathComponent($0, isDirectory: true).appendingPathComponent("DuLog.db") }
                .filter { fileManager.fileExists(atPath: $0.path) }
        }

        let sorted = databases.sorted { FileSystemUtilities.modificationDate($0) > FileSystemUtilities.modificationDate($1) }
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }

    private static func readableCopy(of db: URL) -> URL? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-db-\(UUID().uuidString).db")
        if copyWithFileManager(db, to: tmp) || copyWithSecurityScope(db, to: tmp) {
            // Also copy WAL and SHM files so SQLite can read recent writes
            let walSource = URL(fileURLWithPath: db.path + "-wal")
            let shmSource = URL(fileURLWithPath: db.path + "-shm")
            let walDest = URL(fileURLWithPath: tmp.path + "-wal")
            let shmDest = URL(fileURLWithPath: tmp.path + "-shm")
            if FileManager.default.fileExists(atPath: walSource.path) {
                _ = copyWithFileManager(walSource, to: walDest)
                if !FileManager.default.fileExists(atPath: walDest.path) {
                    _ = copyWithSecurityScope(walSource, to: walDest)
                }
            }
            if FileManager.default.fileExists(atPath: shmSource.path) {
                _ = copyWithFileManager(shmSource, to: shmDest)
                if !FileManager.default.fileExists(atPath: shmDest.path) {
                    _ = copyWithSecurityScope(shmSource, to: shmDest)
                }
            }
            return tmp
        }
        return FileManager.default.isReadableFile(atPath: db.path) ? db : nil
    }

    private static func copyWithFileManager(_ source: URL, to destination: URL) -> Bool {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    private static func copyWithSecurityScope(_ source: URL, to destination: URL) -> Bool {
        guard let root = resolveAuthorizedDataRoot() else { return false }
        let didAccess = root.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                root.stopAccessingSecurityScopedResource()
            }
        }
        return copyWithFileManager(source, to: destination)
    }

    private static func viableDataRoot(at dataURL: URL) -> URL? {
        let standardizedURL = dataURL.standardizedFileURL
        let dbPath = standardizedURL.appendingPathComponent(dbSubpath, isDirectory: true).path
        return FileManager.default.fileExists(atPath: dbPath) ? standardizedURL : nil
    }

    private static func normalizedDataRoot(from url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        if viableDataRoot(at: standardizedURL) != nil {
            return standardizedURL
        }
        let dataURL = standardizedURL.appendingPathComponent("Data", isDirectory: true)
        if viableDataRoot(at: dataURL) != nil {
            return dataURL
        }
        return nil
    }

    private static func resolveAuthorizedDataRoot() -> URL? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: authorizedRootBookmarkKey) else {
            return defaults.string(forKey: authorizedRootPathKey).map(URL.init(fileURLWithPath:))
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
                saveAuthorizedDataRoot(url)
            }
            defaults.set(url.path, forKey: authorizedRootPathKey)
            return url
        } catch {
            defaults.removeObject(forKey: authorizedRootBookmarkKey)
            return defaults.string(forKey: authorizedRootPathKey).map(URL.init(fileURLWithPath:))
        }
    }

    private static func saveAuthorizedDataRoot(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: authorizedRootBookmarkKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: authorizedRootBookmarkKey)
        }
        UserDefaults.standard.set(url.path, forKey: authorizedRootPathKey)
    }

}
