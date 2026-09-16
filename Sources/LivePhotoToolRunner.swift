import Foundation

enum LivePhotoToolRunner {
    static func run(for pair: PairItem, outputFolder: URL) async -> ToolRunResult {
        await Task.detached(priority: .userInitiated) {
            switch runTool(arguments: [pair.imageURL.path, pair.videoURL.path, outputFolder.path], creates: outputFolder) {
            case .success(let output):
                return .success(output)
            case .failure(let message):
                return .failure(message)
            }
        }.value
    }

    static func prepareUniquePairsForPhotosImport(_ pairs: [(URL, URL)]) -> PreparedPhotoImportPairsResult {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HERMESPhotoImport-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        } catch {
            return .failure(error.localizedDescription)
        }

        var preparedPairs: [(URL, URL)] = []
        for (index, pair) in pairs.enumerated() {
            let pairFolder = temporaryRoot
                .appendingPathComponent(String(format: "%03d-%@", index, UUID().uuidString), isDirectory: true)
            let assetID = UUID().uuidString.uppercased()
            let arguments = [pair.0.path, pair.1.path, pairFolder.path, "--asset-id", assetID]
            switch runTool(arguments: arguments, creates: pairFolder) {
            case .success:
                guard let preparedPair = livePhotoPair(in: pairFolder, matchingStem: completedStem(for: pair.0)) else {
                    try? FileManager.default.removeItem(at: temporaryRoot)
                    return .failure("导入前准备 Live Photo 失败。")
                }
                preparedPairs.append(preparedPair)
            case .failure(let message):
                try? FileManager.default.removeItem(at: temporaryRoot)
                return .failure(message.isEmpty ? "导入前准备 Live Photo 失败。" : message)
            }
        }

        return .success(pairs: preparedPairs, folder: temporaryRoot)
    }

    private static func runTool(arguments: [String], creates folder: URL) -> ToolRunResult {
        guard let toolURL = toolURL() else {
            return .failure("找不到合成工具。")
        }

        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try process.run()
            // Drain while the child is running; waiting first can fill the pipe and deadlock.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                return .failure(output)
            }
            return .success(output)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func toolURL() -> URL? {
        if let bundledURL = Bundle.main.url(forResource: "tool", withExtension: nil) {
            return bundledURL
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let swiftPMToolURL = executableURL.deletingLastPathComponent().appendingPathComponent("tool")
        if FileManager.default.isExecutableFile(atPath: swiftPMToolURL.path) {
            return swiftPMToolURL
        }

        return nil
    }

    private static func livePhotoPair(in folder: URL, matchingStem stem: String) -> (URL, URL)? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var imageURL: URL?
        var movieURL: URL?
        for url in urls where completedStem(for: url) == stem {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            if FileSystemUtilities.isImage(url) {
                imageURL = url
            } else if FileSystemUtilities.isVideo(url) {
                movieURL = url
            }
        }

        guard let imageURL, let movieURL else { return nil }
        return (imageURL, movieURL)
    }

    private static func completedStem(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }
}
