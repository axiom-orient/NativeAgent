import Foundation
import DocumentCore

struct ASKByteCursor {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(data: Data, offset: Int = 0) {
        self.bytes = Array(data)
        self.offset = offset
    }

    init(bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var isAtEnd: Bool { offset >= bytes.count }
    var remainingCount: Int { max(bytes.count - offset, 0) }

    mutating func alignToByte() {
        // Byte cursor is already byte-aligned. Bit-level alignment lives in ASKDeflateBitReader.
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < bytes.count else { throw ASKHWPError.malformedContainer("Unexpected end of data at byte \(offset).") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16LE() throws -> UInt16 {
        let value = try Self.uint16LE(bytes, at: offset)
        offset += 2
        return value
    }

    mutating func readUInt32LE() throws -> UInt32 {
        let value = try Self.uint32LE(bytes, at: offset)
        offset += 4
        return value
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else {
            throw ASKHWPError.malformedContainer("Unexpected end of data while reading \(count) bytes at byte \(offset).")
        }
        let result = Array(bytes[offset..<(offset + count)])
        offset += count
        return result
    }

    func slice(offset: Int, count: Int) throws -> [UInt8] {
        guard count >= 0, offset >= 0, offset + count <= bytes.count else {
            throw ASKHWPError.malformedContainer("Invalid byte range offset=\(offset), count=\(count), size=\(bytes.count).")
        }
        return Array(bytes[offset..<(offset + count)])
    }

    static func uint16LE(_ bytes: [UInt8], at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw ASKHWPError.malformedContainer("Invalid UInt16 offset \(offset).")
        }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func uint32LE(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw ASKHWPError.malformedContainer("Invalid UInt32 offset \(offset).")
        }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    static func uint64LE(_ bytes: [UInt8], at offset: Int) throws -> UInt64 {
        let lower = UInt64(try uint32LE(bytes, at: offset))
        let upper = UInt64(try uint32LE(bytes, at: offset + 4))
        return lower | (upper << 32)
    }

    static func utf16LittleEndianString(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        let data = Data(bytes)
        return String(data: data, encoding: .utf16LittleEndian) ?? ""
    }
}
