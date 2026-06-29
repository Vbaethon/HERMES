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
}
