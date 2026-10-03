import Foundation
import Testing
@testable import NativeAgentStore

#if os(iOS)
@Test
func storeDataPolicyAppliesAndClearsBackupExclusion() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("native-agent-store-policy-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try StoreDataPolicy(excludeFromBackup: true).apply(
        to: root,
        fileManager: fileManager
    )
    #expect(
        try URL(fileURLWithPath: root.path)
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup == true
    )

    try StoreDataPolicy(excludeFromBackup: false).apply(
        to: root,
        fileManager: fileManager
    )
    #expect(
        try URL(fileURLWithPath: root.path)
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup != true
    )
}
#endif

@Test
func storeCodecRejectsJSONThatExceedsItsReadBudgetBeforeWriting() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-store-codec-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: (any Error).self) {
        try StoreCodecs.write(
            ["payload": String(repeating: "x", count: 128)],
            to: url,
            maximumByteCount: 32
        )
    }
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
}

#if os(Linux) || os(macOS)
@Test
func storeSandboxRejectsDanglingSymlinkTraversal() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("native-agent-store-symlink-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let danglingTarget = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let linkedDirectory = root.appendingPathComponent("dangling", isDirectory: true)
    try fileManager.createSymbolicLink(at: linkedDirectory, withDestinationURL: danglingTarget)

    let guardObject = StoreSandboxGuard(rootURL: root, fileManager: fileManager)
    #expect(throws: (any Error).self) {
        _ = try guardObject.validateFileURL(
            root.appendingPathComponent("dangling/escape.json")
        )
    }
}
#endif
