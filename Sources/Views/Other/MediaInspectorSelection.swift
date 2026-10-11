import Foundation

/// Keeps each selected item's evidence separate before presenting shared values.
struct MediaInspectorSelection {
    let count: Int
    let requests: [MediaInspection.Request]

    @MainActor
    init(model: ImporterModel) {
        switch model.selection ?? .queue {
        case .queue:
            count = model.selectedPairIDs.count
            requests = model.selectedPairs.map { item in
                let state: String
                switch item.status {
                case .waiting: state = "未合成"
                case .running: state = "合成中"
                case .finished: state = "已合成"
                case .failed: state = "合成失败"
                }
                return .init(name: item.imageURL.deletingPathExtension().lastPathComponent,
                    sourceURLs: [item.imageURL, item.videoURL], displayedURLs: [item.imageURL, item.videoURL],
                    kind: "Live Photo 配对", compositionState: state)
            }
        case .downloads:
            count = model.selectedDownloadItemIDs.count
            requests = model.visibleDownloadItems.filter { model.selectedDownloadItemIDs.contains($0.id) }.compactMap { item in
                let urls: [URL]
                switch item.kind {
                case .pair(let pairID):
                    guard let pair = model.downloadPairs.first(where: { $0.id == pairID }) else { return nil }
                    urls = [pair.imageURL, pair.videoURL]
                case .photo, .video: urls = [item.imageURL]
                }
                let kind = item.mediaKind == .livePhoto ? "Live Photo 配对" : (item.mediaKind == .video ? "视频" : "照片")
                let state = item.mediaKind == .livePhoto ? (item.isCompleted ? "已合成" : (item.status == .running ? "合成中" : "未合成")) : "不适用"
                return .init(name: item.imageURL.lastPathComponent, sourceURLs: urls, displayedURLs: urls,
                    kind: kind, compositionState: state)
            }
        case .completed:
            count = model.selectedCompletedIDs.count
            requests = model.selectedCompletedItems.map { item in
                let outputs = [item.imageURL] + (item.movieURL.map { [$0] } ?? [])
                let sources = [item.sourceImagePath, item.sourceVideoPath].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
                let kind = item.mediaKind == .livePhoto ? "Live Photo" : (item.mediaKind == .video ? "视频" : "照片")
                let hasCompositionRecord = item.movieURL != nil && item.sourceImagePath != nil && item.sourceVideoPath != nil
                let currentOutput = item.outputIsCurrent
                let currentSource = sources.count == 2 && item.sourceRevision != nil
                    && item.sourceRevision == MediaPairRevision(image: sources[0], movie: sources[1])
                // A reused source path alone cannot establish output identity.
                let evidence = hasCompositionRecord ? (currentSource && currentOutput ? sources : []) : outputs
                return .init(name: item.imageURL.lastPathComponent, sourceURLs: evidence,
                    displayedURLs: outputs, kind: kind,
                    compositionState: item.movieURL == nil ? "不适用" : (hasCompositionRecord
                        ? (currentOutput ? "已合成" : "文件已变化，合成状态待确认") : "未记录合成状态"),
                    isCompositionOutput: hasCompositionRecord && currentOutput, importedToPhotos: item.importedToPhotos)
            }
        }
    }

    static func commonSnapshot(_ snapshots: [MediaInspection.Snapshot]) -> MediaInspection.Snapshot {
        guard let first = snapshots.first else { return .init(rows: []) }
        guard snapshots.count > 1 else { return first }
        // Preserve the single-item section/field order and evidence rules.
        // A missing or loading value cannot establish a common property.
        let rows = snapshots.dropFirst().reduce(first.inspectorRows) { common, snapshot in
            let available = snapshot.inspectorRows
            return common.filter { available.contains($0) }
        }
        let location = first.location.flatMap { location in
            snapshots.dropFirst().allSatisfy { $0.location == location } ? location : nil
        }
        return .init(rows: rows, location: location)
    }
}
