import Foundation
import Darwin

@main
struct MediaAttributionRegression {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "HERMES.MediaAttributionRegression", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    static func main() async throws {
        let noteID = "0123456789abcdef01234567"
        let shortURL = URL(string: "https://xhslink.com/a/example?xsec_token=secret")!
        let note = try XHSNativeDownloader.parseNote([
            "noteId": noteID, "type": "normal", "title": "真实标题", "desc": "真实描述",
            "user": ["nickname": "真实博主", "user_id": "actual-user-id"], "imageList": []
        ], fallbackURL: shortURL)
        let xhs = XHSNativeDownloader.postAttribution(for: note, shareURL: shortURL)
        try require(xhs.postURL == "https://www.xiaohongshu.com/explore/\(noteID)", "XHS must use its validated canonical post ID")
        try require(xhs.title == "真实标题" && xhs.postDescription == "真实描述", "XHS title and description must both survive")
        try require(xhs.authorName == "真实博主" && xhs.authorID == "actual-user-id", "XHS exact author fields must be captured")
        try require(note.userID.isEmpty && note.author == "真实博主", "Attribution must not alter existing folder-name identity")
        var emptySnapshot = XHSNativeDownloader.NoteInfo()
        emptySnapshot.noteID = noteID
        emptySnapshot.type = "normal"
        let enriched = XHSNativeDownloader.preferredNote([emptySnapshot, note])!
        try require(enriched.attributionDescription == "真实描述" && enriched.attributionAuthorID == "actual-user-id",
                    "Matching XHS snapshots must fill missing attribution")
        var wrongNote = note
        wrongNote.noteID = "abcdef0123456789abcdef01"
        let isolated = XHSNativeDownloader.preferredNote([emptySnapshot, wrongNote])!
        try require(isolated.attributionAuthorName.isEmpty, "XHS must not merge another post's author")

        let awemeID = "12345678901234567"
        let otherAwemeID = "98765432109876543"
        let douyin = DouyinNativeDownloader.parseAweme([
            "aweme_id": awemeID, "title": "抖音标题", "desc": "抖音描述",
            "author": ["nickname": "抖音博主", "uid": "platform-user-id"],
            "images": [["url_list": ["https://p3-sign.douyinpic.com/image.jpeg"], "width": 64, "height": 64]]
        ])
        let seedHTML = "<script id=\"__NEXT_DATA__\" type=\"application/json\">" + (try json([
            "item_list": [
                ["aweme_id": otherAwemeID, "title": "别的帖子", "desc": "别的描述", "author": ["nickname": "别的博主", "uid": "wrong-user"]],
                ["aweme_id": awemeID, "desc": "匹配的补充描述", "author": ["nickname": "匹配的博主", "uid": "matched-user"]]
            ]
        ])) + "</script>"
        let seeds = DouyinNativeDownloader.recordedPostAttributions(fromHTML: seedHTML)
        try require(seeds[awemeID]?.authorName == "匹配的博主" && seeds[otherAwemeID]?.authorName == "别的博主",
                    "Douyin HTML attribution must be keyed by exact post identity")
        let dy = DouyinNativeDownloader.postAttribution(for: douyin,
            fallbackURL: URL(string: "https://v.douyin.com/share/?signature=secret")!, supplementation: seeds[otherAwemeID])
        try require(dy.postURL == "https://www.douyin.com/note/\(awemeID)", "Douyin images must use their canonical post route")
        try require(dy.title == "抖音标题" && dy.postDescription == "抖音描述" && dy.authorName == "抖音博主",
                    "Primary exact Douyin fields must win over unrelated seeds")
        var emptyDy = DouyinNativeDownloader.AwemeInfo()
        emptyDy.awemeID = awemeID
        let wrongDy = DouyinNativeDownloader.postAttribution(for: emptyDy, fallbackURL: shortURL, supplementation: seeds[otherAwemeID])
        try require(wrongDy.authorName == nil && wrongDy.postDescription == nil, "Wrong Douyin seed identity must not fill blanks")
        let matchingDy = DouyinNativeDownloader.postAttribution(for: emptyDy, fallbackURL: shortURL, supplementation: seeds[awemeID])
        try require(matchingDy.authorID == "matched-user" && matchingDy.postDescription == "匹配的补充描述",
                    "Matching Douyin seeds must fill actual missing fields")
        try require(matchingDy.postURL == "https://www.douyin.com/video/\(awemeID)", "Douyin video must use canonical route")

        let dewuJSON = try json(["props": ["pageProps": ["trendId": "98765", "metaOGInfo": ["data": [[
            "content": ["contentId": "98765", "title": "得物标题", "content": "得物正文"],
            "userInfo": ["userName": "得物博主", "userId": "42"]
        ]]]]]])
        let dewuHTML = "<link href='https://m.dewu.com/community/detail?trendId=98765&amp;signature=secret' rel=\"canonical\">"
            + "<meta property='og:title' content='网页备用标题'><meta content=\"备用描述\" property=\"og:description\">"
            + "<script id=\"__NEXT_DATA__\">" + dewuJSON + "</script>"
        let dewuShare = URL(string: "https://dw4.co/t/A/example?token=secret")!
        let dw = DewuNativeDownloader.postAttribution(fromHTML: dewuHTML, shareURL: dewuShare)!
        try require(dw.postID == "98765" && dw.postURL == "https://m.dewu.com/community/detail?trendId=98765",
                    "Dewu must retain supplied canonical URL with public ID and remove signatures")
        try require(dw.title == "得物标题" && dw.postDescription == "得物正文", "Dewu JSON text must be retained instead of generic page text")
        try require(dw.authorName == "得物博主" && dw.authorID == "42", "Dewu supplied author fields must be retained")
        let fallbackDW = DewuNativeDownloader.postAttribution(fromHTML:
            "trendId=98765 <meta property=\"og:title\" content=\"实际网页标题\"><meta content='实际描述 &amp; 正文' name='description'><link rel='canonical' href='https://example.com/wrong'>",
            shareURL: dewuShare)!
        try require(fallbackDW.title == "实际网页标题" && fallbackDW.postDescription == "实际描述 & 正文",
                    "Dewu supplied HTML metadata must fill omitted JSON text")
        try require(fallbackDW.postURL == "https://dw4.co/t/A/example" && fallbackDW.authorName == nil && fallbackDW.authorID == nil,
                    "Unknown Dewu authors stay unknown and foreign canonical URLs are rejected")
        let mismatchedDW = DewuNativeDownloader.postAttribution(fromHTML:
            "trendId=98765 <link rel='canonical' href='https://m.dewu.com/community/detail?trendId=99999'>",
            shareURL: dewuShare)!
        try require(mismatchedDW.postURL == "https://dw4.co/t/A/example", "A declared different Dewu post ID must not become the source link")
        let unrelated = MediaPostAttribution(platform: "dewu", postID: awemeID, authorName: "wrong-platform")
        try require(matchingDy.fillingMissingFields(from: unrelated) == matchingDy, "Attribution merges must preserve platform identity")

        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-attribution-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("fixture.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=")!
        try png.write(to: image)
        let legacy = try JSONSerialization.data(withJSONObject: ["platform": "xhs", "postID": noteID,
            "postURL": "https://www.xiaohongshu.com/explore/" + noteID, "title": "旧记录标题"])
        let status = legacy.withUnsafeBytes { setxattr(image.path, "com.codex.hermes.post-attribution.v1", $0.baseAddress, $0.count, 0, 0) }
        try require(status == 0, "Fixture xattr write must succeed")
        let old = MediaPostAttribution.read(from: image)
        try require(old?.title == "旧记录标题" && old?.postDescription == nil && old?.authorName == nil,
                    "Old xattrs must decode optional description and author fields without fabrication")
        let originalBytes = try Data(contentsOf: image)
        let rows = await MediaInspection.load(.init(name: "fixture", sourceURLs: [image],
            displayedURLs: [image, folder.appendingPathComponent("missing.mov")], kind: "Live Photo 配对", compositionState: "未合成"))
        try require(rows.contains { $0.section == .image && $0.key == "显示尺寸" && $0.value == "1 × 1 像素" }, "Readable image properties must stay in their image section")
        try require(rows.contains { $0.section == .video && $0.key == "文件状态" && $0.value == "文件不存在或不可读取" }, "Missing video resources must retain their own unavailable-file status")
        try require(!rows.contains { $0.key.contains(" · ") }, "Sectioned tables must not repeat media labels in keys")
        try require(rows.contains { $0.key == "原始文件" && $0.value == "未记录，无法确认" }, "Attribution alone must never assert originality")
        try require(try Data(contentsOf: image) == originalBytes, "Inspection must preserve media bytes")
        print("PASS: exact-post metadata capture, canonical public links, description, author identity, safe merges, legacy xattrs, and sectioned read-only inspection")
    }
}
