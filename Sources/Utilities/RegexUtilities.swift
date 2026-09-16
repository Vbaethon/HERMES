import Foundation

/// Shared regular-expression helpers used by all platform downloaders.
enum RegexUtilities {
    /// Returns the range of the first match of `pattern` in `text`, or `nil`.
    static func firstMatch(
        _ pattern: String,
        in text: String,
        dotMatchesLineSeparators: Bool = false
    ) -> Range<String.Index>? {
        let options: NSRegularExpression.Options = dotMatchesLineSeparators ? [.dotMatchesLineSeparators] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return range
    }

    /// Returns the captured substring at `index` from the first match of `pattern`, or `nil`.
    static func firstCapture(
        _ index: Int,
        pattern: String,
        in text: String,
        dotMatchesLineSeparators: Bool = false
    ) -> String? {
        let options: NSRegularExpression.Options = dotMatchesLineSeparators ? [.dotMatchesLineSeparators] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// Returns all substrings that match `pattern` in `text`.
    static func allMatches(
        _ pattern: String,
        in text: String,
        dotMatchesLineSeparators: Bool = false
    ) -> [String] {
        let options: NSRegularExpression.Options = dotMatchesLineSeparators ? [.dotMatchesLineSeparators] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    /// Returns the range of a specific capture group from the first match.
    static func rangeOfCapture(
        _ index: Int,
        pattern: String,
        in text: String,
        dotMatchesLineSeparators: Bool = false
    ) -> Range<String.Index>? {
        let options: NSRegularExpression.Options = dotMatchesLineSeparators ? [.dotMatchesLineSeparators] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: text) else {
            return nil
        }
        return range
    }
}
