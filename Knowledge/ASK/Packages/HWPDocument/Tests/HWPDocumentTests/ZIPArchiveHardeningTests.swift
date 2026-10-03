import Foundation
import Testing
@testable import HWPDocument

/// HWPX containers are untrusted input, so every malformed shape has to surface as a
/// typed error. A trap here would take the host process down with it.
struct ZIPArchiveHardeningTests {
    @Test
    func duplicateEntryPathThrowsInsteadOfTrapping() {
        let archive = ZIPFixture.storedArchive(entries: [
            ("Contents/section0.xml", Data("<section/>".utf8)),
            ("Contents/section0.xml", Data("<other/>".utf8)),
        ])

        #expect(throws: ASKHWPError.self) {
            _ = try ASKZIPArchive(data: archive)
        }
    }

    @Test
    func distinctEntryPathsStillLoad() throws {
        let archive = ZIPFixture.storedArchive(entries: [
            ("Contents/section0.xml", Data("<section/>".utf8)),
            ("Contents/section1.xml", Data("<other/>".utf8)),
        ])

        let parsed = try ASKZIPArchive(data: archive)
        #expect(parsed.entryPaths() == ["Contents/section0.xml", "Contents/section1.xml"])
        #expect(try parsed.string(for: "Contents/section1.xml") == "<other/>")
    }

    @Test
    func archiveSliceWithNonzeroStartIndexLoads() throws {
        let archive = ZIPFixture.storedArchive(entries: [("Contents/section0.xml", Data("<section/>".utf8))])
        let prefix = Data(repeating: 0xA5, count: 16)
        let padded = prefix + archive
        let slice = padded[prefix.count...]

        let parsed = try ASKZIPArchive(data: slice)
        #expect(try parsed.string(for: "Contents/section0.xml") == "<section/>")
    }

    @Test
    func emptyInputIsRejected() {
        #expect(throws: ASKHWPError.self) {
            _ = try ASKZIPArchive(data: Data())
        }
    }

    @Test
    func truncatedArchiveIsRejected() {
        let archive = ZIPFixture.storedArchive(entries: [("a.xml", Data("<a/>".utf8))])

        #expect(throws: ASKHWPError.self) {
            _ = try ASKZIPArchive(data: archive.prefix(archive.count / 2))
        }
    }
}

/// Builds minimal STORED (uncompressed) ZIP containers, including malformed ones that
/// no ordinary archiver would produce.
private enum ZIPFixture {
    static func storedArchive(entries: [(path: String, payload: Data)]) -> Data {
        var output = Data()
        var localOffsets: [Int] = []

        for entry in entries {
            localOffsets.append(output.count)
            var header = Data()
            append32(0x0403_4B50, to: &header)
            append16(20, to: &header)                                   // version needed
            append16(0, to: &header)                                    // flags
            append16(0, to: &header)                                    // stored
            append16(0, to: &header)                                    // mod time
            append16(0, to: &header)                                    // mod date
            append32(crc32(entry.payload), to: &header)
            append32(UInt32(entry.payload.count), to: &header)
            append32(UInt32(entry.payload.count), to: &header)
            append16(UInt16(entry.path.utf8.count), to: &header)
            append16(0, to: &header)                                    // extra length
            header.append(contentsOf: entry.path.utf8)
            header.append(entry.payload)
            output.append(header)
        }

        let centralStart = output.count
        for (index, entry) in entries.enumerated() {
            var record = Data()
            append32(0x0201_4B50, to: &record)
            append16(20, to: &record)                                   // version made by
            append16(20, to: &record)                                   // version needed
            append16(0, to: &record)                                    // flags
            append16(0, to: &record)                                    // stored
            append16(0, to: &record)                                    // mod time
            append16(0, to: &record)                                    // mod date
            append32(crc32(entry.payload), to: &record)
            append32(UInt32(entry.payload.count), to: &record)
            append32(UInt32(entry.payload.count), to: &record)
            append16(UInt16(entry.path.utf8.count), to: &record)
            append16(0, to: &record)                                    // extra length
            append16(0, to: &record)                                    // comment length
            append16(0, to: &record)                                    // disk number
            append16(0, to: &record)                                    // internal attributes
            append32(0, to: &record)                                    // external attributes
            append32(UInt32(localOffsets[index]), to: &record)
            record.append(contentsOf: entry.path.utf8)
            output.append(record)
        }
        let centralSize = output.count - centralStart

        var end = Data()
        append32(0x0605_4B50, to: &end)
        append16(0, to: &end)                                           // disk number
        append16(0, to: &end)                                           // central directory disk
        append16(UInt16(entries.count), to: &end)
        append16(UInt16(entries.count), to: &end)
        append32(UInt32(centralSize), to: &end)
        append32(UInt32(centralStart), to: &end)
        append16(0, to: &end)                                           // comment length
        output.append(end)

        return output
    }

    private static func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { index in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
