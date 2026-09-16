import AppKit
import Foundation

@main enum ModelSafetyRegression {
    @MainActor static func main() async throws {
        precondition(Bundle.main.bundleIdentifier != "com.codex.Hermes")
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        var checks = 0
        func pass(_ name: String) { checks += 1; print("PASS: \(name)") }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        func pair(_ folder: URL, _ stem: String) throws -> PairItem {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = folder.appendingPathComponent(stem + ".jpg")
            let movie = folder.appendingPathComponent(stem + ".mov")
            try Data("still-\(UUID())".utf8).write(to: image)
            try Data("movie-\(UUID())".utf8).write(to: movie)
            return PairItem(imageURL: image, videoURL: movie)
        }
        func record(_ pair: PairItem, source: PairItem? = nil) -> CompletedItem {
            let version = MediaPairRevision(image: pair.imageURL, movie: pair.videoURL)!
            return CompletedItem(imagePath: pair.imageURL.path, moviePath: pair.videoURL.path,
                modifiedTime: version.image.modified, revision: version,
                sourceImagePath: source?.imageURL.path, sourceVideoPath: source?.videoURL.path,
                sourceRevision: source.flatMap { MediaPairRevision(image: $0.imageURL, movie: $0.videoURL) })
        }
        func model(_ name: String) throws -> ImporterModel {
            // This executable has its own defaults domain. All folders are explicit test fixtures.
            for key in ["CompletedRecords.v1", "DownloadCompletedRecords.v1", "OutputFolderBookmark.v1", "DownloadOutputFolderBookmark.v1"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            let m = ImporterModel(refreshOnInit: false)
            m.outputFolder = root.appendingPathComponent(name + "/output", isDirectory: true)
            m.downloadOutputFolder = root.appendingPathComponent(name + "/download", isDirectory: true)
            try fm.createDirectory(at: m.outputFolder, withIntermediateDirectories: true)
            try fm.createDirectory(at: m.downloadOutputFolder, withIntermediateDirectories: true)
            m.importToPhotos = false
            return m
        }
        func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            expect(predicate(), "asynchronous test timed out")
        }
        let a = try pair(root.appendingPathComponent("A"), "same")
        let b = try pair(root.appendingPathComponent("B"), "same")
        let pairing = try model("pairing")
        await pairing.addFiles([a.imageURL, b.videoURL])
        expect(pairing.pairs.isEmpty, "must not pair across folders")
        expect(pairing.operationNotices[.queue] != nil, "unmatched files must be explained")
        pass("cross-folder names remain unpaired")
        await pairing.addFiles([a.videoURL, b.imageURL, b.imageURL])
        expect(pairing.pairs.count == 2 && pairing.files.count == 4, "one pair per folder, unique files")
        expect(pairing.pairs.allSatisfy { $0.imageURL.deletingLastPathComponent() == $0.videoURL.deletingLastPathComponent() }, "mixed folders")
        pass("same-folder pairing and within-batch deduplication")
        let unmatched = try model("unmatched")
        await unmatched.addFiles([a.imageURL, a.videoURL.deletingLastPathComponent().appendingPathComponent("unrelated.mov")])
        expect(unmatched.pairs.isEmpty, "must not zip unrelated filenames")
        pass("no arbitrary positional pairing")

        let scanning = try model("scanning")
        var scanCompletion: CheckedContinuation<[URL], Never>?
        scanning.importFileScanner = { _ in
            await withCheckedContinuation { scanCompletion = $0 }
        }
        let scanTask = Task { await scanning.addFiles([a.imageURL, a.videoURL]) }
        try await waitUntil { scanCompletion != nil }
        let scanOutputFolder = scanning.outputFolder
        scanning.selectOutputParentFolder(root.appendingPathComponent("blocked-during-scan"))
        expect(scanning.outputFolder == scanOutputFolder, "migration must not invalidate pending scan paths")
        scanning.clear()
        scanCompletion?.resume(returning: [a.imageURL, a.videoURL])
        await scanTask.value
        expect(scanning.files.isEmpty, "clear must invalidate pending file scans")
        pass("file scanning suspends the main actor and clear prevents late repopulation")

        let concurrent = try model("concurrent-scans")
        async let firstScan: Void = concurrent.addFiles([a.imageURL, a.videoURL])
        async let secondScan: Void = concurrent.addFiles([a.imageURL, b.imageURL, b.videoURL])
        _ = await (firstScan, secondScan)
        expect(concurrent.files.count == 4 && concurrent.pairs.count == 2, "concurrent scans must merge without duplicates")
        pass("concurrent file additions merge into current state")

        // The temporary regression executable discovers its helper beside itself.
        // A noisy stand-in exercises the real runner without media or Photos changes.
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("tool")
        let noisyHelper = "#!/usr/bin/perl\nprint STDOUT 'a' x 1048576; print STDERR 'b' x 1048576;\n"
        try noisyHelper.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        switch await LivePhotoToolRunner.run(for: a, outputFolder: root.appendingPathComponent("noisy-helper")) {
        case .success(let output): expect(output.utf8.count == 2097152, "must drain all child output without pipe deadlock")
        case .failure: preconditionFailure("noisy helper failed")
        }
        pass("composition runner drains 2 MB of stdout and stderr before waiting for exit")
        try "#!/bin/sh\nprintf 'failure details' >&2\nexit 7\n".write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        switch await LivePhotoToolRunner.run(for: a, outputFolder: root.appendingPathComponent("failed-helper")) {
        case .failure(let output): expect(output == "failure details", "must preserve failed child diagnostics")
        case .success: preconditionFailure("failed helper reported success")
        }
        try fm.removeItem(at: helper)
        pass("composition runner preserves nonzero exit and error details")

        let result = try pair(root.appendingPathComponent("result"), "same")
        let item = record(result, source: a)
        expect(item.represents(a) && !item.represents(b), "source identity must include paths")
        try Data("replacement source content".utf8).write(to: a.videoURL)
        expect(!item.represents(a), "changed source is not already composed")
        pass("completion is scoped to exact source pair and file revisions")
        expect(item.outputIsCurrent, "unchanged output must match")
        try Data("replacement output content".utf8).write(to: result.imageURL, options: .atomic)
        expect(!item.outputIsCurrent, "replaced output must invalidate import status")
        pass("same-path replacement invalidates saved state")
        let legacy = "{\"imagePath\":\"/test/a.jpg\",\"moviePath\":\"/test/a.mov\",\"importedToPhotos\":true,\"modifiedTime\":1}"
        let decoded = try JSONDecoder().decode(CompletedItem.self, from: Data(legacy.utf8))
        expect(decoded.revision == nil && decoded.sourceRevision == nil, "legacy record decode")
        pass("legacy records decode without fabricated source identity")

        let rollbackPair = try pair(root.appendingPathComponent("trash-fixture"), "pair")
        let mockTrash = root.appendingPathComponent("mock-trash", isDirectory: true)
        try fm.createDirectory(at: mockTrash, withIntermediateDirectories: true)
        let error = FileSystemUtilities.trashGroup([rollbackPair.imageURL, rollbackPair.videoURL], trash: { url in
            if url == rollbackPair.videoURL { throw CocoaError(.fileWriteNoPermission) }
            let moved = mockTrash.appendingPathComponent(url.lastPathComponent)
            try fm.moveItem(at: url, to: moved)
            return moved
        })
        expect(error != nil && fm.fileExists(atPath: rollbackPair.imageURL.path) && fm.fileExists(atPath: rollbackPair.videoURL.path), "partial trash must roll back and report failure")
        pass("partial trash failure restores the other resource")
        let deletion = try model("deletion")
        deletion.completed = [record(rollbackPair)]
        deletion.trashFiles = { _ in "测试拒绝删除" }
        deletion.clearVisibleCompleted(deleteFiles: true)
        expect(deletion.completed.count == 1 && deletion.operationNotices[.completed]?.contains("测试拒绝删除") == true, "failed deletion must retain record and visible error")
        pass("deletion failure retains record and details")

        let asyncModel = try model("async-queue")
        let original = try pair(root.appendingPathComponent("async-input"), "zzz")
        let added = try pair(original.imageURL.deletingLastPathComponent(), "aaa")
        let generated = try pair(asyncModel.outputFolder, "zzz")
        let output = "HERMES_RESULT:" + String(decoding: try JSONEncoder().encode(["imagePath": generated.imageURL.path, "moviePath": generated.videoURL.path]), as: UTF8.self)
        await asyncModel.addFiles([original.imageURL, original.videoURL])
        asyncModel.importToPhotos = true
        asyncModel.compositionRunner = { _, _ in .success(output) }
        var continuation: CheckedContinuation<PhotoImportResult, Never>?
        asyncModel.photoPairImporter = { _, _ in await withCheckedContinuation { continuation = $0 } }
        let work = Task { await asyncModel.processPairs() }
        try await waitUntil { continuation != nil }
        await asyncModel.addFiles([added.imageURL, added.videoURL])
        asyncModel.clear(deleteFiles: true)
        expect(asyncModel.pairs.count == 2, "cannot clear during composition/import")
        continuation?.resume(returning: .success(1))
        await work.value
        expect(asyncModel.pairs.map(\.id) == [added.id], "must remove original by ID after reorder")
        expect(asyncModel.completed.first?.importedToPhotos == true, "successful import recorded")
        pass("reorder during Photos await removes only the completed ID")

        let asyncDownload = try model("async-download")
        let source = try pair(asyncDownload.downloadOutputFolder, "source")
        let dest = try pair(asyncDownload.outputFolder, "source")
        let downloadOutput = "HERMES_RESULT:" + String(decoding: try JSONEncoder().encode(["imagePath": dest.imageURL.path, "moviePath": dest.videoURL.path]), as: UTF8.self)
        asyncDownload.downloadPairs = [source]
        asyncDownload.importToPhotos = true
        asyncDownload.compositionRunner = { _, _ in .success(downloadOutput) }
        var downloadContinuation: CheckedContinuation<PhotoImportResult, Never>?
        asyncDownload.photoPairImporter = { _, _ in await withCheckedContinuation { downloadContinuation = $0 } }
        let downloadWork = Task { await asyncDownload.processDownloadPairs() }
        try await waitUntil { downloadContinuation != nil }
        asyncDownload.clearVisibleDownloads(deleteFiles: true)
        expect(asyncDownload.downloadPairs.count == 1, "must not delete running inputs")
        asyncDownload.downloadPairs = [] // Simulate external file removal followed by a scan.
        downloadContinuation?.resume(returning: .failure("模拟 Photos 错误"))
        await downloadWork.value
        expect(asyncDownload.completed.count == 1 && asyncDownload.downloadStatusText.contains("1 组失败"), "valid output retained; no stale-index crash")
        pass("failed import after list removal does not access a stale index")

        let retainedHistory = try model("retained-history")
        let historicalPair = try pair(root.appendingPathComponent("historical-output"), "older")
        let legacyHistory = CompletedItem(imagePath: historicalPair.imageURL.path, moviePath: historicalPair.videoURL.path, importedToPhotos: true, modifiedTime: 1)
        retainedHistory.downloadCompleted = [legacyHistory]
        retainedHistory.downloadStatusText = "waiting for history scan"
        retainedHistory.refreshDownloads()
        try await waitUntil { retainedHistory.downloadStatusText == "输入分享链接开始下载。" }
        expect(retainedHistory.downloadCompleted == [legacyHistory], "an empty scan must not erase legacy history")
        pass("refresh retains legacy records and records outside the current directory")

        let filterModel = try model("filter-cache")
        let filterSource = try pair(filterModel.downloadOutputFolder, "filter")
        let filterOutput = try pair(filterModel.outputFolder, "filter")
        filterModel.downloadCompleted = [record(filterOutput, source: filterSource)]
        filterModel.downloadPairs = [filterSource]
        filterModel.downloadFilter = .composed
        expect(filterModel.visibleDownloadItems.count == 1, "valid completion appears in composed filter")
        try Data("changed-output".utf8).write(to: filterOutput.imageURL)
        // A filter switch only projects the last validated snapshot. Refresh/action
        // boundaries must detect a replacement; a button press must not perform disk IO.
        filterModel.downloadFilter = .all
        filterModel.downloadFilter = .composed
        expect(filterModel.visibleDownloadItems.count == 1, "filter should reuse snapshot until refresh")
        filterModel.downloadStatusText = "awaiting refresh"
        filterModel.refreshDownloads()
        try await waitUntil { filterModel.downloadStatusText.contains("已识别") }
        expect(filterModel.visibleDownloadItems.isEmpty && filterModel.downloadCompleted.count == 1, "refresh invalidates stale association without deleting history")
        pass("filter reuses snapshot; refresh revalidates changed files and retains history")

        let failures = try model("failure-notice")
        failures.recordDownloadFailures(["第一条失败"])
        failures.recordDownloadFailures([])
        failures.recordDownloadFailures(["第二条失败"])
        failures.refreshDownloads()
        try await waitUntil { failures.downloadStatusText.contains("第二条失败") }
        expect(failures.operationNotices[.downloads]?.contains("第一条失败") == true, "scan must not erase failure details")
        failures.dismissOperationNotice(for: .downloads)
        expect(failures.operationNotices[.downloads] == nil, "notice can be dismissed")
        pass("download failures survive directory refresh and later results")

        // Exercise the actual notice UI offscreen with very long text and a populated grid.
        failures.selection = .downloads
        _ = try pair(failures.downloadOutputFolder, "visible")
        failures.refreshDownloads()
        try await waitUntil { !failures.visibleDownloadItems.isEmpty }
        failures.recordDownloadFailures([String(repeating: "长错误与链接 ", count: 400)])
        let controller = DetailPagesController(model: failures, startDownload: {})
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 920, height: 620))
        controller.reload()
        controller.view.layoutSubtreeIfNeeded()
        let size = window.frame.size
        failures.recordDownloadFailures([String(repeating: "追加 ", count: 500)])
        controller.reload()
        controller.view.layoutSubtreeIfNeeded()
        expect(window.frame.size == size, "notice must not grow the window")
        pass("long failure notice does not enlarge the window")
        let notice = controller.view.subviews.compactMap { $0 as? NSButton }.first
        expect(notice?.isHidden == false && notice?.title.contains("查看详情") == true && notice?.frame.height == 32, "populated grid must expose the notice button")

        let busy = try model("busy-migration")
        let originalFolder = busy.outputFolder
        for state in 0..<4 {
            busy.isDownloading = state == 0
            busy.isProcessingDownloads = state == 1
            busy.isImportingCompleted = state == 2
            busy.isImportingDownloadMedia = state == 3
            busy.selectOutputParentFolder(root.appendingPathComponent("must-not-create"))
            expect(busy.outputFolder == originalFolder && !fm.fileExists(atPath: root.appendingPathComponent("must-not-create").path), "busy migration must not touch disk")
        }
        pass("migration refuses downloads, compositions and imports in progress")

        let nested = try model("nested-migration")
        let alias = root.appendingPathComponent("nested-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: nested.outputFolder)
        nested.selectOutputParentFolder(alias)
        expect(nested.operationNotices[.queue]?.contains("互相包含") == true, "nested destination via symlink must be rejected")
        pass("migration rejects nested destinations including symlink aliases")

        let migration = try model("migration")
        migration.outputFolder = root.appendingPathComponent("migration-old/HERMES", isDirectory: true)
        migration.downloadOutputFolder = migration.outputFolder.appendingPathComponent("Downloader", isDirectory: true)
        let downloadedPair = try pair(migration.downloadOutputFolder, "download")
        let composedPair = try pair(migration.outputFolder, "composed")
        var composedRecord = record(composedPair, source: downloadedPair)
        composedRecord.importedToPhotos = true
        migration.downloadPairs = [downloadedPair]
        migration.pairs = [downloadedPair]
        migration.files = [downloadedPair.imageURL, downloadedPair.videoURL]
        migration.completed = [composedRecord]
        migration.downloadCompleted = [composedRecord]
        migration.selectedPairIDs = [downloadedPair.id]
        migration.selectedDownloadItemIDs = ["pair:" + downloadedPair.id]
        migration.selectedCompletedIDs = [composedRecord.id]
        let newParent = root.appendingPathComponent("migration-new", isDirectory: true)
        migration.selectOutputParentFolder(newParent)
        let expectedRoot = newParent.appendingPathComponent("HERMES", isDirectory: true)
        expect(migration.outputFolder == expectedRoot, "export folder updated")
        expect(migration.downloadOutputFolder.path == expectedRoot.appendingPathComponent("Downloader").path, "nested download root updated")
        expect(migration.pairs.first?.imageURL == migration.downloadPairs.first?.imageURL, "queued source paths updated")
        expect(migration.completed.first?.importedToPhotos == true && migration.completed.first?.outputIsCurrent == true, "validated import state preserved")
        expect(migration.downloadCompleted.first?.represents(migration.downloadPairs[0]) == true, "source and output revision links preserved")
        expect(migration.selectedDownloadItemIDs.contains("pair:" + migration.downloadPairs[0].id), "download selection rebased")
        expect(migration.selectedCompletedIDs.contains(migration.completed[0].id), "completed selection rebased")
        expect(fm.fileExists(atPath: migration.files[0].path), "source still exists")
        pass("migration synchronizes nested downloads, records, selections and revisions")
        try await Task.sleep(for: .milliseconds(100))

        let external = try model("external-migration")
        let externalDownloadRoot = external.downloadOutputFolder
        let externalPair = try pair(externalDownloadRoot, "external")
        let exported = try pair(external.outputFolder, "exported")
        external.completed = [record(exported, source: externalPair)]
        external.downloadCompleted = external.completed
        external.downloadPairs = [externalPair]
        external.selectOutputParentFolder(root.appendingPathComponent("external-new"))
        expect(external.downloadOutputFolder == externalDownloadRoot && fm.fileExists(atPath: externalPair.imageURL.path), "independent download folder must not move")
        expect(external.downloadCompleted.first?.represents(externalPair) == true, "external source link retained")
        pass("migration preserves an independent download folder")
        try await Task.sleep(for: .milliseconds(100))

        let conflict = try model("conflict-migration")
        let originalConflictRoot = conflict.outputFolder
        let conflicting = try pair(originalConflictRoot, "same")
        let conflictParent = root.appendingPathComponent("conflict-target")
        let other = try pair(conflictParent.appendingPathComponent("HERMES"), "same")
        let beforeConflict = try Data(contentsOf: other.imageURL)
        conflict.selectOutputParentFolder(conflictParent)
        expect(conflict.outputFolder == originalConflictRoot && fm.fileExists(atPath: conflicting.imageURL.path), "conflict must preserve source")
        let afterConflict = try Data(contentsOf: other.imageURL)
        expect(beforeConflict == afterConflict, "conflict must preserve destination")
        pass("migration conflict changes neither source nor destination")

        let rollback = try model("rollback-migration")
        let rollbackSourceRoot = rollback.outputFolder
        let rollbackInput = try pair(rollbackSourceRoot, "pair")
        var calls = 0
        rollback.moveFile = { source, target in
            calls += 1
            if calls == 2 { throw CocoaError(.fileWriteNoPermission) }
            try fm.moveItem(at: source, to: target)
        }
        rollback.selectOutputParentFolder(root.appendingPathComponent("rollback-target"))
        expect(rollback.outputFolder == rollbackSourceRoot && fm.fileExists(atPath: rollbackInput.imageURL.path) && fm.fileExists(atPath: rollbackInput.videoURL.path), "failed migration must roll back completed moves")
        expect(rollback.operationNotices[.queue]?.contains("失败") == true, "failure shown")
        pass("failed migration rolls back files without updating preferences")

        let recoveryRoot = root.appendingPathComponent("rollback-error", isDirectory: true)
        let recoveryPair = try pair(recoveryRoot, "pair")
        let movedLocation = recoveryRoot.appendingPathComponent("moved.jpg")
        var recoveryCalls = 0
        do {
            try FileSystemUtilities.moveTransaction([(recoveryPair.imageURL, movedLocation), (recoveryPair.videoURL, recoveryRoot.appendingPathComponent("moved.mov"))], move: { a, b in
                recoveryCalls += 1
                if recoveryCalls > 1 { throw CocoaError(.fileWriteNoPermission) }
                try fm.moveItem(at: a, to: b)
            })
            preconditionFailure("expected rollback error")
        } catch {
            expect(error.localizedDescription.contains(movedLocation.path) && fm.fileExists(atPath: movedLocation.path), "report actual recoverable location if rollback fails")
        }
        pass("rollback failure reports the retained file location")

        // Audit 02e0daf: exercise production model paths with isolated files/defaults.
        let progress = try model("audit-progress")
        for (before, after) in [(1, 1), (1, 3), (3, 1)] {
            _ = progress.updateDownloadProgress(taskID: UUID(), totalCount: before, completedCount: before, unitProgress: 0)
            let nextID = UUID()
            let initial = progress.updateDownloadProgress(taskID: nextID, totalCount: after, completedCount: 0, unitProgress: 0)
            expect(initial.completedCount == 0 && initial.unitProgress == 0, "new task must start at zero")
            _ = progress.updateDownloadProgress(taskID: nextID, totalCount: after, completedCount: 0, unitProgress: 0.6)
            let late = progress.updateDownloadProgress(taskID: nextID, totalCount: after, completedCount: 0, unitProgress: 0.2)
            expect(late.unitProgress == 0.6, "same-task progress must not regress")
        }
        pass("progress resets for 1→1, 1→many, many→1 while retaining same-task monotonicity")

        let safeRefresh = try model("audit-hidden")
        for name in ["hidden-file", "hidden-dir", "empty", "concurrent-write"] {
            try fm.createDirectory(at: safeRefresh.downloadOutputFolder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let hiddenNote = safeRefresh.downloadOutputFolder.appendingPathComponent("hidden-file/.important-note")
        try Data("keep".utf8).write(to: hiddenNote)
        let hiddenGit = safeRefresh.downloadOutputFolder.appendingPathComponent("hidden-dir/.git")
        try fm.createDirectory(at: hiddenGit, withIntermediateDirectories: true)
        safeRefresh.downloadStatusText = "pending"
        safeRefresh.refreshDownloads()
        let duringScan = safeRefresh.downloadOutputFolder.appendingPathComponent("concurrent-write/new.txt")
        try Data("keep".utf8).write(to: duringScan)
        try await waitUntil { safeRefresh.downloadStatusText != "pending" }
        for url in [hiddenNote, hiddenGit, duringScan, safeRefresh.downloadOutputFolder.appendingPathComponent("empty")] {
            expect(fm.fileExists(atPath: url.path), "refresh must not remove directories or data")
        }
        pass("refresh preserves hidden files, hidden directories, empty directories and concurrent writes")

        let history = try model("audit-history")
        let auditExported = try pair(history.outputFolder, "imported")
        var imported = record(auditExported)
        imported.importedToPhotos = true
        history.completed = [imported]
        let savedHistory = try JSONEncoder().encode([imported])
        UserDefaults.standard.set(savedHistory, forKey: "CompletedRecords.v1")
        let offline = history.outputFolder.appendingPathExtension("offline")
        try fm.moveItem(at: history.outputFolder, to: offline)
        history.refreshCompleted()
        try await waitUntil { history.operationNotices[.completed] != nil }
        expect(history.completed == [imported], "offline refresh must retain all history")
        expect(UserDefaults.standard.data(forKey: "CompletedRecords.v1") == savedHistory, "offline scan must not overwrite persistence")
        let restarted = ImporterModel(refreshOnInit: false)
        expect(restarted.completed.first?.importedToPhotos == true, "offline startup must retain imported flag")
        try fm.moveItem(at: offline, to: history.outputFolder)
        history.refreshCompleted()
        try await waitUntil { history.operationNotices[.completed] == nil }
        expect(history.completed.first?.importedToPhotos == true, "directory recovery retains imported flag")
        pass("missing output and offline startup preserve history, persistence and import flags through recovery")
        let historyAlias = root.appendingPathComponent("history-alias")
        try fm.createSymbolicLink(at: historyAlias, withDestinationURL: history.outputFolder)
        var aliasRecord = imported
        aliasRecord.imagePath = historyAlias.appendingPathComponent("imported.jpg").path
        aliasRecord.moviePath = historyAlias.appendingPathComponent("imported.mov").path
        history.completed = [aliasRecord]
        history.refreshCompleted()
        try await waitUntil { history.completed.first?.imagePath == auditExported.imageURL.path }
        expect(history.completed.first?.importedToPhotos == true, "symlink aliases must retain exact-revision import history")
        pass("resolved directory alias retains import history for identical media revision")
        let realScanner = history.completedScanner
        history.completedScanner = { _ in throw CocoaError(.fileReadNoPermission) }
        history.refreshCompleted()
        try await waitUntil { history.operationNotices[.completed] != nil }
        expect(history.completed.first?.importedToPhotos == true, "permission failure must preserve import status")
        history.completedScanner = realScanner
        try Data("replacement file with different revision".utf8).write(to: auditExported.videoURL)
        history.refreshCompleted()
        try await waitUntil { history.completed.first?.importedToPhotos == false }
        expect(history.operationNotices[.completed] == nil, "recovery clears the error")
        pass("replaced media does not inherit a previous imported flag")
        try fm.removeItem(at: auditExported.imageURL)
        try fm.removeItem(at: auditExported.videoURL)
        history.refreshCompleted()
        try await waitUntil { history.completed.isEmpty }
        expect(history.operationNotices[.completed] == nil, "successful empty scan clears unavailable notice")
        pass("permission failure is preserved while successful empty scan is distinguished")

        // Suspend the real refresh state machine, not a copy of its control flow.
        let switching = try model("audit-directory-switch")
        let firstFolder = switching.downloadOutputFolder
        let secondFolder = root.appendingPathComponent("audit-B")
        let thirdFolder = root.appendingPathComponent("audit-C")
        let bPair = try pair(secondFolder, "B")
        let cPair = try pair(thirdFolder, "C")
        let scanner = switching.downloadScanner
        actor ScanGate {
            var continuation: CheckedContinuation<DownloadScanResult, Never>?
            var started = false
            func suspend() async -> DownloadScanResult {
                started = true
                return await withCheckedContinuation { continuation = $0 }
            }
            func release() { continuation?.resume(returning: DownloadScanResult(pairs: [], photos: [], videos: [])); continuation = nil }
        }
        for finalFolder in [secondFolder, thirdFolder] {
            let gate = ScanGate()
            UserDefaults.standard.removeObject(forKey: "DownloadOutputFolderBookmark.v1")
            switching.downloadOutputFolder = firstFolder
            switching.downloadScanner = { folder, excluded in
                if folder == firstFolder { return await gate.suspend() }
                return await scanner(folder, excluded)
            }
            switching.refreshDownloads()
            while !(await gate.started) { try await Task.sleep(for: .milliseconds(5)) }
            switching.selectDownloadOutputFolder(secondFolder)
            if finalFolder == thirdFolder { switching.selectDownloadOutputFolder(thirdFolder) }
            await gate.release()
            let expected = finalFolder == secondFolder ? bPair.id : cPair.id
            try await waitUntil { switching.downloadPairs.first?.id == expected }
        }
        pass("A→B and A→B→C finish on latest folder without a second manual refresh")

        for (name, imageNames, movieNames, count) in [
            ("unique", ["sample.jpg"], ["sample.mov"], 1),
            ("two-images", ["sample.jpg", "sample.heic"], ["sample.mov"], 0),
            ("two-videos", ["sample.jpg"], ["sample.mov", "sample.mp4"], 0),
            ("case", ["SAMPLE.jpg"], ["sample.mov"], 1),
            ("different-folders", ["a/sample.jpg"], ["b/sample.mov"], 0)
        ] {
            let pairingModel = try model("audit-pair-" + name)
            var inputs: [URL] = []
            for filename in imageNames + movieNames {
                let url = pairingModel.downloadOutputFolder.appendingPathComponent(filename)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: url)
                inputs.append(url)
            }
            await pairingModel.addFiles(inputs)
            pairingModel.downloadStatusText = "pending"
            pairingModel.refreshDownloads()
            try await waitUntil { pairingModel.downloadStatusText != "pending" }
            expect(pairingModel.pairs.count == count && pairingModel.downloadPairs.count == count, "both pages must use identical unique pairing")
            expect(pairingModel.downloadPhotos.count + pairingModel.downloadVideos.count == inputs.count - count * 2, "ambiguous resources must remain visible")
        }
        pass("both pages agree on unique, ambiguous, case and cross-directory pairing")

        let commands = try model("audit-commands")
        let queueInput = try pair(root.appendingPathComponent("audit-queue"), "queue")
        let downloadInput = try pair(commands.downloadOutputFolder, "download")
        await commands.addFiles([queueInput.imageURL, queueInput.videoURL])
        commands.downloadPairs = [downloadInput]
        actor CommandCalls {
            var ids: [String] = []
            func add(_ id: String) { ids.append(id) }
        }
        let commandCalls = CommandCalls()
        commands.compositionRunner = { input, _ in
            await commandCalls.add(input.id)
            return .failure("isolated command routing test")
        }
        commands.selection = .completed
        expect(!commands.canComposeCurrentPage, "completed page cannot compose hidden queue")
        await commands.composeCurrentPage()
        commands.selection = .downloads
        expect(commands.canComposeCurrentPage, "downloads enabled for available pair")
        await commands.composeCurrentPage()
        commands.selection = .queue
        await commands.composeCurrentPage()
        let routedIDs = await commandCalls.ids
        expect(routedIDs == [downloadInput.id, queueInput.id], "shared command routes only to visible page")
        pass("shared composition command routes downloads and queue; completed is disabled")

        let deleteScope = try model("audit-delete-scope")
        let deleteSource = try pair(deleteScope.downloadOutputFolder, "source")
        let keptOutput = try pair(deleteScope.outputFolder, "output")
        let keptRecord = record(keptOutput, source: deleteSource)
        deleteScope.downloadPairs = [deleteSource]
        deleteScope.downloadCompleted = [keptRecord]
        deleteScope.completed = [keptRecord]
        deleteScope.downloadStatusText = "pending"
        deleteScope.refreshDownloads()
        try await waitUntil { deleteScope.downloadStatusText != "pending" }
        var trashedURLs: [URL] = []
        deleteScope.trashFiles = { trashedURLs += $0; return nil }
        deleteScope.clearVisibleDownloads(deleteFiles: true)
        expect(Set(trashedURLs) == Set([deleteSource.imageURL, deleteSource.videoURL]), "delete action must target sources only")
        expect(deleteScope.completed == [keptRecord] && fm.fileExists(atPath: keptOutput.imageURL.path) && fm.fileExists(atPath: keptOutput.videoURL.path), "export and completed record must remain")
        pass("download deletion targets only sources and retains composed exports and completed history")

        print("PASS: \(checks) model safety scenarios; no real downloads or Photos writes")
    }
}
