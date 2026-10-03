import Foundation

/// Deterministic package-internal SHA-256 used for content identity at package boundaries.
public enum SHA256HexDigest {
    public static func digest(_ string: String) -> String {
        digest(Data(string.utf8))
    }

    public static func digest(_ data: Data) -> String {
        var accumulator = SHA256Accumulator()
        accumulator.update(data)
        return accumulator.finalizeHex()
    }
}

/// Incremental SHA-256 for bounded-memory package boundary validation.
public struct SHA256Accumulator {
    private var state = SHA256Core.initial
    private var bufferedBytes: [UInt8] = []
    private var totalByteCount: UInt64 = 0
    private var isFinalized = false

    public init() {}

    public mutating func update(_ data: Data) {
        precondition(isFinalized == false, "SHA-256 accumulator cannot be reused after finalization.")
        precondition(
            UInt64(data.count) <= UInt64.max - totalByteCount,
            "SHA-256 input length exceeds UInt64."
        )
        totalByteCount += UInt64(data.count)

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var offset = 0

            if bufferedBytes.isEmpty == false {
                let needed = 64 - bufferedBytes.count
                let consumed = min(needed, bytes.count)
                bufferedBytes.append(contentsOf: bytes[..<consumed])
                offset += consumed
                if bufferedBytes.count == 64 {
                    SHA256Core.process(block: bufferedBytes, state: &state)
                    bufferedBytes.removeAll(keepingCapacity: true)
                }
            }

            while offset + 64 <= bytes.count {
                SHA256Core.process(
                    block: bytes[offset..<(offset + 64)],
                    state: &state
                )
                offset += 64
            }

            if offset < bytes.count {
                bufferedBytes.append(contentsOf: bytes[offset...])
            }
        }
    }

    public mutating func finalizeHex() -> String {
        precondition(isFinalized == false, "SHA-256 accumulator can only be finalized once.")
        precondition(
            totalByteCount <= UInt64.max / 8,
            "SHA-256 input bit length exceeds UInt64."
        )
        isFinalized = true

        var finalBytes = bufferedBytes
        finalBytes.append(0x80)
        while finalBytes.count % 64 != 56 {
            finalBytes.append(0)
        }
        let bitLength = totalByteCount * 8
        finalBytes.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))

        for offset in stride(from: 0, to: finalBytes.count, by: 64) {
            SHA256Core.process(
                block: finalBytes[offset..<(offset + 64)],
                state: &state
            )
        }

        return state
            .flatMap { value in
                withUnsafeBytes(of: value.bigEndian, Array.init)
            }
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private enum SHA256Core {
    static let initial: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func process<C: RandomAccessCollection>(
        block: C,
        state: inout [UInt32]
    ) where C.Element == UInt8, C.Index == Int {
        precondition(block.count == 64)
        var words = [UInt32](repeating: 0, count: 64)
        let base = block.startIndex
        for index in 0..<16 {
            let start = base + index * 4
            words[index] = UInt32(block[start]) << 24
                | UInt32(block[start + 1]) << 16
                | UInt32(block[start + 2]) << 8
                | UInt32(block[start + 3])
        }
        for index in 16..<64 {
            let s0 = rotate(words[index - 15], 7)
                ^ rotate(words[index - 15], 18)
                ^ (words[index - 15] >> 3)
            let s1 = rotate(words[index - 2], 17)
                ^ rotate(words[index - 2], 19)
                ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]

        for index in 0..<64 {
            let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let choice = (e & f) ^ ((~e) & g)
            let temporary1 = h &+ s1 &+ choice &+ constants[index] &+ words[index]
            let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = s0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temporary1
            d = c
            c = b
            b = a
            a = temporary1 &+ temporary2
        }

        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    private static func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
