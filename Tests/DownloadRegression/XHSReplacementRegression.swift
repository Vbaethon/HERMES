import Foundation

enum XHSReplacementRegression {
    static func run() async throws {
        typealias X = XHSNativeDownloader
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("hermes-xhs-replacement-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let order = MediaDisplayOrder(postID: "xhs:replacement-note", downloadedAt: 200, index: 1)
        let oldOrder = MediaDisplayOrder(postID: order.postID, downloadedAt: 100, index: order.index)
        let mp4 = Data([0, 0, 0, 24]) + Data("ftypisom00000000-new-mp4".utf8)
        let mov = Data([0, 0, 0, 24]) + Data("ftypqt  00000000-new-mov".utf8)
        let heic = Data([0, 0, 0, 24]) + Data("ftypheic00000000-new-heic".utf8)
        let jpg = Data([0xff, 0xd8, 0xff]) + Data("old-jpeg-payload".utf8)
        let oldBytes = Data("previous verified download".utf8)

        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            let result = try condition()
            precondition(result, message)
        }
        func folder(_ name: String) throws -> URL {
            let result = root.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: result, withIntermediateDirectories: true)
            return result
        }
        func task(in folder: URL, image: Bool = false, tagged: Bool = true) -> X.DownloadTask {
            X.DownloadTask(urls: [], destination: folder.appendingPathComponent(image ? "resource.bin" : "resource.mp4"),
                requestUserAgent: X.mobileUserAgent, videoHDRHint: nil, isLivePhoto: !image, isImage: image,
                displayOrder: tagged ? order : nil)
        }
        func write(_ folder: URL, _ name: String, bytes: Data = oldBytes, tag: MediaDisplayOrder? = oldOrder) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            tag?.write(to: url)
            if let tag {
                try expect(MediaDisplayOrder.read(from: url) == tag, "Replacement fixtures must carry readable download metadata")
            }
            return url
        }
        func staged(_ folder: URL, bytes: Data) throws -> URL {
            try write(folder, "resource.part", bytes: bytes, tag: nil)
        }
        func intact(_ url: URL, bytes: Data = oldBytes) throws {
            try expect(try Data(contentsOf: url) == bytes, "Unrelated or retained resources must remain byte-identical")
        }
        func clean(_ folder: URL) throws {
            try expect(try manager.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix(".") },
                "Publication must not leave a hidden replacement transaction")
        }

        for (name, previousSuffix, payload, newSuffix, image) in [
            ("mp4-to-mov", "mp4", mov, "mov", false),
            ("mov-to-mp4", "mov", mp4, "mp4", false),
            ("jpeg-to-heic", "jpg", heic, "heic", true),
            ("heic-to-jpeg", "heic", jpg, "jpg", true)
        ] {
            let dir = try folder(name)
            let previous = try write(dir, "resource." + previousSuffix)
            let source = try staged(dir, bytes: payload)
            let result = try X.publishDownloadedFile(source, task: task(in: dir, image: image))
            try expect(result == dir.appendingPathComponent("resource." + newSuffix), "Publication must retain the actual container suffix")
            try intact(result, bytes: payload)
            try expect(!manager.fileExists(atPath: previous.path), "A successful redownload must remove the same resource's old container")
            try expect(!manager.fileExists(atPath: source.path), "Publication must consume the staged file")
            try expect(try manager.contentsOfDirectory(atPath: dir.path).count == 1, "A format change must leave exactly one media resource")
            try clean(dir)
        }

        let sameFormat = try folder("same-format")
        let existing = try write(sameFormat, "resource.mov", tag: nil)
        let replacement = try staged(sameFormat, bytes: mov)
        let replaced = try X.publishDownloadedFile(replacement, task: task(in: sameFormat))
        try expect(replaced == existing, "The existing exact output path must still be overwritten")
        try intact(existing, bytes: mov)
        try clean(sameFormat)

        let protected = try folder("protected-siblings")
        let sameResource = try write(protected, "resource.mp4")
        let otherPost = try write(protected, "resource.m4v", tag: .init(postID: "xhs:another-note", downloadedAt: 100, index: 1))
        let otherStem = try write(protected, "another.mp4")
        let still = try write(protected, "resource.jpg")
        let published = try X.publishDownloadedFile(staged(protected, bytes: mov), task: task(in: protected))
        try expect(!manager.fileExists(atPath: sameResource.path), "Only the matching historical video is replaced")
        try intact(published, bytes: mov)
        for url in [otherPost, otherStem, still] { try intact(url) }
        try clean(protected)

        for (name, tag) in [
            ("untagged-sibling", Optional<MediaDisplayOrder>.none),
            ("other-index", Optional(MediaDisplayOrder(postID: order.postID, downloadedAt: 100, index: 2)))
        ] {
            let dir = try folder(name)
            let sibling = try write(dir, "resource.mp4", tag: tag)
            _ = try X.publishDownloadedFile(staged(dir, bytes: mov), task: task(in: dir))
            try intact(sibling)
            try clean(dir)
        }

        let untaggedTask = try folder("untagged-task")
        let taggedSibling = try write(untaggedTask, "resource.mp4")
        _ = try X.publishDownloadedFile(staged(untaggedTask, bytes: mov), task: task(in: untaggedTask, tagged: false))
        try intact(taggedSibling)
        try clean(untaggedTask)

        let missingStage = try folder("missing-stage")
        let retainedMP4 = try write(missingStage, "resource.mp4")
        let retainedMOV = try write(missingStage, "resource.mov")
        do {
            _ = try X.publishDownloadedFile(missingStage.appendingPathComponent("missing.part"), task: task(in: missingStage))
            preconditionFailure("A missing staged resource must fail publication")
        } catch { }
        try intact(retainedMP4)
        try intact(retainedMOV)
        try clean(missingStage)

        // Immutable staging forces the final move to fail after the existing
        // outputs have entered the transaction, exercising actual restoration.
        let failedCommit = try folder("failed-commit")
        let rollbackMP4 = try write(failedCommit, "resource.mp4")
        let rollbackMOV = try write(failedCommit, "resource.mov")
        let blockedSource = try staged(failedCommit, bytes: mov)
        try manager.setAttributes([.immutable: true], ofItemAtPath: blockedSource.path)
        defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: blockedSource.path) }
        do {
            _ = try X.publishDownloadedFile(blockedSource, task: task(in: failedCommit))
            preconditionFailure("An immutable staged file must make the final commit fail")
        } catch { }
        try manager.setAttributes([.immutable: false], ofItemAtPath: blockedSource.path)
        try intact(rollbackMP4)
        try intact(rollbackMOV)
        try intact(blockedSource, bytes: mov)
        try expect(MediaDisplayOrder.read(from: rollbackMP4) == oldOrder
            && MediaDisplayOrder.read(from: rollbackMOV) == oldOrder,
            "A failed final move must restore historical metadata as well as bytes")
        try clean(failedCommit)

        let linkSibling = try folder("symlink-sibling")
        let donor = try write(linkSibling, "unrelated.mp4")
        let link = linkSibling.appendingPathComponent("resource.mp4")
        try manager.createSymbolicLink(at: link, withDestinationURL: donor)
        _ = try X.publishDownloadedFile(staged(linkSibling, bytes: mov), task: task(in: linkSibling))
        try expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
            "A same-name symlink must never be removed as a historical download")
        try intact(donor)
        try clean(linkSibling)

        for name in ["symlink-final", "directory-final"] {
            let dir = try folder(name)
            let sibling = try write(dir, "resource.mp4")
            let final = dir.appendingPathComponent("resource.mov")
            let target = try write(dir, "target.mp4")
            if name == "symlink-final" {
                try manager.createSymbolicLink(at: final, withDestinationURL: target)
            } else {
                try manager.createDirectory(at: final, withIntermediateDirectories: false)
                try oldBytes.write(to: final.appendingPathComponent("user-content"))
            }
            let source = try staged(dir, bytes: mov)
            do {
                _ = try X.publishDownloadedFile(source, task: task(in: dir))
                preconditionFailure("A symlink or directory at the exact output path must reject publication")
            } catch { }
            try intact(sibling)
            try intact(target)
            try intact(source, bytes: mov)
            if name == "symlink-final" {
                try expect(try final.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
                    "Rejected publication must preserve the existing symlink")
            } else {
                try intact(final.appendingPathComponent("user-content"))
            }
            try clean(dir)
        }

        let cancelled = try folder("cancelled")
        let cancelledPrevious = try write(cancelled, "resource.mp4")
        let cancelledSource = try staged(cancelled, bytes: mov)
        let cancelledPublish = Task { () throws -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            let cancelledTask = X.DownloadTask(urls: [], destination: cancelled.appendingPathComponent("resource.mp4"),
                requestUserAgent: X.mobileUserAgent, videoHDRHint: nil, isLivePhoto: true, displayOrder: order)
            return try X.publishDownloadedFile(cancelledSource, task: cancelledTask)
        }
        do {
            _ = try await cancelledPublish.value
            preconditionFailure("An already cancelled task must not publish a resource")
        } catch is CancellationError { }
        try intact(cancelledPrevious)
        try intact(cancelledSource, bytes: mov)
        try expect(!manager.fileExists(atPath: cancelled.appendingPathComponent("resource.mov").path),
            "Cancelled publication must not create the new container")
        try clean(cancelled)

        print("PASS: XHS redownload replaces matching historical containers, protects unrelated resources and rolls back failures or cancellation")
    }
}
