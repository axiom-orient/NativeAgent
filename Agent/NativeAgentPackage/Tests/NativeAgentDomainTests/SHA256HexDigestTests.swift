import Foundation
import Testing
@testable import NativeAgentDomain

@Test
func sha256MatchesPublishedKnownVectors() {
    #expect(
        SHA256HexDigest.digest("")
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    #expect(
        SHA256HexDigest.digest("abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    #expect(
        SHA256HexDigest.digest(Data("world".utf8))
            == "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7"
    )
}

@Test
func incrementalSHA256MatchesSinglePassAcrossBlockBoundaries() {
    let data = Data((0..<4_097).map { UInt8($0 % 251) })
    var accumulator = SHA256Accumulator()
    var offset = 0
    for size in [1, 63, 64, 65, 1_024, 2_880] {
        let end = min(offset + size, data.count)
        accumulator.update(data[offset..<end])
        offset = end
    }
    if offset < data.count {
        accumulator.update(data[offset...])
    }

    #expect(accumulator.finalizeHex() == SHA256HexDigest.digest(data))
}
