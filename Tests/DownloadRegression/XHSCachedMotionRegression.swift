import Foundation

enum XHSCachedMotionRegression {
    static func run() throws {
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            let result = try condition()
            precondition(result, message)
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("hermes-xhs-motion-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = URL(string: "https://sns-video-qc.xhscdn.com/stream/1/10/66/01eac060489493b501005001a0ff787193_66.mp4?sign=fixture")!
        let identity = "stream_1_10_66_01eac060489493b501005001a0ff787193_66"
        let payload = Data("exact cached motion payload".utf8)
        let padded = payload + Data(repeating: 0, count: 64 - payload.count)
        func makeCache(_ name: String) throws -> URL {
            let folder = root.appendingPathComponent(name).appendingPathComponent("com.xiaohongshu.livephoto_netcache")
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try padded.write(to: folder.appendingPathComponent(identity))
            let map = "total_file_size:\(payload.count)\ncache_file_size:\(payload.count)\ncache_period_size:64\nentry_logical_pos:0\nentry_data_amount:\(payload.count)\nentry_physical_pos:0\nentry_info_flush\n"
            try Data(map.utf8).write(to: folder.appendingPathComponent(identity + "-map"))
            return folder
        }
        func copy(_ roots: [URL], _ name: String, url: URL? = nil) throws -> Bool {
            try XHSCachedMotionReader.copyMotion(for: url ?? source, cacheRoots: roots, to: root.appendingPathComponent(name))
        }
        func reject(_ cache: URL, _ name: String) throws {
            try expect(try !copy([cache], name), "Incomplete or unknown cache must be rejected")
            try expect(!manager.fileExists(atPath: root.appendingPathComponent(name).path), "Rejected cache left a donor")
        }
        let complete = try makeCache("complete")
        try expect(try copy([complete], "complete-donor.mp4"), "Complete exact-URL cache was rejected")
        try expect(try Data(contentsOf: root.appendingPathComponent("complete-donor.mp4")) == payload,
            "Padding must be excluded without changing valid bytes")
        try expect(try !copy([complete], "complete-donor.mp4"), "Existing donor must never be replaced")
        try expect(try Data(contentsOf: complete.appendingPathComponent(identity)) == padded, "Cache source was modified")

        let partial = try makeCache("partial")
        let partialMap = partial.appendingPathComponent(identity + "-map")
        let partialText = try String(contentsOf: partialMap, encoding: .utf8)
            .replacingOccurrences(of: "cache_file_size:\(payload.count)", with: "cache_file_size:1")
        try Data(partialText.utf8).write(to: partialMap)
        try reject(partial, "partial-donor.mp4")

        let multipleEntries = try makeCache("multiple-entries")
        let multiMap = multipleEntries.appendingPathComponent(identity + "-map")
        var multiBytes = try Data(contentsOf: multiMap)
        multiBytes.append(Data("entry_logical_pos:1\nentry_data_amount:1\nentry_physical_pos:1\nentry_info_flush\n".utf8))
        try multiBytes.write(to: multiMap)
        try reject(multipleEntries, "multi-entry-donor.mp4")

        let changedSize = try makeCache("changed-size")
        try padded.dropLast().write(to: changedSize.appendingPathComponent(identity))
        try reject(changedSize, "changed-size-donor.mp4")

        let dirtyPadding = try makeCache("dirty-padding")
        var dirty = padded
        dirty[dirty.count - 1] = 1
        try dirty.write(to: dirtyPadding.appendingPathComponent(identity))
        try reject(dirtyPadding, "dirty-padding-donor.mp4")

        let duplicate = try makeCache("duplicate")
        try expect(try !copy([complete, duplicate], "ambiguous-donor.mp4"), "Multiple matching containers must be rejected")
        for unknown in ["https://example.com/stream/1/10/66/01eac060489493b501005001a0ff787193_66.mp4",
                        "https://sns-video-qc.xhscdn.com/stream/1/10/66/01eac060489493b501005001a0ff787193_66.mov",
                        "https://sns-video-qc.xhscdn.com/stream/1/10/66/%30%31eac060489493b501005001a0ff787193_66.mp4"] {
            try expect(try !copy([complete], "unknown-donor.mp4", url: URL(string: unknown)!), "Unknown URL must not alias a cache identity")
        }
        let symlink = try makeCache("symlink")
        let symlinkMotion = symlink.appendingPathComponent(identity)
        try manager.removeItem(at: symlinkMotion)
        try manager.createSymbolicLink(at: symlinkMotion, withDestinationURL: complete.appendingPathComponent(identity))
        try reject(symlink, "symlink-donor.mp4")
        try expect(try manager.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".xhs-donor-") },
            "Failed reads must clean temporary donors")
        print("PASS: exact complete XHS motion cache, padding trim, partial/multi-entry/size/padding/ambiguous/URL/symlink rejection")
    }
}
