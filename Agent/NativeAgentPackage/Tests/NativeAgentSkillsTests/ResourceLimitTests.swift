import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentSkills

@Test
func remoteSkillLimitsRejectUnboundedConfiguration() {
    let limits = RemoteSkillFetchLimits(
        maximumResponseBytes: RemoteSkillFetchLimits.supportedMaximumResponseBytes + 1
    )
    #expect(throws: AgentError.self) {
        try limits.validate()
    }
}

@Test
func boundedSkillReaderRejectsOversizedAndNonUTF8Documents() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgent-skill-limit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let oversized = root.appendingPathComponent("oversized.md")
    try Data(repeating: 0x61, count: 5).write(to: oversized)
    #expect(throws: AgentError.self) {
        _ = try SkillBoundedFileReader.readUTF8(
            from: oversized,
            maximumByteCount: 4,
            label: "test skill"
        )
    }

    let binary = root.appendingPathComponent("binary.md")
    try Data([0xff]).write(to: binary)
    #expect(throws: AgentError.self) {
        _ = try SkillBoundedFileReader.readUTF8(
            from: binary,
            maximumByteCount: 4,
            label: "test skill"
        )
    }
}
