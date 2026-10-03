import ModelArtifactStore
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 3 else { exit(2) }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let ready = URL(fileURLWithPath: CommandLine.arguments[2])
let bytes = Data("model".utf8)
let digest = ArtifactDigest(
  rawValue: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())!
let manifest = try ArtifactManifest(
  artifactID: "text",
  files: [try .init(path: "model.bin", byteCount: UInt64(bytes.count), sha256: digest)])
let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
let lease = try await store.open(manifest)
try Data("ready".utf8).write(to: ready, options: .atomic)
try await Task.sleep(for: .seconds(30))
lease.close()
