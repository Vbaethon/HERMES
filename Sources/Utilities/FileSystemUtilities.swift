import Foundation
import Darwin

/// Presentation metadata only. It never participates in media pairing or validation.
struct MediaDisplayOrder: Codable, Hashable, Sendable {
    let postID: String
    let downloadedAt: TimeInterval
    let index: Int
    private static let attribute = "com.codex.hermes.media-order.v1"

    func write(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        // Unsupported filesystems may omit this optional presentation metadata.
        _ = data.withUnsafeBytes { bytes in
            setxattr(url.path, Self.attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
    }

    static func read(from url: URL) -> Self? {
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0, size <= 4096 else { return nil }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, 0) }
        guard count == size, let order = try? JSONDecoder().decode(Self.self, from: data),
              !order.postID.isEmpty, order.index > 0, order.downloadedAt.isFinite else { return nil }
        return order
    }

    static func legacy(for url: URL, downloadedAt: TimeInterval) -> Self {
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = stem.range(of: #"_[0-9]{2,}$"#, options: .regularExpression)
        let postStem = suffix.map { String(stem[..<$0.lowerBound]) } ?? stem
        let index = suffix.flatMap { Int(stem[$0].dropFirst()) } ?? 1
        return Self(postID: url.deletingLastPathComponent().standardizedFileURL.path + "/" + postStem,
                    downloadedAt: downloadedAt, index: index)
    }

    static func sorted<T>(_ items: [T], order: (T) -> Self, name: (T) -> String) -> [T] {
        let entries = items.map { (item: $0, order: order($0), name: name($0)) }
        let dates = Dictionary(grouping: entries, by: { $0.order.postID })
            .mapValues { $0.map { $0.order.downloadedAt }.max()! }
        return entries.sorted { lhs, rhs in
            if lhs.order.postID != rhs.order.postID {
                let leftDate = dates[lhs.order.postID]!, rightDate = dates[rhs.order.postID]!
                if leftDate != rightDate { return leftDate > rightDate }
                return lhs.order.postID < rhs.order.postID
            }
            if lhs.order.index != rhs.order.index { return lhs.order.index < rhs.order.index }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.map(\.item)
    }
}

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
