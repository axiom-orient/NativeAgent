import Foundation
import Testing
@testable import KnowledgeCore

struct ASKSHA256Tests {
    @Test
    func knownDigestVectorsMatchSHA256Specification() {
        #expect(ASKSHA256.hexDigest(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ASKSHA256.hexDigest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ASKSHA256.prefixedDigest(Data("hello world".utf8)) == "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }

    @Test
    func digestBytesAndHexDigestStayConsistent() {
        let data = Data((0 ..< 255).map(UInt8.init))
        let bytes = ASKSHA256.digest(data)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()

        #expect(bytes.count == 32)
        #expect(hex == ASKSHA256.hexDigest(data))
    }
}
