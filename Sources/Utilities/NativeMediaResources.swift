import Foundation

/// File-based actions use complete resources, never the thumbnail bitmap.
enum NativeMediaResources {
    static func readableURLs(for item: ThumbnailGridItem) -> [URL] {
        guard item.unavailableMessage == nil else { return [] }
        let urls = item.resourceURLs.isEmpty ? [item.url] : item.resourceURLs
        guard item.mediaKind != .livePhoto || urls.count == 2,
              urls.allSatisfy({ url in
                  guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
                        let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
                  return values.isRegularFile == true
              }) else { return [] }
        return urls.map(\.standardizedFileURL)
    }

    static func readableURLs(for items: [ThumbnailGridItem]) -> [URL] {
        var seen = Set<URL>()
        var resources: [URL] = []
        for item in items {
            let urls = readableURLs(for: item)
            guard !urls.isEmpty else { return [] }
            resources += urls.filter { seen.insert($0).inserted }
        }
        return resources
    }
}
