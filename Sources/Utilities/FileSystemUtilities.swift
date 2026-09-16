import Foundation

enum FileSystemUtilities {
    /// Returns the content modification date of a URL, or `.distantPast` on failure.
    static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date.distantPast
    }

    /// Returns `true` if the URL points to a recognized still-image file extension.
    static func isImage(_ url: URL) -> Bool {
        ["jpg", "jpeg", "jfif", "heic", "heif", "webp", "png"].contains(url.pathExtension.lowercased())
    }

    /// Returns `true` if the URL points to a recognized video file extension.
    static func isVideo(_ url: URL) -> Bool {
        ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
    }

    static func trashGroup(
        _ urls: [URL],
        trash: (URL) throws -> URL = { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            guard let result else { throw CocoaError(.fileWriteUnknown) }
            return result as URL
        },
        restore: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) -> String? {
        var moved: [(source: URL, trash: URL)] = []
        var seen = Set<URL>()
        for url in urls.map(\.standardizedFileURL) where seen.insert(url).inserted {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                moved.append((url, try trash(url)))
            } catch {
                var messages = ["\(url.path)：\(error.localizedDescription)"]
                for item in moved.reversed() {
                    do { try restore(item.trash, item.source) }
                    catch { messages.append("未能恢复 \(item.source.path)，文件位于 \(item.trash.path)：\(error.localizedDescription)") }
                }
                return messages.joined(separator: "\n")
            }
        }
        return nil
    }

    /// Roll back only moves completed by this transaction; never overwrite destination content.
    static func moveTransaction(
        _ moves: [(source: URL, destination: URL)],
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws {
        var completed: [(source: URL, destination: URL)] = []
        do {
            for item in moves {
                try move(item.source, item.destination)
                completed.append(item)
            }
        } catch {
            var errors = [error.localizedDescription]
            for item in completed.reversed() {
                do { try move(item.destination, item.source) }
                catch { errors.append("回滚失败，文件仍在 \(item.destination.path)，原位置为 \(item.source.path)：\(error.localizedDescription)") }
            }
            throw NSError(domain: "HERMES.Migration", code: 1, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "\n")])
        }
    }

}
