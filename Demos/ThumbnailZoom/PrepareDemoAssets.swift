import Foundation
import ImageIO
import UniformTypeIdentifiers

// Build-time preview preparation. Originals stay read-only. Only small JPEGs
// are placed inside the Demo bundle; the running app needs no folder permission.
let sourceDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let extensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "webp", "avif", "tiff"]
let enumerator = FileManager.default.enumerator(at: sourceDirectory,
    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
let urls = (enumerator?.compactMap { $0 as? URL } ?? []).filter {
    extensions.contains($0.pathExtension.lowercased()) &&
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.prefix(180)
var count = 0
for url in urls {
    autoreleasepool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return }
        let output = outputDirectory.appendingPathComponent(String(format: "preview-%03d.jpg", count + 1))
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image,
                                  [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        if CGImageDestinationFinalize(destination) { count += 1 }
    }
}
print("Prepared \(count) read-only-source Demo previews")
