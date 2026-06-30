import Foundation

enum DewuPlaybackLogVideoExtractor {
    static func videoURLs(in text: String) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        let decoded = decodeLogText(text)
        let pattern = #"https?://video-cdn-auth(?:-[a-z]+)?\.dewu\.com/[^\s"'<>]+?\.mp4\?auth_key=[^\s"'<>]+"#
        for match in allMatches(pattern, in: decoded) {
            let cleaned = String(match.trimmingCharacters(in: CharacterSet(charactersIn: ",);]}\"")))
            guard let url = URL(string: cleaned) else { continue }
            let key = url.path
            if seen.insert(key).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    static func shouldSearchPlaybackLogs(
        didFetchAPIDetail: Bool,
        hasAPIMediaPairs: Bool,
        hasVideoURLs: Bool,
        isVideoPost: Bool,
        hasImageSources: Bool,
        hasShareVideoURLs: Bool
    ) -> Bool {
        guard !hasVideoURLs else { return false }
        guard !hasAPIMediaPairs else { return false }
        guard didFetchAPIDetail || !hasShareVideoURLs else { return false }
        return isVideoPost || hasImageSources || didFetchAPIDetail
    }

    private static func decodeLogText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func allMatches(_ pattern: String, in text: String) -> [Substring] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return text[range]
        }
    }
}
