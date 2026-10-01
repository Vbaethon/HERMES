import AVFoundation
import CoreMedia
import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

enum ToolError: Error, CustomStringConvertible {
    case usage
    case noAssetID
    case noVideoTrack
    case cannotAddReaderOutput
    case cannotAddWriterInput
    case failed(String)

    var description: String {
        switch self {
        case .usage:
            return "Usage: tool <cover.jpeg|heic> <source-video.mp4|mov> <output-folder> [--asset-id UUID]"
        case .noAssetID:
            return "Could not find the Apple Live Photo asset identifier in the JPEG MakerNote."
        case .noVideoTrack:
            return "No video track found."
        case .cannotAddReaderOutput:
            return "Could not add reader output."
        case .cannotAddWriterInput:
            return "Could not add writer input."
        case .failed(let message):
            return message
        }
    }
}

private struct MediaPipe: @unchecked Sendable {
    let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
    let receiver: AVAssetWriterInput.SampleBufferReceiver
}

func readUInt16BE(_ data: Data, _ offset: Int) -> UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
}

func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
    (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
}

func tiffTypeSize(_ type: UInt16) -> Int {
    switch type {
    case 1, 2, 6, 7: return 1
    case 3, 8: return 2
    case 4, 9, 11: return 4
    case 5, 10, 12, 16, 17, 18: return 8
    default: return 1
    }
}

func extractAssetID(from jpegURL: URL) throws -> String {
    let data = try Data(contentsOf: jpegURL)
    guard data.count > 4, data[0] == 0xff, data[1] == 0xd8 else { throw ToolError.noAssetID }
    var offset = 2
    while offset + 4 <= data.count {
        guard data[offset] == 0xff else { break }
        let marker = data[offset + 1]
        if marker == 0xda || marker == 0xd9 { break }
        let length = Int(readUInt16BE(data, offset + 2))
        guard length >= 2, length <= data.count - offset - 2 else { throw ToolError.noAssetID }
        let start = offset + 4
        let end = offset + 2 + length
        if marker == 0xe1, end - start >= 6,
           data[start..<start + 6] == Data("Exif\0\0".utf8) {
            return try extractAssetIDFromTIFF(Data(data[start + 6..<end]))
        }
        offset = end
    }
    throw ToolError.noAssetID
}

/// Bounds-checked ISO BMFF boxes, shared by HEIF metadata and MOV field edits.
struct ISOBox {
    let range: Range<Int>
    let payload: Range<Int>
    let type: UInt32
    var typeRange: Range<Int> { range.lowerBound + 4..<range.lowerBound + 8 }
    func isType(_ name: String) -> Bool { type == fourCC(name) }
}

func fourCC(_ name: String) -> UInt32 {
    name.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

func isoBox(in data: Data, offset: Int, limit: Int) throws -> ISOBox {
    guard offset >= data.startIndex, limit <= data.endIndex, offset <= limit, limit - offset >= 8 else { throw ToolError.noAssetID }
    let shortSize = Int(readUInt32BE(data, offset))
    var headerSize = 8
    let size: Int
    if shortSize == 1 {
        guard limit - offset >= 16 else { throw ToolError.noAssetID }
        let longSize = (UInt64(readUInt32BE(data, offset + 8)) << 32) | UInt64(readUInt32BE(data, offset + 12))
        guard longSize <= UInt64(limit - offset) else { throw ToolError.noAssetID }
        size = Int(longSize)
        headerSize = 16
    } else { size = shortSize == 0 ? limit - offset : shortSize }
    guard size >= headerSize, size <= limit - offset else { throw ToolError.noAssetID }
    return ISOBox(range: offset..<offset + size, payload: offset + headerSize..<offset + size,
                  type: readUInt32BE(data, offset + 4))
}

func isoBoxes(in data: Data, range: Range<Int>) throws -> [ISOBox] {
    guard range.lowerBound >= data.startIndex, range.upperBound <= data.endIndex else { throw ToolError.noAssetID }
    var result: [ISOBox] = []
    var offset = range.lowerBound
    while offset < range.upperBound {
        let box = try isoBox(in: data, offset: offset, limit: range.upperBound)
        result.append(box)
        offset = box.range.upperBound
    }
    return result
}

// Older HERMES HEIF exports appended Exif bytes without an enclosing box.
// Locate meta without interpreting that historical tail as another box.
func firstISOBox(ofType type: String, in data: Data) throws -> ISOBox? {
    var offset = data.startIndex
    while offset < data.endIndex {
        let box = try isoBox(in: data, offset: offset, limit: data.endIndex)
        if box.isType(type) { return box }
        offset = box.range.upperBound
    }
    return nil
}

struct MetadataCursor {
    let data: Data
    let limit: Int
    var offset: Int

    mutating func integer(_ count: Int) throws -> Int {
        guard count >= 0, count <= 8, offset >= data.startIndex,
              offset <= limit, count <= limit - offset, limit <= data.endIndex else { throw ToolError.noAssetID }
        var value: UInt64 = 0
        for byte in data[offset..<offset + count] { value = (value << 8) | UInt64(byte) }
        guard value <= UInt64(Int.max) else { throw ToolError.noAssetID }
        offset += count
        return Int(value)
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset <= limit, count <= limit - offset else { throw ToolError.noAssetID }
        offset += count
    }
}

struct HEICExifItemLocation {
    var itemRange: Range<Int>
    var constructionMethodRange: Range<Int>?
    var baseOffsetRange: Range<Int>
    var extentOffsetRange: Range<Int>
    var extentLengthRange: Range<Int>
}

func readIntegerBE(_ data: Data, range: Range<Int>) -> Int {
    var value = 0
    for byte in data[range] {
        value = (value << 8) | Int(byte)
    }
    return value
}

func writeIntegerBE(_ value: Int, range: Range<Int>, in data: inout Data) {
    let byteCount = range.count
    for index in 0..<byteCount {
        let shift = (byteCount - index - 1) * 8
        data[range.lowerBound + index] = UInt8((value >> shift) & 0xff)
    }
}

func integerFits(_ value: Int, byteCount: Int) -> Bool {
    guard byteCount > 0 else { return value == 0 }
    if byteCount >= MemoryLayout<Int>.size {
        return true
    }
    return value >= 0 && value < (1 << (byteCount * 8))
}

func heicExifItemLocation(in data: Data) throws -> HEICExifItemLocation {
    guard let meta = try firstISOBox(ofType: "meta", in: data),
          meta.payload.count >= 4 else { throw ToolError.noAssetID }
    let children = try isoBoxes(in: data, range: meta.payload.lowerBound + 4..<meta.payload.upperBound)
    var exifItemID: Int?
    if let info = children.first(where: { $0.isType("iinf") }), info.payload.count >= 4 {
        var cursor = MetadataCursor(data: data, limit: info.payload.upperBound, offset: info.payload.lowerBound)
        let version = try cursor.integer(1)
        try cursor.skip(3)
        let count = try cursor.integer(version == 0 ? 2 : 4)
        let entries = try isoBoxes(in: data, range: cursor.offset..<info.payload.upperBound)
        guard count == entries.count else { throw ToolError.noAssetID }
        for entry in entries where entry.isType("infe") {
            var item = MetadataCursor(data: data, limit: entry.payload.upperBound, offset: entry.payload.lowerBound)
            let version = try item.integer(1)
            try item.skip(3)
            guard version == 2 || version == 3 else { continue }
            let identifier = try item.integer(version == 2 ? 2 : 4)
            try item.skip(2)
            if try item.integer(4) == Int(fourCC("Exif")) { exifItemID = identifier }
        }
    }
    guard let exifItemID, let location = children.first(where: { $0.isType("iloc") }), location.payload.count >= 4 else {
        throw ToolError.noAssetID
    }
    var cursor = MetadataCursor(data: data, limit: location.payload.upperBound, offset: location.payload.lowerBound)
    let version = try cursor.integer(1)
    guard version <= 2 else { throw ToolError.noAssetID }
    try cursor.skip(3)
    let sizes1 = try cursor.integer(1), sizes2 = try cursor.integer(1)
    let offsetSize = sizes1 >> 4, lengthSize = sizes1 & 15
    let baseSize = sizes2 >> 4, indexSize = version == 0 ? 0 : sizes2 & 15
    guard [offsetSize, lengthSize, baseSize, indexSize].allSatisfy({ $0 <= 8 }) else { throw ToolError.noAssetID }
    let count = try cursor.integer(version < 2 ? 2 : 4)
    // Every item consumes at least an ID, data reference and extent count.
    guard count <= (cursor.limit - cursor.offset) / (version < 2 ? 6 : 8) else { throw ToolError.noAssetID }
    for _ in 0..<count {
        let identifier = try cursor.integer(version < 2 ? 2 : 4)
        let methodRange = version == 0 ? nil : cursor.offset..<cursor.offset + 2
        let method = version == 0 ? 0 : try cursor.integer(2) & 15
        let dataReference = try cursor.integer(2)
        let baseRange = cursor.offset..<cursor.offset + baseSize
        let base = try cursor.integer(baseSize)
        let extentCount = try cursor.integer(2)
        let extentWidth = indexSize + offsetSize + lengthSize
        guard extentWidth > 0 || extentCount == 0,
              extentWidth == 0 || extentCount <= (cursor.limit - cursor.offset) / extentWidth else { throw ToolError.noAssetID }
        var result: HEICExifItemLocation?
        for index in 0..<extentCount {
            try cursor.skip(indexSize)
            let offsetRange = cursor.offset..<cursor.offset + offsetSize
            let extentOffset = try cursor.integer(offsetSize)
            let lengthRange = cursor.offset..<cursor.offset + lengthSize
            let length = try cursor.integer(lengthSize)
            if identifier == exifItemID, index == 0 {
                guard dataReference == 0, method <= 1, extentCount == 1 else { throw ToolError.noAssetID }
                let origin: Int
                let limit: Int
                if method == 1 {
                    guard let itemData = children.first(where: { $0.isType("idat") }) else { throw ToolError.noAssetID }
                    origin = itemData.payload.lowerBound
                    limit = itemData.payload.upperBound
                } else { origin = data.startIndex; limit = data.endIndex }
                guard base <= limit - origin, extentOffset <= limit - origin - base,
                      length <= limit - origin - base - extentOffset else { throw ToolError.noAssetID }
                let start = origin + base + extentOffset
                result = HEICExifItemLocation(itemRange: start..<start + length,
                    constructionMethodRange: methodRange, baseOffsetRange: baseRange,
                    extentOffsetRange: offsetRange, extentLengthRange: lengthRange)
            }
        }
        if let result { return result }
    }
    throw ToolError.noAssetID
}

func extractHEICExifData(from heicURL: URL) throws -> Data {
    let data = try Data(contentsOf: heicURL)
    let location = try heicExifItemLocation(in: data)
    let exifItem = Data(data[location.itemRange])
    guard exifItem.count >= 4 else { throw ToolError.noAssetID }
    let tiffOffset = Int(readUInt32BE(exifItem, 0))
    guard tiffOffset <= exifItem.count - 4 else { throw ToolError.noAssetID }
    return Data(exifItem.dropFirst(4 + tiffOffset))
}

func extractAssetIDFromTIFF(_ data: Data) throws -> String {
    guard data.count >= 8, data[0] == 0x4d, data[1] == 0x4d,
          readUInt16BE(data, 2) == 42 else { throw ToolError.noAssetID }
    let ifd0 = try parseIFDEntries(from: data, offset: Int(readUInt32BE(data, 4))).0
    guard let exif = ifd0.first(where: { $0.tag == 0x8769 && $0.type == 4 && $0.count == 1 }) else { throw ToolError.noAssetID }
    let exifEntries = try parseIFDEntries(from: data, offset: Int(readUInt32BE(exif.valueField, 0))).0
    guard let maker = exifEntries.first(where: { $0.tag == 0x927c })?.referencedData,
          maker.count >= 18, String(data: maker.prefix(9), encoding: .ascii) == "Apple iOS" else { throw ToolError.noAssetID }
    let entries = try parseIFDEntries(from: maker, offset: 14).0
    guard let identifier = entries.first(where: { $0.tag == 17 && $0.type == 2 && $0.count > 1 }) else { throw ToolError.noAssetID }
    let bytes = identifier.referencedData ?? Data(identifier.valueField.prefix(Int(identifier.count)))
    guard let value = String(data: bytes.filter { $0 != 0 }, encoding: .utf8), !value.isEmpty else { throw ToolError.noAssetID }
    return value
}

func extractAssetIDFromMovie(_ movieURL: URL) async throws -> String {
    let asset = AVURLAsset(url: movieURL)
    var identifiers = Set<String>()
    for format in try await asset.load(.availableMetadataFormats) {
        for item in try await asset.loadMetadata(for: format)
        where item.identifier == .quickTimeMetadataContentIdentifier {
            if let value = try await item.load(.stringValue), !value.isEmpty { identifiers.insert(value) }
        }
    }
    guard identifiers.count == 1, let identifier = identifiers.first else { throw ToolError.noAssetID }
    return identifier
}

func movieMetadataValueRanges(in data: Data, key: String) throws -> [Range<Int>] {
    guard let movie = try isoBoxes(in: data, range: data.startIndex..<data.endIndex).first(where: { $0.isType("moov") }) else {
        throw ToolError.noAssetID
    }
    let movieChildren = try isoBoxes(in: data, range: movie.payload)
    var containers = movieChildren.filter { $0.isType("meta") }
    for userData in movieChildren where userData.isType("udta") {
        containers += try isoBoxes(in: data, range: userData.payload).filter { $0.isType("meta") }
    }
    var ranges: [Range<Int>] = []
    for container in containers {
        // QuickTime meta has no version/flags; ISO meta is a FullBox.
        let children: [ISOBox]
        if let quickTime = try? isoBoxes(in: data, range: container.payload) { children = quickTime }
        else {
            guard container.payload.count >= 4, readUInt32BE(data, container.payload.lowerBound) == 0 else { throw ToolError.noAssetID }
            children = try isoBoxes(in: data, range: container.payload.lowerBound + 4..<container.payload.upperBound)
        }
        guard let handler = children.first(where: { $0.isType("hdlr") }), handler.payload.count >= 12,
              readUInt32BE(data, handler.payload.lowerBound + 8) == fourCC("mdta"),
              let keys = children.first(where: { $0.isType("keys") }), keys.payload.count >= 8,
              let values = children.first(where: { $0.isType("ilst") }) else { continue }
        var cursor = MetadataCursor(data: data, limit: keys.payload.upperBound, offset: keys.payload.lowerBound)
        guard try cursor.integer(4) == 0 else { throw ToolError.noAssetID }
        let count = try cursor.integer(4)
        guard count <= (cursor.limit - cursor.offset) / 8 else { throw ToolError.noAssetID }
        var indices = Set<UInt32>()
        for index in 0..<count {
            let size = try cursor.integer(4)
            guard size >= 8, size - 4 <= cursor.limit - cursor.offset else { throw ToolError.noAssetID }
            let namespace = try cursor.integer(4)
            let end = cursor.offset + size - 8
            if namespace == Int(fourCC("mdta")), String(data: data[cursor.offset..<end], encoding: .utf8) == key {
                indices.insert(UInt32(index + 1))
            }
            cursor.offset = end
        }
        guard cursor.offset == cursor.limit else { throw ToolError.noAssetID }
        for value in try isoBoxes(in: data, range: values.payload) where indices.contains(value.type) {
            let atoms = try isoBoxes(in: data, range: value.payload)
            guard atoms.count == 1, let atom = atoms.first, atom.isType("data"), atom.payload.count >= 8,
                  readUInt32BE(data, atom.payload.lowerBound) == 1 else { throw ToolError.noAssetID }
            ranges.append(atom.payload.lowerBound + 8..<atom.payload.upperBound)
        }
    }
    return ranges
}

func copyMovieReplacingAssetIDIfPossible(sourceURL: URL, outputURL: URL, assetID: String) async throws -> Bool {
    guard fileContainsAllASCII(["com.apple.quicktime.still-image-time"], in: sourceURL),
          let existingAssetID = try? await extractAssetIDFromMovie(sourceURL) else { return false }
    let asset = AVURLAsset(url: sourceURL)
    guard !(try await asset.loadTracks(withMediaType: .metadata)).isEmpty else { return false }
    var data = try Data(contentsOf: sourceURL)
    let existingBytes = Data(existingAssetID.utf8), replacementBytes = Data(assetID.utf8)
    guard existingBytes.count == replacementBytes.count,
          let ranges = try? movieMetadataValueRanges(in: data, key: "com.apple.quicktime.content.identifier"),
          !ranges.isEmpty, ranges.allSatisfy({ data[$0] == existingBytes }) else { return false }
    for range in ranges { data.replaceSubrange(range, with: replacementBytes) }
    try? FileManager.default.removeItem(at: outputURL)
    try data.write(to: outputURL, options: .atomic)
    guard (try? await extractAssetIDFromMovie(outputURL)) == assetID else {
        try? FileManager.default.removeItem(at: outputURL)
        return false
    }
    return true
}

func jpegDimensions(_ data: Data) -> (width: UInt32, height: UInt32) {
    var offset = 2
    while offset + 9 < data.count, data[offset] == 0xff {
        let marker = data[offset + 1]
        if marker == 0xda { break }
        let length = Int(readUInt16BE(data, offset + 2))
        if marker == 0xc0 || marker == 0xc2 {
            let height = UInt32(readUInt16BE(data, offset + 5))
            let width = UInt32(readUInt16BE(data, offset + 7))
            return (width, height)
        }
        offset += 2 + length
    }
    return (0, 0)
}

func appendUInt16BE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

func tiffEntry(tag: UInt16, type: UInt16, count: UInt32, value: Data) -> Data {
    var entry = Data()
    appendUInt16BE(tag, to: &entry)
    appendUInt16BE(type, to: &entry)
    appendUInt32BE(count, to: &entry)
    entry.append(value.prefix(4))
    if value.count < 4 {
        entry.append(contentsOf: Array(repeating: 0, count: 4 - value.count))
    }
    return entry
}

func tiffEntry(tag: UInt16, type: UInt16, count: UInt32, offsetOrValue: UInt32) -> Data {
    var value = Data()
    appendUInt32BE(offsetOrValue, to: &value)
    return tiffEntry(tag: tag, type: type, count: count, value: value)
}

func shortInline(_ value: UInt16) -> Data {
    var data = Data()
    appendUInt16BE(value, to: &data)
    data.append(contentsOf: [0, 0])
    return data
}

func undefinedInline(_ bytes: [UInt8]) -> Data {
    var data = Data(bytes.prefix(4))
    if data.count < 4 {
        data.append(contentsOf: Array(repeating: 0, count: 4 - data.count))
    }
    return data
}

func makeAppleMakerNote(assetID: String) -> Data {
    let uuid = Data((assetID + "\0").utf8)
    var maker = Data("Apple iOS\0\0".utf8)
    maker.append(1)
    maker.append(Data("MM".utf8))
    appendUInt16BE(1, to: &maker)
    maker.append(tiffEntry(tag: 17, type: 2, count: UInt32(uuid.count), offsetOrValue: 32))
    appendUInt32BE(0, to: &maker)
    maker.append(uuid)
    return maker
}

func makePreservingAppleMakerNote(from existingMaker: Data, assetID: String) throws -> Data {
    guard existingMaker.count > 18,
          String(data: existingMaker[existingMaker.startIndex..<existingMaker.startIndex + 9], encoding: .ascii) == "Apple iOS" else {
        throw ToolError.noAssetID
    }

    var entries = try parseIFDEntries(from: existingMaker, offset: 14).0
    let uuid = Data((assetID + "\0").utf8)
    let assetIDEntry = PreservedTIFFEntry(
        tag: 17,
        type: 2,
        count: UInt32(uuid.count),
        valueField: Data([0, 0, 0, 0]),
        referencedData: uuid
    )

    if let index = entries.firstIndex(where: { $0.tag == 17 }) {
        entries[index] = assetIDEntry
    } else if let insertionIndex = entries.firstIndex(where: { $0.tag > 17 }) {
        entries.insert(assetIDEntry, at: insertionIndex)
    } else {
        entries.append(assetIDEntry)
    }

    var maker = Data(existingMaker.prefix(14))
    maker.append(serializeIFD(entries, ifdOffset: 14))
    return maker
}

func makeLivePhotoExifSegment(width: UInt32, height: UInt32, assetID: String) throws -> Data {
    let maker = makeAppleMakerNote(assetID: assetID)
    let ifd0Count = 6
    let exifCount = 8
    let ifd0Offset = 8
    let ifd0Size = 2 + ifd0Count * 12 + 4
    let xResolutionOffset = ifd0Offset + ifd0Size
    let yResolutionOffset = xResolutionOffset + 8
    let exifOffset = yResolutionOffset + 8
    let exifSize = 2 + exifCount * 12 + 4
    let makerOffset = exifOffset + exifSize

    var tiff = Data()
    tiff.append(Data("MM".utf8))
    appendUInt16BE(42, to: &tiff)
    appendUInt32BE(UInt32(ifd0Offset), to: &tiff)

    appendUInt16BE(UInt16(ifd0Count), to: &tiff)
    tiff.append(tiffEntry(tag: 0x0112, type: 3, count: 1, value: shortInline(1)))
    tiff.append(tiffEntry(tag: 0x011a, type: 5, count: 1, offsetOrValue: UInt32(xResolutionOffset)))
    tiff.append(tiffEntry(tag: 0x011b, type: 5, count: 1, offsetOrValue: UInt32(yResolutionOffset)))
    tiff.append(tiffEntry(tag: 0x0128, type: 3, count: 1, value: shortInline(2)))
    tiff.append(tiffEntry(tag: 0x0213, type: 3, count: 1, value: shortInline(1)))
    tiff.append(tiffEntry(tag: 0x8769, type: 4, count: 1, offsetOrValue: UInt32(exifOffset)))
    appendUInt32BE(0, to: &tiff)

    appendUInt32BE(72, to: &tiff)
    appendUInt32BE(1, to: &tiff)
    appendUInt32BE(72, to: &tiff)
    appendUInt32BE(1, to: &tiff)

    appendUInt16BE(UInt16(exifCount), to: &tiff)
    tiff.append(tiffEntry(tag: 0x9000, type: 7, count: 4, value: undefinedInline([0x30, 0x32, 0x32, 0x31])))
    tiff.append(tiffEntry(tag: 0x9101, type: 7, count: 4, value: undefinedInline([1, 2, 3, 0])))
    tiff.append(tiffEntry(tag: 0x927c, type: 7, count: UInt32(maker.count), offsetOrValue: UInt32(makerOffset)))
    tiff.append(tiffEntry(tag: 0xa000, type: 7, count: 4, value: undefinedInline([0x30, 0x31, 0x30, 0x30])))
    tiff.append(tiffEntry(tag: 0xa001, type: 3, count: 1, value: shortInline(1)))
    tiff.append(tiffEntry(tag: 0xa002, type: 4, count: 1, offsetOrValue: width))
    tiff.append(tiffEntry(tag: 0xa003, type: 4, count: 1, offsetOrValue: height))
    tiff.append(tiffEntry(tag: 0xa406, type: 3, count: 1, value: shortInline(0)))
    appendUInt32BE(0, to: &tiff)
    tiff.append(maker)

    var payload = Data("Exif\0\0".utf8)
    payload.append(tiff)

    guard payload.count + 2 <= UInt16.max else { throw ToolError.noAssetID }
    var segment = Data([0xff, 0xe1])
    appendUInt16BE(UInt16(payload.count + 2), to: &segment)
    segment.append(payload)
    return segment
}

struct PreservedTIFFEntry {
    var tag: UInt16
    var type: UInt16
    var count: UInt32
    var valueField: Data
    var referencedData: Data?
}

func tiffByteCount(type: UInt16, count: UInt32) -> Int {
    Int(count) * tiffTypeSize(type)
}

func parseIFDEntries(from tiff: Data, offset: Int) throws -> ([PreservedTIFFEntry], UInt32) {
    guard offset >= tiff.startIndex, offset <= tiff.endIndex, tiff.endIndex - offset >= 2 else { throw ToolError.noAssetID }
    let count = Int(readUInt16BE(tiff, offset))
    let entriesStart = offset + 2
    let nextOffsetPosition = entriesStart + count * 12
    guard nextOffsetPosition <= tiff.endIndex, tiff.endIndex - nextOffsetPosition >= 4 else { throw ToolError.noAssetID }

    var entries: [PreservedTIFFEntry] = []
    for index in 0..<count {
        let entryOffset = entriesStart + index * 12
        let tag = readUInt16BE(tiff, entryOffset)
        let type = readUInt16BE(tiff, entryOffset + 2)
        let itemCount = readUInt32BE(tiff, entryOffset + 4)
        let valueField = Data(tiff[entryOffset + 8..<entryOffset + 12])
        let byteCount = tiffByteCount(type: type, count: itemCount)
        let referencedData: Data?
        if byteCount > 4 {
            let dataOffset = Int(readUInt32BE(tiff, entryOffset + 8))
            guard dataOffset >= tiff.startIndex, dataOffset <= tiff.endIndex, byteCount <= tiff.endIndex - dataOffset else { throw ToolError.noAssetID }
            referencedData = Data(tiff[dataOffset..<dataOffset + byteCount])
        } else {
            referencedData = nil
        }
        entries.append(PreservedTIFFEntry(tag: tag, type: type, count: itemCount, valueField: valueField, referencedData: referencedData))
    }

    return (entries, readUInt32BE(tiff, nextOffsetPosition))
}

func serializedIFDLength(_ entries: [PreservedTIFFEntry]) -> Int {
    2 + entries.count * 12 + 4 + entries.reduce(0) { total, entry in
        total + (entry.referencedData?.count ?? 0)
    }
}

func serializeIFD(_ entries: [PreservedTIFFEntry], ifdOffset: Int, overrides: [UInt16: UInt32] = [:]) -> Data {
    var ifd = Data()
    var referencedData = Data()
    var nextDataOffset = UInt32(ifdOffset + 2 + entries.count * 12 + 4)

    appendUInt16BE(UInt16(entries.count), to: &ifd)
    for entry in entries {
        appendUInt16BE(entry.tag, to: &ifd)
        appendUInt16BE(entry.type, to: &ifd)
        appendUInt32BE(entry.count, to: &ifd)

        if let override = overrides[entry.tag] {
            appendUInt32BE(override, to: &ifd)
        } else if let data = entry.referencedData {
            appendUInt32BE(nextDataOffset, to: &ifd)
            referencedData.append(data)
            nextDataOffset += UInt32(data.count)
        } else {
            ifd.append(entry.valueField.prefix(4))
            if entry.valueField.count < 4 {
                ifd.append(contentsOf: Array(repeating: 0, count: 4 - entry.valueField.count))
            }
        }
    }
    appendUInt32BE(0, to: &ifd)
    ifd.append(referencedData)
    return ifd
}

func makePreservingLivePhotoExifSegment(from existingSegmentPayload: Data, assetID: String) throws -> Data {
    guard existingSegmentPayload.count > 14,
          existingSegmentPayload[0..<6] == Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) else {
        throw ToolError.noAssetID
    }

    let originalTIFF = Data(existingSegmentPayload.dropFirst(6))
    guard originalTIFF.count > 16,
          originalTIFF[0] == 0x4d,
          originalTIFF[1] == 0x4d else {
        throw ToolError.noAssetID
    }

    let ifd0Offset = Int(readUInt32BE(originalTIFF, 4))
    var (ifd0Entries, _) = try parseIFDEntries(from: originalTIFF, offset: ifd0Offset)
    guard let exifPointerEntry = ifd0Entries.first(where: { $0.tag == 0x8769 }) else {
        throw ToolError.noAssetID
    }

    let originalExifOffset = Int(readUInt32BE(exifPointerEntry.valueField, 0))
    var (exifEntries, _) = try parseIFDEntries(from: originalTIFF, offset: originalExifOffset)
    let gpsEntries: [PreservedTIFFEntry]?
    if let gpsPointerEntry = ifd0Entries.first(where: { $0.tag == 0x8825 }) {
        let originalGPSOffset = Int(readUInt32BE(gpsPointerEntry.valueField, 0))
        gpsEntries = try parseIFDEntries(from: originalTIFF, offset: originalGPSOffset).0
    } else {
        gpsEntries = nil
    }

    let existingMaker = exifEntries.first(where: { $0.tag == 0x927c })?.referencedData
    let maker = existingMaker.flatMap { try? makePreservingAppleMakerNote(from: $0, assetID: assetID) }
        ?? makeAppleMakerNote(assetID: assetID)
    let makerEntry = PreservedTIFFEntry(
        tag: 0x927c,
        type: 7,
        count: UInt32(maker.count),
        valueField: Data([0, 0, 0, 0]),
        referencedData: maker
    )

    if let makerIndex = exifEntries.firstIndex(where: { $0.tag == 0x927c }) {
        exifEntries[makerIndex] = makerEntry
    } else if let insertionIndex = exifEntries.firstIndex(where: { $0.tag > 0x927c }) {
        exifEntries.insert(makerEntry, at: insertionIndex)
    } else {
        exifEntries.append(makerEntry)
    }

    if !ifd0Entries.contains(where: { $0.tag == 0x8769 }) {
        ifd0Entries.append(PreservedTIFFEntry(tag: 0x8769, type: 4, count: 1, valueField: Data([0, 0, 0, 0]), referencedData: nil))
    }

    let newExifOffset = 8 + serializedIFDLength(ifd0Entries)
    let newGPSOffset = newExifOffset + serializedIFDLength(exifEntries)
    var ifd0Overrides: [UInt16: UInt32] = [0x8769: UInt32(newExifOffset)]
    if gpsEntries != nil {
        ifd0Overrides[0x8825] = UInt32(newGPSOffset)
    }

    var tiff = Data()
    tiff.append(Data("MM".utf8))
    appendUInt16BE(42, to: &tiff)
    appendUInt32BE(8, to: &tiff)
    tiff.append(serializeIFD(ifd0Entries, ifdOffset: 8, overrides: ifd0Overrides))
    tiff.append(serializeIFD(exifEntries, ifdOffset: newExifOffset))
    if let gpsEntries {
        tiff.append(serializeIFD(gpsEntries, ifdOffset: newGPSOffset))
    }

    var payload = Data("Exif\0\0".utf8)
    payload.append(tiff)
    guard payload.count + 2 <= UInt16.max else { throw ToolError.noAssetID }
    var segment = Data([0xff, 0xe1])
    appendUInt16BE(UInt16(payload.count + 2), to: &segment)
    segment.append(payload)
    return segment
}

func writeJPEGWithAssetID(sourceURL: URL, outputURL: URL, assetID: String) throws {
    let source = try Data(contentsOf: sourceURL)
    guard source.count > 4, source[0] == 0xff, source[1] == 0xd8 else {
        throw ToolError.noAssetID
    }

    let dimensions = jpegDimensions(source)
    let fallbackSegment = try makeLivePhotoExifSegment(width: dimensions.width, height: dimensions.height, assetID: assetID)

    var offset = 2
    while offset + 4 < source.count, source[offset] == 0xff {
        let marker = source[offset + 1]
        if marker == 0xda { break }
        let length = Int(readUInt16BE(source, offset + 2))
        let start = offset + 4
        let end = offset + 2 + length
        guard length >= 2, end <= source.count else { throw ToolError.noAssetID }
        if marker == 0xe1,
           end <= source.count,
           source[start..<min(start + 6, end)] == Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) {
            let segmentPayload = Data(source[start..<end])
            let segment = (try? makePreservingLivePhotoExifSegment(from: segmentPayload, assetID: assetID)) ?? fallbackSegment
            var output = Data()
            output.append(source[0..<offset])
            output.append(segment)
            output.append(source[end..<source.count])
            try output.write(to: outputURL)
            return
        }
        offset = end
    }

    var output = Data()
    output.append(source[0..<2])
    output.append(fallbackSegment)
    output.append(source[2..<source.count])
    try output.write(to: outputURL)
}

func heicImageDimensions(_ url: URL) -> (width: UInt32, height: UInt32) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return (0, 0)
    }
    let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint32Value ?? 0
    let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint32Value ?? 0
    return (width, height)
}

func writeHEICWithAssetID(sourceURL: URL, outputURL: URL, assetID: String) throws {
    var source = try Data(contentsOf: sourceURL)
    let location = try heicExifItemLocation(in: source)
    let originalExifItem = Data(source[location.itemRange])
    guard originalExifItem.count >= 4 else { throw ToolError.noAssetID }
    let tiffOffset = Int(readUInt32BE(originalExifItem, 0))
    guard tiffOffset <= originalExifItem.count - 4 else { throw ToolError.noAssetID }
    let tiffStart = 4 + tiffOffset

    let existingSegmentPayload = Data("Exif\0\0".utf8) + Data(originalExifItem.dropFirst(tiffStart))
    let segment: Data
    if let preservingSegment = try? makePreservingLivePhotoExifSegment(from: existingSegmentPayload, assetID: assetID) {
        segment = preservingSegment
    } else {
        let dimensions = heicImageDimensions(sourceURL)
        segment = try makeLivePhotoExifSegment(width: dimensions.width, height: dimensions.height, assetID: assetID)
    }

    let segmentPayload = Data(segment.dropFirst(4))
    guard segmentPayload.count > 6 else { throw ToolError.noAssetID }
    let newExifItem = Data(originalExifItem.prefix(tiffStart)) + Data(segmentPayload.dropFirst(6))
    let newItemStart = source.count + 8
    let newItemLength = newExifItem.count

    guard integerFits(newItemLength, byteCount: location.extentLengthRange.count) else {
        throw ToolError.noAssetID
    }

    if let constructionMethodRange = location.constructionMethodRange {
        let original = readIntegerBE(source, range: constructionMethodRange)
        writeIntegerBE(original & 0xf000, range: constructionMethodRange, in: &source)
    }

    if location.extentOffsetRange.count > 0,
       integerFits(newItemStart, byteCount: location.extentOffsetRange.count),
       integerFits(0, byteCount: location.baseOffsetRange.count) {
        writeIntegerBE(0, range: location.baseOffsetRange, in: &source)
        writeIntegerBE(newItemStart, range: location.extentOffsetRange, in: &source)
    } else if location.baseOffsetRange.count > 0,
              integerFits(newItemStart, byteCount: location.baseOffsetRange.count),
              integerFits(0, byteCount: location.extentOffsetRange.count) {
        writeIntegerBE(newItemStart, range: location.baseOffsetRange, in: &source)
        writeIntegerBE(0, range: location.extentOffsetRange, in: &source)
    } else {
        throw ToolError.noAssetID
    }

    writeIntegerBE(newItemLength, range: location.extentLengthRange, in: &source)
    appendUInt32BE(UInt32(newExifItem.count + 8), to: &source)
    source.append(Data("mdat".utf8))
    source.append(newExifItem)
    try source.write(to: outputURL)

    let writtenAssetID = try extractAssetIDFromTIFF(extractHEICExifData(from: outputURL))
    guard writtenAssetID == assetID else {
        throw ToolError.noAssetID
    }
}

func convertImageToJPEGWithAssetID(sourceURL: URL, outputURL: URL, assetID: String) throws {
    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jpg")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    try convertImageToJPEG(sourceURL: sourceURL, outputURL: temporaryURL)

    try writeJPEGWithAssetID(sourceURL: temporaryURL, outputURL: outputURL, assetID: assetID)
}

func writeJPEGWithAssetIDPreservingDisplayOrientation(sourceURL: URL, outputURL: URL, assetID: String) throws {
    if imageOrientation(sourceURL) == 1 {
        try writeJPEGWithAssetID(sourceURL: sourceURL, outputURL: outputURL, assetID: assetID)
    } else {
        try writeOrientationNormalizedJPEGWithAssetID(sourceURL: sourceURL, outputURL: outputURL, assetID: assetID)
    }
}

func imageOrientation(_ url: URL) -> Int {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return 1
    }
    return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
}

func writeOrientationNormalizedJPEGWithAssetID(sourceURL: URL, outputURL: URL, assetID: String) throws {
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        throw ToolError.failed("Could not decode still image.")
    }

    let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    let maxPixelSize = max(width, height, 1)
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
        throw ToolError.failed("Could not normalize still image orientation.")
    }

    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jpg")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    guard let destination = CGImageDestinationCreateWithURL(
        temporaryURL as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        throw ToolError.failed("Could not create JPEG destination.")
    }

    var outputProperties = properties
    outputProperties[kCGImagePropertyOrientation] = 1
    if var tiff = outputProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
        tiff[kCGImagePropertyTIFFOrientation] = 1
        outputProperties[kCGImagePropertyTIFFDictionary] = tiff
    }
    outputProperties[kCGImageDestinationLossyCompressionQuality] = 1.0
    CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw ToolError.failed("Could not write orientation-normalized JPEG image.")
    }

    try writeJPEGWithAssetID(sourceURL: temporaryURL, outputURL: outputURL, assetID: assetID)
}

func convertImageToJPEG(sourceURL: URL, outputURL: URL) throws {
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        throw ToolError.failed("Could not decode still image.")
    }

    let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    let maxPixelSize = max(width, height, 1)
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
        throw ToolError.failed("Could not normalize still image orientation.")
    }

    let destinationOptions: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 1.0
    ]
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        throw ToolError.failed("Could not create JPEG destination.")
    }

    var outputProperties = properties
    outputProperties[kCGImagePropertyOrientation] = 1
    if var tiff = outputProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
        tiff[kCGImagePropertyTIFFOrientation] = 1
        outputProperties[kCGImagePropertyTIFFDictionary] = tiff
    }
    outputProperties[kCGImageDestinationLossyCompressionQuality] = destinationOptions[kCGImageDestinationLossyCompressionQuality]
    CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw ToolError.failed("Could not write JPEG image.")
    }
}

func fileContainsAnyASCII(_ values: [String], in url: URL, chunkSize: Int = 1_048_576) -> Bool {
    let needles = values.map { Data($0.utf8) }.filter { !$0.isEmpty }
    guard !needles.isEmpty,
          let handle = try? FileHandle(forReadingFrom: url) else {
        return false
    }
    defer { try? handle.close() }

    let overlapCount = max((needles.map(\.count).max() ?? 1) - 1, 0)
    var tail = Data()
    while true {
        let chunk = handle.readData(ofLength: chunkSize)
        if chunk.isEmpty { return false }

        var buffer = tail
        buffer.append(chunk)
        if needles.contains(where: { buffer.range(of: $0) != nil }) {
            return true
        }
        tail = overlapCount > 0 ? Data(buffer.suffix(overlapCount)) : Data()
    }
}

func fileContainsAllASCII(_ values: [String], in url: URL, chunkSize: Int = 1_048_576) -> Bool {
    let needles = values.map { Data($0.utf8) }.filter { !$0.isEmpty }
    guard !needles.isEmpty,
          let handle = try? FileHandle(forReadingFrom: url) else {
        return false
    }
    defer { try? handle.close() }

    let overlapCount = max((needles.map(\.count).max() ?? 1) - 1, 0)
    var found = Array(repeating: false, count: needles.count)
    var tail = Data()
    while true {
        let chunk = handle.readData(ofLength: chunkSize)
        if chunk.isEmpty { return found.allSatisfy { $0 } }

        var buffer = tail
        buffer.append(chunk)
        for (index, needle) in needles.enumerated() where !found[index] {
            if buffer.range(of: needle) != nil {
                found[index] = true
            }
        }
        if found.allSatisfy({ $0 }) {
            return true
        }
        tail = overlapCount > 0 ? Data(buffer.suffix(overlapCount)) : Data()
    }
}

func movieNeedsAppleCompatibilityPass(_ movieURL: URL) -> Bool {
    fileContainsAnyASCII(["Lavf", "Lavc", "hev1"], in: movieURL)
}

func makeAppleCompatibleMovieIfNeeded(_ movieURL: URL) async throws -> URL? {
    guard movieNeedsAppleCompatibilityPass(movieURL) else { return nil }

    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mov")

    let asset = AVURLAsset(url: movieURL)
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        throw ToolError.failed("Could not create Apple-compatible movie exporter.")
    }
    exportSession.shouldOptimizeForNetworkUse = false

    do {
        try await exportSession.export(to: outputURL, as: .mov)
    } catch {
        try? FileManager.default.removeItem(at: outputURL)
        throw ToolError.failed(error.localizedDescription)
    }

    return outputURL
}

func rewriteHEVCSampleEntryForAppleCompatibility(_ movieURL: URL) throws {
    var data = try Data(contentsOf: movieURL)
    let roots = try isoBoxes(in: data, range: data.startIndex..<data.endIndex)
    var typeRanges: [Range<Int>] = []
    for movie in roots where movie.isType("moov") {
        for track in try isoBoxes(in: data, range: movie.payload) where track.isType("trak") {
            guard let media = try isoBoxes(in: data, range: track.payload).first(where: { $0.isType("mdia") }) else { continue }
            let children = try isoBoxes(in: data, range: media.payload)
            guard let handler = children.first(where: { $0.isType("hdlr") }), handler.payload.count >= 12,
                  readUInt32BE(data, handler.payload.lowerBound + 8) == fourCC("vide"),
                  let info = children.first(where: { $0.isType("minf") }),
                  let table = try isoBoxes(in: data, range: info.payload).first(where: { $0.isType("stbl") }),
                  let descriptions = try isoBoxes(in: data, range: table.payload).first(where: { $0.isType("stsd") }),
                  descriptions.payload.count >= 8 else { continue }
            let entries = try isoBoxes(in: data, range: descriptions.payload.lowerBound + 8..<descriptions.payload.upperBound)
            guard Int(readUInt32BE(data, descriptions.payload.lowerBound + 4)) == entries.count else { throw ToolError.noAssetID }
            for entry in entries where entry.isType("hev1") {
                guard entry.payload.count >= 78,
                      try isoBoxes(in: data, range: entry.payload.lowerBound + 78..<entry.payload.upperBound)
                        .contains(where: { $0.isType("hvcC") }) else { throw ToolError.noAssetID }
                typeRanges.append(entry.typeRange)
            }
        }
    }
    for range in typeRanges { data.replaceSubrange(range, with: Data("hvc1".utf8)) }
    if !typeRanges.isEmpty { try data.write(to: movieURL, options: .atomic) }
}

func metadataItem(identifier: AVMetadataIdentifier, value: any NSCopying & NSObjectProtocol, dataType: String) -> AVMutableMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value
    item.dataType = dataType
    return item
}

func preservedMovieMetadata(from asset: AVAsset) async throws -> [AVMetadataItem] {
    var metadata: [AVMetadataItem] = []
    let metadataFormats = try await asset.load(.availableMetadataFormats)
    for format in metadataFormats {
        metadata.append(contentsOf: try await asset.loadMetadata(for: format))
    }

    return metadata.filter { $0.identifier != .quickTimeMetadataContentIdentifier }
}

func makeMovie(sourceURL: URL, outputURL: URL, assetID: String) async throws {
    try? FileManager.default.removeItem(at: outputURL)

    let asset = AVURLAsset(url: sourceURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let videoTrack = tracks.first else { throw ToolError.noVideoTrack }

    let reader = try AVAssetReader(asset: asset)
    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    guard reader.canAdd(videoOutput) else { throw ToolError.cannotAddReaderOutput }
    let videoProvider = reader.outputProvider(for: videoOutput)

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    let formatHint = try await videoTrack.load(.formatDescriptions).first
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
    videoInput.transform = try await videoTrack.load(.preferredTransform)
    guard writer.canAdd(videoInput) else { throw ToolError.cannotAddWriterInput }
    let videoReceiver = writer.inputReceiver(for: videoInput)

    var mediaPipes = [
        MediaPipe(provider: videoProvider, receiver: videoReceiver)
    ]

    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    for audioTrack in audioTracks {
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        guard reader.canAdd(audioOutput) else { throw ToolError.cannotAddReaderOutput }
        let audioProvider = reader.outputProvider(for: audioOutput)

        let audioFormatHint = try await audioTrack.load(.formatDescriptions).first
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormatHint)
        guard writer.canAdd(audioInput) else { throw ToolError.cannotAddWriterInput }
        let audioReceiver = writer.inputReceiver(for: audioInput)
        mediaPipes.append(MediaPipe(provider: audioProvider, receiver: audioReceiver))
    }

    var movieMetadata = try await preservedMovieMetadata(from: asset)
    movieMetadata.append(metadataItem(
        identifier: .quickTimeMetadataContentIdentifier,
        value: assetID as NSString,
        dataType: kCMMetadataBaseDataType_UTF8 as String
    ))
    writer.metadata = movieMetadata

    let metadataSpec: [String: Any] = [
        kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
        kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String
    ]
    var metadataDescription: CMMetadataFormatDescription?
    let metadataStatus = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: [metadataSpec] as CFArray,
        formatDescriptionOut: &metadataDescription
    )
    guard metadataStatus == noErr, let metadataDescription else {
        throw ToolError.failed("Could not create timed metadata description.")
    }

    let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: metadataDescription)
    guard writer.canAdd(metadataInput) else { throw ToolError.cannotAddWriterInput }
    let metadataReceiver = writer.inputMetadataReceiver(for: metadataInput)

    try reader.start()
    try writer.start()
    writer.startSession(atSourceTime: .zero)

    let stillImageTime = metadataItem(
        identifier: AVMetadataIdentifier("mdta/com.apple.quicktime.still-image-time"),
        value: NSNumber(value: 0 as Int8),
        dataType: kCMMetadataBaseDataType_SInt8 as String
    )
    try await metadataReceiver.append(
        AVTimedMetadataGroup(
            items: [stillImageTime],
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 100))
        )
    )
    metadataReceiver.finish()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for pipe in mediaPipes {
            group.addTask {
                while let sample = try await pipe.provider.next() {
                    try await pipe.receiver.append(sample)
                }
                pipe.receiver.finish()
            }
        }
        try await group.waitForAll()
    }

    await withCheckedContinuation { continuation in
        writer.finishWriting {
            continuation.resume()
        }
    }

    if reader.status == .failed { throw ToolError.failed(reader.error?.localizedDescription ?? "Reader failed.") }
    if writer.status == .failed { throw ToolError.failed(writer.error?.localizedDescription ?? "Writer failed.") }
}

func makeLivePhotoMovie(sourceURL: URL, outputURL: URL, assetID: String) async throws {
    if try await copyMovieReplacingAssetIDIfPossible(sourceURL: sourceURL, outputURL: outputURL, assetID: assetID) {
        return
    }

    do {
        try await makeMovie(sourceURL: sourceURL, outputURL: outputURL, assetID: assetID)
        try rewriteHEVCSampleEntryForAppleCompatibility(outputURL)
    } catch {
        try? FileManager.default.removeItem(at: outputURL)
        guard let compatibleMovieURL = try await makeAppleCompatibleMovieIfNeeded(sourceURL) else {
            throw error
        }
        defer { try? FileManager.default.removeItem(at: compatibleMovieURL) }
        if try await copyMovieReplacingAssetIDIfPossible(sourceURL: compatibleMovieURL, outputURL: outputURL, assetID: assetID) {
            return
        }
        try await makeMovie(sourceURL: compatibleMovieURL, outputURL: outputURL, assetID: assetID)
        try rewriteHEVCSampleEntryForAppleCompatibility(outputURL)
    }
}

func detectStillImageExtension(_ url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url),
          let data = try? handle.read(upToCount: 12) else {
        return "jpeg"
    }
    try? handle.close()

    if data.count >= 12 {
        if data.starts(with: Data([0x52, 0x49, 0x46, 0x46])) { return "webp" }
        if data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) { return "png" }
        if data.prefix(4) == Data("ftyp".utf8) {
            let subtype = String(data: data.subdata(in: 8..<12), encoding: .ascii) ?? ""
            if subtype.lowercased().hasPrefix("heic") { return "heic" }
            if subtype.lowercased().hasPrefix("heif") { return "heif" }
            if subtype.lowercased().hasPrefix("mif1") { return "heic" }
            if subtype.lowercased().hasPrefix("msf1") { return "heif" }
        }
    }
    if data.count >= 2 {
        if data[0] == 0xFF, data[1] == 0xD8 { return "jpeg" }
    }
    return "jpeg"
}


/// Serialize publication across helper processes. Existing files are never replaced.
func publishLivePhoto(still: URL, movie: URL, to folder: URL, baseName: String) throws -> (URL, URL) {
    let fm = FileManager.default
    let lockPath = folder.appendingPathComponent(".hermes-publish.lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw POSIXError(.EACCES) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
    defer { flock(fd, LOCK_UN) }
    let names = try fm.contentsOfDirectory(atPath: folder.path)
    let occupied = Set(names.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() })
    var stem = baseName
    var number = 2
    while occupied.contains(stem.lowercased()) {
        stem = "\(baseName) (\(number))"
        number += 1
    }
    let imageURL = folder.appendingPathComponent(stem).appendingPathExtension(still.pathExtension)
    let movieURL = folder.appendingPathComponent(stem).appendingPathExtension("mov")
    // Publish the photo last: directory scans cannot see a completed photo before its movie.
    try fm.moveItem(at: movie, to: movieURL)
    do {
        try fm.moveItem(at: still, to: imageURL)
    } catch {
        try? fm.moveItem(at: movieURL, to: movie)
        throw error
    }
    return (imageURL, movieURL)
}

@main
struct Main {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 3 else { throw ToolError.usage }

            let jpegURL = URL(fileURLWithPath: args[0])
            let videoURL = URL(fileURLWithPath: args[1])
            let destinationFolder = URL(fileURLWithPath: args[2]).standardizedFileURL
            guard FileManager.default.isReadableFile(atPath: jpegURL.path),
                  FileManager.default.isReadableFile(atPath: videoURL.path) else {
                throw NSError(domain: "HERMES.Tool", code: 1, userInfo: [NSLocalizedDescriptionKey: "照片或视频不存在或不可读取。"])
            }
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            let outputFolder = destinationFolder.appendingPathComponent(".hermes-stage-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: outputFolder) }
            let assetIDIndex = args.firstIndex(of: "--asset-id")
            let providedAssetID = assetIDIndex.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }

            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let baseName = jpegURL.deletingPathExtension().lastPathComponent
            let stillExtension = jpegURL.pathExtension.isEmpty
                ? detectStillImageExtension(jpegURL)
                : jpegURL.pathExtension
            var outputJPEG = outputFolder.appendingPathComponent(baseName).appendingPathExtension(stillExtension)
            let outputMOV = outputFolder.appendingPathComponent(baseName).appendingPathExtension("mov")
            let assetID: String
            var stillHasAssetID = false
            if let providedAssetID {
                assetID = providedAssetID
            } else if stillExtension.lowercased() == "heic" || stillExtension.lowercased() == "heif" {
                do {
                    assetID = try extractAssetIDFromTIFF(extractHEICExifData(from: jpegURL))
                    stillHasAssetID = true
                } catch {
                    assetID = (try? await extractAssetIDFromMovie(videoURL)) ?? UUID().uuidString.uppercased()
                }
            } else {
                do {
                    assetID = try extractAssetID(from: jpegURL)
                    stillHasAssetID = true
                } catch {
                    assetID = (try? await extractAssetIDFromMovie(videoURL)) ?? UUID().uuidString.uppercased()
                }
            }

            try? FileManager.default.removeItem(at: outputJPEG)
            let lowerExtension = stillExtension.lowercased()
            if lowerExtension == "jpg" || lowerExtension == "jpeg" {
                if stillHasAssetID {
                    if imageOrientation(jpegURL) == 1 {
                        try FileManager.default.copyItem(at: jpegURL, to: outputJPEG)
                    } else {
                        try writeOrientationNormalizedJPEGWithAssetID(sourceURL: jpegURL, outputURL: outputJPEG, assetID: assetID)
                    }
                } else {
                    let actualExtension = detectStillImageExtension(jpegURL)
                    if actualExtension == "webp" || actualExtension == "png" {
                        outputJPEG = outputFolder.appendingPathComponent(baseName).appendingPathExtension("jpg")
                        try? FileManager.default.removeItem(at: outputJPEG)
                        try convertImageToJPEGWithAssetID(sourceURL: jpegURL, outputURL: outputJPEG, assetID: assetID)
                    } else {
                        do {
                            try writeJPEGWithAssetIDPreservingDisplayOrientation(
                                sourceURL: jpegURL,
                                outputURL: outputJPEG,
                                assetID: assetID
                            )
                        } catch {
                            outputJPEG = outputFolder.appendingPathComponent(baseName).appendingPathExtension("jpg")
                            try? FileManager.default.removeItem(at: outputJPEG)
                            try convertImageToJPEGWithAssetID(sourceURL: jpegURL, outputURL: outputJPEG, assetID: assetID)
                        }
                    }
                }
            } else if lowerExtension == "heic" || lowerExtension == "heif" {
                if stillHasAssetID {
                    if imageOrientation(jpegURL) == 1 {
                        try FileManager.default.copyItem(at: jpegURL, to: outputJPEG)
                    } else {
                        outputJPEG = outputFolder.appendingPathComponent(baseName).appendingPathExtension("jpg")
                        try? FileManager.default.removeItem(at: outputJPEG)
                        try convertImageToJPEGWithAssetID(sourceURL: jpegURL, outputURL: outputJPEG, assetID: assetID)
                    }
                } else {
                    do {
                        try writeHEICWithAssetID(sourceURL: jpegURL, outputURL: outputJPEG, assetID: assetID)
                    } catch {
                        outputJPEG = outputFolder.appendingPathComponent(baseName).appendingPathExtension("jpg")
                        try? FileManager.default.removeItem(at: outputJPEG)
                        try convertImageToJPEGWithAssetID(sourceURL: jpegURL, outputURL: outputJPEG, assetID: assetID)
                    }
                }
            } else if lowerExtension == "webp" || lowerExtension == "png" {
                outputJPEG = outputFolder.appendingPathComponent(baseName).appendingPathExtension("jpg")
                try? FileManager.default.removeItem(at: outputJPEG)
                try convertImageToJPEGWithAssetID(sourceURL: jpegURL, outputURL: outputJPEG, assetID: assetID)
            } else {
                let actualExtension = detectStillImageExtension(jpegURL)
                if actualExtension == "webp" || actualExtension == "png" {
                    outputJPEG = outputFolder.appendingPathComponent(baseName).appendingPathExtension("jpg")
                    try? FileManager.default.removeItem(at: outputJPEG)
                    try convertImageToJPEGWithAssetID(sourceURL: jpegURL, outputURL: outputJPEG, assetID: assetID)
                } else if actualExtension == "heic" || actualExtension == "heif" {
                    try convertImageToJPEGWithAssetID(sourceURL: jpegURL, outputURL: outputJPEG, assetID: assetID)
                } else if actualExtension == "jpeg" {
                    do {
                        try writeJPEGWithAssetIDPreservingDisplayOrientation(
                            sourceURL: jpegURL,
                            outputURL: outputJPEG,
                            assetID: assetID
                        )
                    } catch {
                        outputJPEG = outputFolder.appendingPathComponent(baseName).appendingPathExtension("jpg")
                        try? FileManager.default.removeItem(at: outputJPEG)
                        try convertImageToJPEGWithAssetID(sourceURL: jpegURL, outputURL: outputJPEG, assetID: assetID)
                    }
                } else {
                    try FileManager.default.copyItem(at: jpegURL, to: outputJPEG)
                }
            }
            try await makeLivePhotoMovie(sourceURL: videoURL, outputURL: outputMOV, assetID: assetID)
            let completedDate = Date()
            try? FileManager.default.setAttributes([.modificationDate: completedDate], ofItemAtPath: outputJPEG.path)
            try? FileManager.default.setAttributes([.modificationDate: completedDate], ofItemAtPath: outputMOV.path)

            guard CGImageSourceCreateWithURL(outputJPEG as CFURL, nil) != nil,
                  try await extractAssetIDFromMovie(outputMOV) == assetID else {
                throw NSError(domain: "HERMES.Tool", code: 2, userInfo: [NSLocalizedDescriptionKey: "合成结果验证失败，未发布文件。"])
            }
            let published = try publishLivePhoto(still: outputJPEG, movie: outputMOV, to: destinationFolder, baseName: baseName)
            let result = try JSONSerialization.data(withJSONObject: ["imagePath": published.0.path, "moviePath": published.1.path], options: [.sortedKeys])
            print("Asset ID: \(assetID)")
            print("HERMES_RESULT:" + String(decoding: result, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
