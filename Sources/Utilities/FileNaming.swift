import Foundation

enum FileNaming {
    // MARK: - Folder name helpers

    /// Builds a user-scoped output folder name from an author and user ID, reusing an
    /// existing folder with a matching user-ID suffix when one already exists.
    static func userOutputFolder(root: URL, author: String, userID: String, defaultName: String) throws -> URL {
        let folderName = sanitizeFileName([author, userID].filter { !$0.isEmpty }.joined(separator: "_"),
                                           fallback: defaultName)
        if !userID.isEmpty, userID != "unknown" {
            let suffix = "_\(userID)"
            let matches = ((try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? [])
                .filter { item in
                    item.hasDirectoryPath
                        && (item.lastPathComponent == folderName || item.lastPathComponent.hasSuffix(suffix))
                }
                .sorted { FileSystemUtilities.modificationDate($0) > FileSystemUtilities.modificationDate($1) }
            if let existing = matches.first {
                return existing
            }
        }
        return root.appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: - Name sanitization

    /// Sanitizes a string for use as a file or folder name.
    ///
    /// The implementation is CJK-aware (preserves Chinese characters, Japanese kana, etc.)
    /// and replaces invalid characters with underscores. If the result is empty the
    /// `fallback` value is returned instead.
    static func sanitizeFileName(_ value: String, fallback: String) -> String {
        let pattern = #"[^一-龥a-zA-Z0-9-_！？，。；：“”（）《》]"#
        let cleaned = value.replacingOccurrences(of: pattern, with: "_", options: .regularExpression)
            .replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String((cleaned.isEmpty ? fallback : cleaned).prefix(120))
    }

    // MARK: - Unique destination

    /// Returns a unique destination URL inside `folder` for a file with the given `name`,
    /// avoiding collisions stored in `usedNames`.
    static func uniqueDestination(in folder: URL, name: String, usedNames: inout Set<String>) -> URL {
        let source = URL(fileURLWithPath: name.isEmpty ? "media" : name)
        let stem = source.deletingPathExtension().lastPathComponent.isEmpty
            ? "media" : source.deletingPathExtension().lastPathComponent
        let suffix = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
        var candidate = source.lastPathComponent
        var index = 2
        while usedNames.contains(candidate) {
            candidate = "\(stem)_\(index)\(suffix)"
            index += 1
        }
        usedNames.insert(candidate)
        return folder.appendingPathComponent(candidate)
    }
}
