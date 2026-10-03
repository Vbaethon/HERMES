import Foundation

enum XHSCachedMotionReader {
    private struct Stamp: Equatable {
        let size: Int
        let modified: Date
        let inode: UInt64
    }

    private static func stamp(_ url: URL, maximum: Int) throws -> Stamp? {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= maximum,
              let modified = attributes[.modificationDate] as? Date,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        return Stamp(size: size, modified: modified, inode: inode)
    }

    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maximum + 1) ?? Data()
    }

    static func copyMotion(for sourceURL: URL, cacheRoots: [URL], to destination: URL) throws -> Bool {
        guard let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(),
              host.range(of: #"^(sns-video|sns-bak)(-[a-z0-9]+)*\.xhscdn\.com$"#, options: .regularExpression) != nil,
              components.percentEncodedPath == components.path,
              components.path.range(of: #"^/stream/[0-9]{1,4}/[0-9]{1,4}/[0-9]{1,4}/[A-Za-z0-9_-]{1,160}\.mp4$"#, options: .regularExpression) != nil else {
            return false
        }
        let identity = String(components.path.dropFirst().dropLast(4)).replacingOccurrences(of: "/", with: "_")
        let manager = FileManager.default
        var seenRoots = Set<String>()
        let pairs = cacheRoots.filter { seenRoots.insert($0.standardizedFileURL.path).inserted }.compactMap { root -> (URL, URL)? in
            let motion = root.appendingPathComponent(identity)
            let map = root.appendingPathComponent(identity + "-map")
            guard manager.fileExists(atPath: motion.path), manager.fileExists(atPath: map.path) else { return nil }
            return (motion, map)
        }
        guard pairs.count == 1, let (motion, map) = pairs.first,
              !manager.fileExists(atPath: destination.path),
              ![motion, map].contains(where: { $0.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() }),
              let beforeMotion = try stamp(motion, maximum: 64 * 1024 * 1024),
              let beforeMap = try stamp(map, maximum: 4096) else { return false }
        let mapData = try read(map, maximum: beforeMap.size)
        guard mapData.count == beforeMap.size, let text = String(data: mapData, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n")
        guard lines.count == 7, lines.last == "entry_info_flush" else { return false }
        var fields: [String: Int] = [:]
        for line in lines.dropLast() {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, fields[String(parts[0])] == nil, let value = Int(parts[1]) else { return false }
            fields[String(parts[0])] = value
        }
        guard let total = fields["total_file_size"], total > 0, total <= beforeMotion.size,
              fields["cache_file_size"] == total, fields["entry_data_amount"] == total,
              fields["cache_period_size"] == beforeMotion.size,
              fields["entry_logical_pos"] == 0, fields["entry_physical_pos"] == 0 else { return false }
        // Only the observed single contiguous entry is supported. Never assemble guessed fragments.
        let bytes = try read(motion, maximum: beforeMotion.size)
        guard bytes.count == beforeMotion.size, bytes.dropFirst(total).allSatisfy({ $0 == 0 }),
              try stamp(motion, maximum: 64 * 1024 * 1024) == beforeMotion,
              try stamp(map, maximum: 4096) == beforeMap,
              try read(map, maximum: beforeMap.size) == mapData else { return false }
        // Stage beside the donor so publication cannot expose a partial copy or replace another file.
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".xhs-donor-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staged) }
        try bytes.prefix(total).write(to: staged, options: .atomic)
        try manager.moveItem(at: staged, to: destination)
        return true
    }
}
