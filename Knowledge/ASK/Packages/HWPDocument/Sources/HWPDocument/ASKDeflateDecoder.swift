import Foundation
import DocumentCore

enum ASKDeflateDecoder {
    /// Inflates the stream used by a compressed HWP BodyText section.
    ///
    /// HWP 5 files conventionally store a raw DEFLATE stream.  A few producers
    /// emit a zlib-wrapped stream instead, so the reader follows the same
    /// compatibility order as rHWP: raw DEFLATE first, zlib as a fallback.
    static func inflateHWPStream(_ data: Data, maxOutputSize: Int? = nil) throws -> Data {
        do {
            return try inflateRaw(data, maxOutputSize: maxOutputSize)
        } catch let rawError {
            do {
                return try inflateZlib(data, maxOutputSize: maxOutputSize)
            } catch {
                // The raw stream is the HWP5 default. If neither representation
                // succeeds, retain its error so output-limit and malformed-stream
                // diagnostics are not hidden by a failed compatibility fallback.
                throw rawError
            }
        }
    }

    static func inflateZlib(_ data: Data, maxOutputSize: Int? = nil) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else {
            throw ASKHWPError.decompressionFailed("Zlib stream is too short.")
        }

        let cmf = bytes[0]
        let flg = bytes[1]
        guard cmf & 0x0F == 8 else {
            throw ASKHWPError.decompressionFailed("Unsupported zlib compression method: \(cmf & 0x0F).")
        }
        guard ((UInt16(cmf) << 8) | UInt16(flg)) % 31 == 0 else {
            throw ASKHWPError.decompressionFailed("Invalid zlib header checksum.")
        }
        guard (flg & 0x20) == 0 else {
            throw ASKHWPError.unsupportedFeature("Preset zlib dictionaries are not supported.")
        }

        let deflatePayload = Data(bytes[2..<(bytes.count - 4)])
        let inflated = try inflateRaw(deflatePayload, maxOutputSize: maxOutputSize)
        let expectedAdler = UInt32(bytes[bytes.count - 4]) << 24
            | UInt32(bytes[bytes.count - 3]) << 16
            | UInt32(bytes[bytes.count - 2]) << 8
            | UInt32(bytes[bytes.count - 1])
        let actualAdler = adler32([UInt8](inflated))
        guard actualAdler == expectedAdler else {
            throw ASKHWPError.decompressionFailed("Zlib Adler-32 mismatch.")
        }
        return inflated
    }

    static func inflateRaw(_ data: Data, maxOutputSize: Int? = nil) throws -> Data {
        var inflater = ASKRawDeflateInflater(bytes: [UInt8](data), maxOutputSize: maxOutputSize)
        return Data(try inflater.inflate())
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        let modulus: UInt32 = 65_521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }
        return (b << 16) | a
    }
}

private struct ASKRawDeflateInflater {
    private var reader: ASKDeflateBitReader
    private var output: [UInt8] = []
    private let maxOutputSize: Int?

    init(bytes: [UInt8], maxOutputSize: Int?) {
        self.reader = ASKDeflateBitReader(bytes: bytes)
        self.maxOutputSize = maxOutputSize
    }

    mutating func inflate() throws -> [UInt8] {
        var isFinalBlock = false
        while !isFinalBlock {
            isFinalBlock = try reader.readBits(1) == 1
            let blockType = try reader.readBits(2)
            switch blockType {
            case 0:
                try inflateStoredBlock()
            case 1:
                try inflateCompressedBlock(
                    literalLengthTree: ASKHuffmanTree.fixedLiteralLength(),
                    distanceTree: ASKHuffmanTree.fixedDistance()
                )
            case 2:
                let trees = try readDynamicTrees()
                try inflateCompressedBlock(literalLengthTree: trees.literalLength, distanceTree: trees.distance)
            default:
                throw ASKHWPError.decompressionFailed("Reserved DEFLATE block type encountered.")
            }
        }
        return output
    }

    private mutating func inflateStoredBlock() throws {
        reader.alignToByte()
        let len = try reader.readAlignedUInt16LE()
        let nlen = try reader.readAlignedUInt16LE()
        guard len == ~nlen else {
            throw ASKHWPError.decompressionFailed("Invalid stored DEFLATE block length complement.")
        }
        let bytes = try reader.readAlignedBytes(count: Int(len))
        try reserveOutputCapacity(for: bytes.count)
        output.append(contentsOf: bytes)
    }

    private mutating func readDynamicTrees() throws -> (literalLength: ASKHuffmanTree, distance: ASKHuffmanTree) {
        let hlit = try Int(reader.readBits(5)) + 257
        let hdist = try Int(reader.readBits(5)) + 1
        let hclen = try Int(reader.readBits(4)) + 4
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengthLengths = Array(repeating: 0, count: 19)
        for index in 0..<hclen {
            codeLengthLengths[order[index]] = try Int(reader.readBits(3))
        }
        let codeLengthTree = try ASKHuffmanTree(codeLengths: codeLengthLengths)
        var lengths: [Int] = []
        lengths.reserveCapacity(hlit + hdist)

        while lengths.count < hlit + hdist {
            let symbol = try codeLengthTree.decode(from: &reader)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else {
                    throw ASKHWPError.decompressionFailed("DEFLATE repeat code 16 appeared before any code length.")
                }
                let repeatCount = try Int(reader.readBits(2)) + 3
                lengths.append(contentsOf: repeatElement(previous, count: repeatCount))
            case 17:
                let repeatCount = try Int(reader.readBits(3)) + 3
                lengths.append(contentsOf: repeatElement(0, count: repeatCount))
            case 18:
                let repeatCount = try Int(reader.readBits(7)) + 11
                lengths.append(contentsOf: repeatElement(0, count: repeatCount))
            default:
                throw ASKHWPError.decompressionFailed("Invalid DEFLATE code-length symbol \(symbol).")
            }
        }

        let literalLengths = Array(lengths[0..<hlit])
        let distanceLengths = Array(lengths[hlit..<(hlit + hdist)])
        return (try ASKHuffmanTree(codeLengths: literalLengths), try ASKHuffmanTree(codeLengths: distanceLengths))
    }

    private mutating func inflateCompressedBlock(literalLengthTree: ASKHuffmanTree, distanceTree: ASKHuffmanTree) throws {
        while true {
            let symbol = try literalLengthTree.decode(from: &reader)
            switch symbol {
            case 0...255:
                try reserveOutputCapacity(for: 1)
                output.append(UInt8(symbol))
            case 256:
                return
            case 257...285:
                let length = try decodeLength(symbol)
                let distanceSymbol = try distanceTree.decode(from: &reader)
                let distance = try decodeDistance(distanceSymbol)
                try copyFromHistory(distance: distance, length: length)
            default:
                throw ASKHWPError.decompressionFailed("Invalid DEFLATE literal/length symbol \(symbol).")
            }
        }
    }

    private mutating func decodeLength(_ symbol: Int) throws -> Int {
        let base = [
            3, 4, 5, 6, 7, 8, 9, 10,
            11, 13, 15, 17, 19, 23, 27, 31,
            35, 43, 51, 59, 67, 83, 99, 115,
            131, 163, 195, 227, 258
        ]
        let extra = [
            0, 0, 0, 0, 0, 0, 0, 0,
            1, 1, 1, 1, 2, 2, 2, 2,
            3, 3, 3, 3, 4, 4, 4, 4,
            5, 5, 5, 5, 0
        ]
        let index = symbol - 257
        guard index >= 0, index < base.count else {
            throw ASKHWPError.decompressionFailed("Invalid DEFLATE length symbol \(symbol).")
        }
        return try base[index] + Int(reader.readBits(extra[index]))
    }

    private mutating func decodeDistance(_ symbol: Int) throws -> Int {
        let base = [
            1, 2, 3, 4, 5, 7, 9, 13,
            17, 25, 33, 49, 65, 97, 129, 193,
            257, 385, 513, 769, 1025, 1537, 2049, 3073,
            4097, 6145, 8193, 12289, 16385, 24577
        ]
        let extra = [
            0, 0, 0, 0, 1, 1, 2, 2,
            3, 3, 4, 4, 5, 5, 6, 6,
            7, 7, 8, 8, 9, 9, 10, 10,
            11, 11, 12, 12, 13, 13
        ]
        guard symbol >= 0, symbol < base.count else {
            throw ASKHWPError.decompressionFailed("Invalid DEFLATE distance symbol \(symbol).")
        }
        return try base[symbol] + Int(reader.readBits(extra[symbol]))
    }

    private mutating func copyFromHistory(distance: Int, length: Int) throws {
        guard distance > 0, distance <= output.count else {
            throw ASKHWPError.decompressionFailed("Invalid DEFLATE back-reference distance \(distance).")
        }
        try reserveOutputCapacity(for: length)
        for _ in 0..<length {
            output.append(output[output.count - distance])
        }
    }

    private func reserveOutputCapacity(for additionalCount: Int) throws {
        guard additionalCount >= 0 else {
            throw ASKHWPError.decompressionFailed("Invalid DEFLATE output length \(additionalCount).")
        }
        guard let maxOutputSize else { return }
        guard output.count <= maxOutputSize, additionalCount <= maxOutputSize - output.count else {
            throw ASKHWPError.decompressionFailed("DEFLATE output exceeds configured limit of \(maxOutputSize) bytes.")
        }
    }
}

private struct ASKDeflateBitReader {
    private let bytes: [UInt8]
    private var byteOffset = 0
    private var bitBuffer: UInt32 = 0
    private var bitCount = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readBits(_ count: Int) throws -> UInt32 {
        guard count >= 0, count <= 16 else {
            throw ASKHWPError.decompressionFailed("Invalid DEFLATE bit count \(count).")
        }
        while bitCount < count {
            guard byteOffset < bytes.count else {
                throw ASKHWPError.decompressionFailed("Unexpected end of DEFLATE stream.")
            }
            bitBuffer |= UInt32(bytes[byteOffset]) << UInt32(bitCount)
            byteOffset += 1
            bitCount += 8
        }
        let mask = count == 0 ? UInt32(0) : ((UInt32(1) << UInt32(count)) - 1)
        let value = bitBuffer & mask
        bitBuffer >>= UInt32(count)
        bitCount -= count
        return value
    }

    mutating func alignToByte() {
        bitBuffer = 0
        bitCount = 0
    }

    mutating func readAlignedUInt16LE() throws -> UInt16 {
        let bytes = try readAlignedBytes(count: 2)
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    mutating func readAlignedBytes(count: Int) throws -> [UInt8] {
        guard bitCount == 0 else {
            throw ASKHWPError.decompressionFailed("DEFLATE reader is not byte-aligned.")
        }
        guard count >= 0, byteOffset >= 0, byteOffset <= bytes.count,
              count <= bytes.count - byteOffset else {
            throw ASKHWPError.decompressionFailed("Unexpected end of byte-aligned DEFLATE block.")
        }
        let result = Array(bytes[byteOffset..<(byteOffset + count)])
        byteOffset += count
        return result
    }
}

private struct ASKHuffmanTree {
    private let table: [Int: Int]
    private let maximumCodeLength: Int

    static func fixedLiteralLength() throws -> ASKHuffmanTree {
        var lengths = Array(repeating: 0, count: 288)
        for symbol in 0...143 { lengths[symbol] = 8 }
        for symbol in 144...255 { lengths[symbol] = 9 }
        for symbol in 256...279 { lengths[symbol] = 7 }
        for symbol in 280...287 { lengths[symbol] = 8 }
        return try ASKHuffmanTree(codeLengths: lengths)
    }

    static func fixedDistance() throws -> ASKHuffmanTree {
        try ASKHuffmanTree(codeLengths: Array(repeating: 5, count: 32))
    }

    init(codeLengths: [Int]) throws {
        let maxLength = codeLengths.max() ?? 0
        guard maxLength > 0 else {
            throw ASKHWPError.decompressionFailed("Empty DEFLATE Huffman tree.")
        }
        self.maximumCodeLength = maxLength

        var blCount = Array(repeating: 0, count: maxLength + 1)
        for length in codeLengths where length > 0 {
            guard length <= maxLength else { continue }
            blCount[length] += 1
        }

        var nextCode = Array(repeating: 0, count: maxLength + 1)
        var code = 0
        for bits in 1...maxLength {
            code = (code + blCount[bits - 1]) << 1
            nextCode[bits] = code
        }

        var table: [Int: Int] = [:]
        for (symbol, length) in codeLengths.enumerated() where length > 0 {
            let canonicalCode = nextCode[length]
            nextCode[length] += 1
            let reversedCode = Self.reverseBits(canonicalCode, length: length)
            table[(reversedCode << 5) | length] = symbol
        }
        self.table = table
    }

    func decode(from reader: inout ASKDeflateBitReader) throws -> Int {
        var code = 0
        for length in 1...maximumCodeLength {
            let bit = try Int(reader.readBits(1))
            code |= bit << (length - 1)
            if let symbol = table[(code << 5) | length] {
                return symbol
            }
        }
        throw ASKHWPError.decompressionFailed("Invalid DEFLATE Huffman code.")
    }

    private static func reverseBits(_ value: Int, length: Int) -> Int {
        var result = 0
        for bitIndex in 0..<length {
            result = (result << 1) | ((value >> bitIndex) & 1)
        }
        return result
    }
}
