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
    while offset + 4 < data.count {
        guard data[offset] == 0xff else { break }
        let marker = data[offset + 1]
        if marker == 0xda { break }
        let segmentLength = Int(readUInt16BE(data, offset + 2))
        let segmentStart = offset + 4
        let segmentEnd = offset + 2 + segmentLength
        if marker == 0xe1,
           segmentEnd <= data.count,
           segmentLength >= 14,
           data[segmentStart..<segmentStart + 6] == Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) {
            let tiffStart = segmentStart + 6
            guard data[tiffStart] == 0x4d, data[tiffStart + 1] == 0x4d else { throw ToolError.noAssetID }
            let ifd0Offset = Int(readUInt32BE(data, tiffStart + 4))
            let ifd0Start = tiffStart + ifd0Offset
            let ifd0Count = Int(readUInt16BE(data, ifd0Start))
            var exifOffset: Int?

            for index in 0..<ifd0Count {
                let entry = ifd0Start + 2 + index * 12
                let tag = readUInt16BE(data, entry)
                if tag == 0x8769 {
                    exifOffset = Int(readUInt32BE(data, entry + 8))
                    break
                }
            }

            guard let exifOffset else { throw ToolError.noAssetID }
            let exifStart = tiffStart + exifOffset
            let exifCount = Int(readUInt16BE(data, exifStart))
            var makerOffset: Int?
            var makerCount: Int?

            for index in 0..<exifCount {
                let entry = exifStart + 2 + index * 12
                let tag = readUInt16BE(data, entry)
                if tag == 0x927c {
                    makerCount = Int(readUInt32BE(data, entry + 4))
                    makerOffset = Int(readUInt32BE(data, entry + 8))
                    break
                }
            }

            guard let makerOffset, let makerCount else { throw ToolError.noAssetID }
            let makerStart = tiffStart + makerOffset
            guard makerStart + makerCount <= data.count,
                  makerCount > 20,
                  String(data: data[makerStart..<makerStart + 9], encoding: .ascii) == "Apple iOS" else {
                throw ToolError.noAssetID
            }

            let makerIfdStart = makerStart + 14
            let makerEntryCount = Int(readUInt16BE(data, makerIfdStart))
            for index in 0..<makerEntryCount {
                let entry = makerIfdStart + 2 + index * 12
                let tag = readUInt16BE(data, entry)
                let type = readUInt16BE(data, entry + 2)
                let count = Int(readUInt32BE(data, entry + 4))
                let value = Int(readUInt32BE(data, entry + 8))
                if tag == 17, type == 2, count > 1 {
                    let byteCount = count * tiffTypeSize(type)
                    let valueStart = byteCount <= 4 ? entry + 8 : makerStart + value
                    let valueEnd = min(valueStart + count, data.count)
                    let raw = data[valueStart..<valueEnd].filter { $0 != 0 }
                    if let id = String(data: Data(raw), encoding: .utf8), !id.isEmpty {
                        return id
                    }
                }
            }
        }
        offset = segmentEnd
    }

    throw ToolError.noAssetID
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
    guard data.count > 12 else { throw ToolError.noAssetID }

    func readUInt32(_ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    func type(_ offset: Int) -> String {
        String(data: data[offset + 4..<offset + 8], encoding: .isoLatin1) ?? ""
    }

    var metaOffset: Int?
    var metaSize: Int?
    var offset = 0
    while offset + 8 <= data.count {
        let size = Int(readUInt32(offset))
        if type(offset) == "meta" {
            metaOffset = offset
            metaSize = size
            break
        }
        guard size >= 8 else { break }
        offset += size
    }

    guard let metaOffset, let metaSize else { throw ToolError.noAssetID }
    let metaEnd = metaOffset + metaSize
    var exifItemID: Int?
    var itemLocations: [Int: HEICExifItemLocation] = [:]

    var childOffset = metaOffset + 12
    while childOffset + 8 <= metaEnd {
        let size = Int(readUInt32(childOffset))
        let boxType = type(childOffset)
        let content = childOffset + 12

        if boxType == "iinf" {
            let version = data[childOffset + 8]
            var cursor = content
            let count: Int
            if version == 0 {
                count = Int(readUInt16BE(data, cursor))
                cursor += 2
            } else {
                count = Int(readUInt32(cursor))
                cursor += 4
            }
            for _ in 0..<count {
                let entryOffset = cursor
                let entrySize = Int(readUInt32(entryOffset))
                if type(entryOffset) == "infe" {
                    let entryVersion = data[entryOffset + 8]
                    var entryCursor = entryOffset + 12
                    if entryVersion >= 2 {
                        let itemID: Int
                        if entryVersion == 2 {
                            itemID = Int(readUInt16BE(data, entryCursor))
                            entryCursor += 2
                        } else {
                            itemID = Int(readUInt32(entryCursor))
                            entryCursor += 4
                        }
                        entryCursor += 2
                        let itemType = String(data: data[entryCursor..<entryCursor + 4], encoding: .isoLatin1) ?? ""
                        if itemType == "Exif" {
                            exifItemID = itemID
                        }
                    }
                }
                cursor += entrySize
            }
        } else if boxType == "iloc" {
            let version = data[childOffset + 8]
            var cursor = content
            let sizes1 = data[cursor]
            cursor += 1
            let offsetSize = Int(sizes1 >> 4)
            let lengthSize = Int(sizes1 & 0x0f)
            let sizes2 = data[cursor]
            cursor += 1
            let baseOffsetSize = Int(sizes2 >> 4)
            let indexSize = (version == 1 || version == 2) ? Int(sizes2 & 0x0f) : 0
            let itemCount: Int
            if version < 2 {
                itemCount = Int(readUInt16BE(data, cursor))
                cursor += 2
            } else {
                itemCount = Int(readUInt32(cursor))
                cursor += 4
            }

            func readN(_ byteCount: Int, cursor: inout Int) -> Int {
                let start = cursor
                cursor += byteCount
                return byteCount == 0 ? 0 : readIntegerBE(data, range: start..<cursor)
            }

            for _ in 0..<itemCount {
                let itemID: Int
                if version < 2 {
                    itemID = Int(readUInt16BE(data, cursor))
                    cursor += 2
                } else {
                    itemID = Int(readUInt32(cursor))
                    cursor += 4
                }
                var constructionMethodRange: Range<Int>?
                if version == 1 || version == 2 {
                    constructionMethodRange = cursor..<cursor + 2
                    cursor += 2
                }
                cursor += 2

                let baseOffsetStart = cursor
                let base = readN(baseOffsetSize, cursor: &cursor)
                let baseOffsetRange = baseOffsetStart..<cursor
                let extentCount = Int(readUInt16BE(data, cursor))
                cursor += 2
                for extentIndex in 0..<extentCount {
                    if indexSize > 0 {
                        _ = readN(indexSize, cursor: &cursor)
                    }
                    let extentOffsetStart = cursor
                    let extentOffset = readN(offsetSize, cursor: &cursor)
                    let extentOffsetRange = extentOffsetStart..<cursor
                    let extentLengthStart = cursor
                    let extentLength = readN(lengthSize, cursor: &cursor)
                    let extentLengthRange = extentLengthStart..<cursor
                    if extentIndex == 0 {
                        let itemStart = base + extentOffset
                        let itemEnd = itemStart + extentLength
                        guard itemStart >= 0, itemEnd <= data.count else { throw ToolError.noAssetID }
                        itemLocations[itemID] = HEICExifItemLocation(
                            itemRange: itemStart..<itemEnd,
                            constructionMethodRange: constructionMethodRange,
                            baseOffsetRange: baseOffsetRange,
                            extentOffsetRange: extentOffsetRange,
                            extentLengthRange: extentLengthRange
                        )
                    }
                }
            }
        }

        guard size >= 8 else { break }
        childOffset += size
    }

    guard let exifItemID, let exifLocation = itemLocations[exifItemID] else { throw ToolError.noAssetID }
    return exifLocation
}

func extractHEICExifData(from heicURL: URL) throws -> Data {
    let data = try Data(contentsOf: heicURL)
    let location = try heicExifItemLocation(in: data)
    let exifItem = data[location.itemRange]
    guard exifItem.count > 10 else { throw ToolError.noAssetID }
    return Data(exifItem.dropFirst(10))
}

func extractAssetIDFromTIFF(_ data: Data) throws -> String {
    guard data.count > 16, data[0] == 0x4d, data[1] == 0x4d else { throw ToolError.noAssetID }

    func read16(_ offset: Int) -> UInt16 { readUInt16BE(data, offset) }
    func read32(_ offset: Int) -> UInt32 { readUInt32BE(data, offset) }

    let ifd0Offset = Int(read32(4))
    let ifd0Count = Int(read16(ifd0Offset))
    var exifOffset: Int?
    for index in 0..<ifd0Count {
        let entry = ifd0Offset + 2 + index * 12
        if read16(entry) == 0x8769 {
            exifOffset = Int(read32(entry + 8))
            break
        }
    }
    guard let exifOffset else { throw ToolError.noAssetID }

    let exifCount = Int(read16(exifOffset))
    var makerOffset: Int?
    var makerCount: Int?
    for index in 0..<exifCount {
        let entry = exifOffset + 2 + index * 12
        if read16(entry) == 0x927c {
            makerCount = Int(read32(entry + 4))
            makerOffset = Int(read32(entry + 8))
            break
        }
    }

    guard let makerOffset, let makerCount, makerOffset + makerCount <= data.count else {
        throw ToolError.noAssetID
    }
    let maker = data[makerOffset..<makerOffset + makerCount]
    guard maker.count > 32,
          String(data: maker[maker.startIndex..<maker.startIndex + 9], encoding: .ascii) == "Apple iOS" else {
        throw ToolError.noAssetID
    }

    let base = maker.startIndex
    let makerCountEntries = Int(readUInt16BE(maker, base + 14))
    for index in 0..<makerCountEntries {
        let entry = base + 16 + index * 12
        let tag = readUInt16BE(maker, entry)
        let type = readUInt16BE(maker, entry + 2)
        let count = Int(readUInt32BE(maker, entry + 4))
        let value = Int(readUInt32BE(maker, entry + 8))
        if tag == 17, type == 2, count > 1 {
            let valueStart = count <= 4 ? entry + 8 : base + value
            let valueEnd = min(valueStart + count, maker.endIndex)
            let raw = maker[valueStart..<valueEnd].filter { $0 != 0 }
            if let id = String(data: Data(raw), encoding: .utf8), !id.isEmpty {
                return id
            }
        }
    }

    throw ToolError.noAssetID
}

func extractAssetIDFromMovie(_ movieURL: URL) throws -> String {
    let data = try Data(contentsOf: movieURL)
    guard let text = String(data: data, encoding: .isoLatin1) else {
        throw ToolError.noAssetID
    }

    return try extractAssetID(fromMovieText: text)
}

func extractAssetID(fromMovieText text: String) throws -> String {
    guard text.contains("com.apple.quicktime.content.identifier") else {
        throw ToolError.noAssetID
    }

    let pattern = #"[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}"#
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let uuidRange = Range(match.range, in: text) else {
        throw ToolError.noAssetID
    }
    return String(text[uuidRange])
}

func copyMovieReplacingAssetIDIfPossible(sourceURL: URL, outputURL: URL, assetID: String) throws -> Bool {
    guard fileContainsAllASCII([
        "com.apple.quicktime.content.identifier",
        "com.apple.quicktime.still-image-time"
    ], in: sourceURL) else {
        return false
    }

    var data = try Data(contentsOf: sourceURL)
    guard let text = String(data: data, encoding: .isoLatin1) else {
        return false
    }

    let existingAssetID = try extractAssetID(fromMovieText: text)
    guard existingAssetID.utf8.count == assetID.utf8.count else { return false }

    let existingData = Data(existingAssetID.utf8)
    let replacementData = Data(assetID.utf8)
    var searchStart = data.startIndex
    var replacementCount = 0
    while searchStart < data.endIndex,
          let range = data[searchStart...].range(of: existingData) {
        data.replaceSubrange(range, with: replacementData)
        searchStart = range.upperBound
        replacementCount += 1
    }

    guard replacementCount > 0 else { return false }
    try? FileManager.default.removeItem(at: outputURL)
    try data.write(to: outputURL, options: .atomic)

    let writtenAssetID = try extractAssetIDFromMovie(outputURL)
    guard writtenAssetID == assetID else {
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

func makeLivePhotoExifSegment(width: UInt32, height: UInt32, assetID: String) -> Data {
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
    guard offset + 2 <= tiff.count else { throw ToolError.noAssetID }
    let count = Int(readUInt16BE(tiff, offset))
    let entriesStart = offset + 2
    let nextOffsetPosition = entriesStart + count * 12
    guard nextOffsetPosition + 4 <= tiff.count else { throw ToolError.noAssetID }

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
            guard dataOffset >= 0, dataOffset + byteCount <= tiff.count else { throw ToolError.noAssetID }
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
    let fallbackSegment = makeLivePhotoExifSegment(width: dimensions.width, height: dimensions.height, assetID: assetID)

    var offset = 2
    while offset + 4 < source.count, source[offset] == 0xff {
        let marker = source[offset + 1]
        if marker == 0xda { break }
        let length = Int(readUInt16BE(source, offset + 2))
        let start = offset + 4
        let end = offset + 2 + length
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
    guard originalExifItem.count > 10 else { throw ToolError.noAssetID }

    let existingSegmentPayload = Data("Exif\0\0".utf8) + Data(originalExifItem.dropFirst(10))
    let segment: Data
    if let preservingSegment = try? makePreservingLivePhotoExifSegment(from: existingSegmentPayload, assetID: assetID) {
        segment = preservingSegment
    } else {
        let dimensions = heicImageDimensions(sourceURL)
        segment = makeLivePhotoExifSegment(width: dimensions.width, height: dimensions.height, assetID: assetID)
    }

    let segmentPayload = Data(segment.dropFirst(4))
    guard segmentPayload.count > 6 else { throw ToolError.noAssetID }
    let newExifItem = Data(originalExifItem.prefix(10)) + Data(segmentPayload.dropFirst(6))
    let newItemStart = source.count
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
    let sourceFourCC = Data("hev1".utf8)
    let destinationFourCC = Data("hvc1".utf8)
    var searchStart = data.startIndex
    var didRewrite = false

    while searchStart < data.endIndex,
          let range = data[searchStart...].range(of: sourceFourCC) {
        data.replaceSubrange(range, with: destinationFourCC)
        searchStart = range.upperBound
        didRewrite = true
    }

    if didRewrite {
        try data.write(to: movieURL, options: .atomic)
    }
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
    if try copyMovieReplacingAssetIDIfPossible(sourceURL: sourceURL, outputURL: outputURL, assetID: assetID) {
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
        if try copyMovieReplacingAssetIDIfPossible(sourceURL: compatibleMovieURL, outputURL: outputURL, assetID: assetID) {
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
                    assetID = (try? extractAssetIDFromMovie(videoURL)) ?? UUID().uuidString.uppercased()
                }
            } else {
                do {
                    assetID = try extractAssetID(from: jpegURL)
                    stillHasAssetID = true
                } catch {
                    assetID = (try? extractAssetIDFromMovie(videoURL)) ?? UUID().uuidString.uppercased()
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
                  try extractAssetIDFromMovie(outputMOV) == assetID else {
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
