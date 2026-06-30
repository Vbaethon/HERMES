import Foundation

enum CookieManager {
    // MARK: - Storage Keys

    private static let xhsCookieKey = "XHSWebSessionCookie.v1"

    // MARK: - XHS Cookie Read/Write/Clear

    static var savedXHSCookie: String? {
        UserDefaults.standard.string(forKey: xhsCookieKey)
    }

    static func saveXHSCookie(_ cookie: String) {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearXHSCookie()
            return
        }
        UserDefaults.standard.set(trimmed, forKey: xhsCookieKey)
    }

    static func clearXHSCookie() {
        UserDefaults.standard.removeObject(forKey: xhsCookieKey)
    }

    // MARK: - Text Parsing

    /// 从分享文本中提取 Cookie 行。
    /// 支持格式: `cookie: value` 或 `Cookie：value`（中英文冒号，大小写不敏感）。
    /// - Returns: `(cookie: 提取的Cookie字符串?, cleanedText: 去除Cookie行后的剩余文本)`
    static func extractCookie(from text: String) -> (cookie: String?, cleanedText: String) {
        let pattern = #"(?i)^\s*cookie\s*[:：]\s*(.+)$"#
        let lines = text.components(separatedBy: .newlines)
        var cookieValue: String?
        var remainingLines: [String] = []

        for line in lines {
            if cookieValue == nil,
               let match = line.range(of: pattern, options: .regularExpression) {
                let rawValue = String(line[match]).replacingOccurrences(
                    of: pattern,
                    with: "$1",
                    options: [.regularExpression, .caseInsensitive]
                ).trimmingCharacters(in: .whitespaces)
                if !rawValue.isEmpty {
                    cookieValue = rawValue
                }
            } else {
                remainingLines.append(line)
            }
        }

        let cleanedText = remainingLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cookieValue, cleanedText)
    }

    // MARK: - Validation

    /// 验证 XHS Cookie 是否有效。
    /// 发送带 Cookie 的请求到小红书首页，检查是否能正常访问。
    /// - Returns: `true` 表示 Cookie 有效
    static func validateXHSCookie(_ cookie: String) async -> Bool {
        guard let url = URL(string: "https://www.xiaohongshu.com/") else {
            return false
        }
        let trimmedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCookie.isEmpty else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(trimmedCookie, forHTTPHeaderField: "Cookie")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<400).contains(httpResponse.statusCode) else {
                return false
            }
            let html = String(data: data, encoding: .utf8) ?? ""
            // 小红书有效页面包含特征标记
            return html.contains("xhscdn.com") || html.contains("xiaohongshu.com")
                || html.contains("__INITIAL_STATE__") || data.count > 8192
        } catch {
            return false
        }
    }
}
