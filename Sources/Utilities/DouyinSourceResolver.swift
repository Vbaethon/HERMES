import Foundation

/// Probe the MP4 track header before replacing a known playable rendition.
/// Range requests read metadata only; no desktop cache or full-video buffering.
enum DouyinSourceResolver {
    struct Video: Sendable {
        let url: URL
        let width: Int
        let height: Int
    }

    static func sourceURL(videoID: String) -> URL? {
        guard videoID.range(of: #"^v[a-zA-Z0-9_-]{8,100}$"#, options: .regularExpression) != nil else { return nil }
        var url = URLComponents(string: "https://www.douyin.com/aweme/v1/play/")!
        url.queryItems = [
            .init(name: "video_id", value: videoID), .init(name: "ratio", value: "default"),
            .init(name: "improve_bitrate", value: "1"), .init(name: "watermark", value: "0"),
            .init(name: "line", value: "0")
        ]
        return url.url
    }

    static func resolve(videoID: String, userAgent: String) async throws -> Video? {
        guard let source = sourceURL(videoID: videoID) else { return nil }
        let session = DownloaderHTTPCompatibility.makeDownloadSession(timeoutRequest: 12, timeoutResource: 30)
        defer { session.invalidateAndCancel() }
        var current = source
        var offset = 0
        // Skip media payload by its declared atom size, including >4 GB files.
        for _ in 0..<12 {
            let (header, finalURL) = try await range(current, offset: offset, count: 16, session: session, userAgent: userAgent)
            current = finalURL
            guard let atom = atomHeader(header, at: 0), atom.size >= atom.headerSize,
                  atom.size <= Int.max - offset else { return nil }
            if atom.type == "moov" {
                guard atom.size <= 8 * 1024 * 1024 else { return nil }
                let (metadata, _) = try await range(current, offset: offset, count: atom.size, session: session, userAgent: userAgent)
                guard let size = dimensions(in: metadata) else { return nil }
                return Video(url: current, width: size.width, height: size.height)
            }
            offset += atom.size
        }
        return nil
    }

    private static func range(_ url: URL, offset: Int, count: Int, session: URLSession, userAgent: String) async throws -> (Data, URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("bytes=\(offset)-\(offset + count - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(offset)-") == true else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        data.reserveCapacity(count)
        for try await byte in bytes {
            data.append(byte)
            if data.count == count { break }
        }
        guard data.count == count else { throw URLError(.cannotDecodeContentData) }
        return (data, response.url ?? url)
    }

    private static func uint(_ data: Data, at offset: Int, bytes: Int) -> UInt64? {
        guard offset >= 0, bytes <= data.count, offset <= data.count - bytes else { return nil }
        return data[offset..<(offset + bytes)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func atomHeader(_ data: Data, at offset: Int) -> (size: Int, type: String, headerSize: Int)? {
        guard let shortSize = uint(data, at: offset, bytes: 4), offset <= data.count - 8 else { return nil }
        let headerSize = shortSize == 1 ? 16 : 8
        guard let size = shortSize == 1 ? uint(data, at: offset + 8, bytes: 8) : shortSize,
              size >= headerSize, size <= Int.max else { return nil }
        return (Int(size), String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self), headerSize)
    }

    static func dimensions(in data: Data) -> (width: Int, height: Int)? {
        func children(_ start: Int, _ end: Int) -> [(type: String, start: Int, end: Int)] {
            var offset = start
            var result: [(String, Int, Int)] = []
            while offset < end {
                guard let atom = atomHeader(data, at: offset), atom.size <= end - offset else { break }
                result.append((atom.type, offset + atom.headerSize, offset + atom.size))
                offset += atom.size
            }
            return result
        }
        guard let moov = children(0, data.count).first(where: { $0.type == "moov" }) else { return nil }
        for track in children(moov.start, moov.end) where track.type == "trak" {
            let nodes = children(track.start, track.end)
            guard let mdia = nodes.first(where: { $0.type == "mdia" }),
                  let handler = children(mdia.start, mdia.end).first(where: { $0.type == "hdlr" }),
                  handler.end - handler.start >= 12,
                  String(decoding: data[(handler.start + 8)..<(handler.start + 12)], as: UTF8.self) == "vide",
                  let tkhd = nodes.first(where: { $0.type == "tkhd" }),
                  tkhd.end - tkhd.start >= 84,
                  let width = uint(data, at: tkhd.end - 8, bytes: 4),
                  let height = uint(data, at: tkhd.end - 4, bytes: 4),
                  width >> 16 > 0, height >> 16 > 0 else { continue }
            return (Int(width >> 16), Int(height >> 16))
        }
        return nil
    }
}
