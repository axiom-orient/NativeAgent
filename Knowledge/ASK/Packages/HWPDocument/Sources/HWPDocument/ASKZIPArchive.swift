import Foundation
import DocumentCore

struct ASKZIPArchive {
    struct Entry: Sendable, Hashable {
        let path: String
        let compressionMethod: UInt16
        let generalPurposeBitFlag: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32

        var isDirectory: Bool { path.hasSuffix("/") }
        var isEncrypted: Bool { (generalPurposeBitFlag & 0x0001) != 0 }
    }

    private let data: Data
    private let limits: ASKHWPParserLimits
    let entries: [Entry]
    private let entriesByPath: [String: Entry]

    init(data: Data, limits: ASKHWPParserLimits = .default) throws {
        // `Data` slices may retain non-zero indices. Rebase once so every offset
        // below is relative to the archive byte stream rather than its source buffer.
        let data = Data(data)
        self.data = data
        self.limits = limits
        guard !data.isEmpty else { throw ASKHWPError.emptyInput }
        try limits.validateInputSize(data.count)
        let centralDirectory = try Self.findCentralDirectory(in: data)
        self.entries = try Self.readCentralDirectory(data: data, offset: centralDirectory.offset, size: centralDirectory.size)

        guard entries.count <= limits.maximumEntryOrSectionCount else {
            throw ASKHWPError.unsupportedFeature("ZIP archive declares \(entries.count) entries, above the \(limits.maximumEntryOrSectionCount) entry limit.")
        }
        var declaredTotal = 0
        for entry in entries {
            let (sum, overflowed) = declaredTotal.addingReportingOverflow(Int(entry.uncompressedSize))
            guard !overflowed, sum <= limits.maximumDecodedTotalByteCount else {
                throw ASKHWPError.unsupportedFeature("ZIP archive declares more than \(limits.maximumDecodedTotalByteCount) uncompressed bytes.")
            }
            declaredTotal = sum
        }

        // A duplicated entry path is a property of the input, not a programming error.
        // `Dictionary(uniqueKeysWithValues:)` traps on it, which turns a malformed
        // document into a process crash instead of a typed parse failure.
        var entriesByPath: [String: Entry] = [:]
        entriesByPath.reserveCapacity(entries.count)
        for entry in entries {
            guard entriesByPath.updateValue(entry, forKey: entry.path) == nil else {
                throw ASKHWPError.malformedContainer("Duplicate ZIP entry path: \(entry.path).")
            }
        }
        self.entriesByPath = entriesByPath
    }

    func contains(_ path: String) -> Bool {
        entriesByPath[path] != nil
    }

    func entryPaths() -> [String] {
        entries.map(\.path).sorted()
    }

    func data(for path: String) throws -> Data {
        guard let entry = entriesByPath[path] else {
            throw ASKHWPError.resourceNotFound(path)
        }
        return try data(for: entry)
    }

    func string(for path: String, encoding: String.Encoding = .utf8) throws -> String {
        let data = try data(for: path)
        guard let string = String(data: data, encoding: encoding) else {
            throw ASKHWPError.malformedDocument("Unable to decode ZIP entry as text: \(path)")
        }
        return string
    }

    private func data(for entry: Entry) throws -> Data {
        guard !entry.isDirectory else { return Data() }
        guard !entry.isEncrypted else {
            throw ASKHWPError.unsupportedFeature("Encrypted ZIP entries are not supported: \(entry.path)")
        }
        guard entry.compressedSize != UInt32.max, entry.uncompressedSize != UInt32.max else {
            throw ASKHWPError.unsupportedFeature("ZIP64 entries are not supported: \(entry.path)")
        }
        guard Int(entry.uncompressedSize) <= limits.maximumDecodedStreamByteCount else {
            throw ASKHWPError.unsupportedFeature("ZIP entry too large: \(entry.path) (\(entry.uncompressedSize) bytes)")
        }

        let localOffset = Int(entry.localHeaderOffset)
        guard try Self.uint32LE(data, at: localOffset) == 0x0403_4B50 else {
            throw ASKHWPError.malformedContainer("Invalid local ZIP header for \(entry.path).")
        }
        let fileNameLength = Int(try Self.uint16LE(data, at: localOffset + 26))
        let extraLength = Int(try Self.uint16LE(data, at: localOffset + 28))
        let payloadOffset = localOffset + 30 + fileNameLength + extraLength
        let compressedSize = Int(entry.compressedSize)
        guard payloadOffset >= 0, payloadOffset + compressedSize <= data.count else {
            throw ASKHWPError.malformedContainer("ZIP entry data range escapes archive: \(entry.path).")
        }

        let payload = Data(data[payloadOffset..<(payloadOffset + compressedSize)])
        let inflated: Data
        switch entry.compressionMethod {
        case 0:
            inflated = payload
        case 8:
            inflated = try ASKDeflateDecoder.inflateRaw(payload, maxOutputSize: Int(entry.uncompressedSize))
        default:
            throw ASKHWPError.unsupportedFeature("ZIP compression method \(entry.compressionMethod) is not supported for \(entry.path).")
        }

        guard inflated.count == Int(entry.uncompressedSize) else {
            throw ASKHWPError.decompressionFailed("ZIP entry size mismatch for \(entry.path): expected \(entry.uncompressedSize), got \(inflated.count).")
        }
        let actualCRC = Self.crc32(inflated)
        guard actualCRC == entry.crc32 else {
            throw ASKHWPError.decompressionFailed("ZIP CRC-32 mismatch for \(entry.path).")
        }
        return inflated
    }

    private static func findCentralDirectory(in data: Data) throws -> (offset: Int, size: Int) {
        guard data.count >= 22 else {
            throw ASKHWPError.malformedContainer("ZIP file is too short to contain an end-of-central-directory record.")
        }
        let minimumOffset = max(0, data.count - 65_557)
        var offset = data.count - 22
        while offset >= minimumOffset {
            if try uint32LE(data, at: offset) == 0x0605_4B50 {
                let diskNumber = try uint16LE(data, at: offset + 4)
                let centralDirectoryDisk = try uint16LE(data, at: offset + 6)
                guard diskNumber == 0, centralDirectoryDisk == 0 else {
                    throw ASKHWPError.unsupportedFeature("Multi-disk ZIP archives are not supported.")
                }
                let size = Int(try uint32LE(data, at: offset + 12))
                let centralOffset = Int(try uint32LE(data, at: offset + 16))
                guard centralOffset >= 0, size >= 0, centralOffset + size <= data.count else {
                    throw ASKHWPError.malformedContainer("ZIP central directory range escapes archive.")
                }
                return (centralOffset, size)
            }
            offset -= 1
        }
        throw ASKHWPError.malformedContainer("ZIP end-of-central-directory record not found.")
    }

    private static func readCentralDirectory(data: Data, offset: Int, size: Int) throws -> [Entry] {
        var entries: [Entry] = []
        var cursorOffset = offset
        let endOffset = offset + size
        while cursorOffset < endOffset {
            guard try uint32LE(data, at: cursorOffset) == 0x0201_4B50 else {
                throw ASKHWPError.malformedContainer("Invalid ZIP central directory header at byte \(cursorOffset).")
            }
            let flags = try uint16LE(data, at: cursorOffset + 8)
            let method = try uint16LE(data, at: cursorOffset + 10)
            let crc = try uint32LE(data, at: cursorOffset + 16)
            let compressedSize = try uint32LE(data, at: cursorOffset + 20)
            let uncompressedSize = try uint32LE(data, at: cursorOffset + 24)
            let fileNameLength = Int(try uint16LE(data, at: cursorOffset + 28))
            let extraLength = Int(try uint16LE(data, at: cursorOffset + 30))
            let commentLength = Int(try uint16LE(data, at: cursorOffset + 32))
            let localHeaderOffset = try uint32LE(data, at: cursorOffset + 42)
            let nameStart = cursorOffset + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= endOffset else {
                throw ASKHWPError.malformedContainer("ZIP file name escapes central directory.")
            }
            let nameBytes = Data(data[nameStart..<nameEnd])
            let path = Self.decodePath(nameBytes, flags: flags)
            entries.append(.init(
                path: path,
                compressionMethod: method,
                generalPurposeBitFlag: flags,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
            cursorOffset = nameEnd + extraLength + commentLength
            guard cursorOffset <= endOffset else {
                throw ASKHWPError.malformedContainer("ZIP central directory entry escapes central directory.")
            }
        }
        return entries
    }

    private static func decodePath(_ data: Data, flags: UInt16) -> String {
        if (flags & 0x0800) != 0, let string = String(data: data, encoding: .utf8) {
            return string
        }
        // HWPX package paths are ASCII/UTF-8 in practice. Fall back to UTF-8 and then lossy Latin-1.
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(data.map { Character(UnicodeScalar($0)) })
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func uint16LE(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw ASKHWPError.malformedContainer("Invalid UInt16 offset \(offset).")
        }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32LE(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw ASKHWPError.malformedContainer("Invalid UInt32 offset \(offset).")
        }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
