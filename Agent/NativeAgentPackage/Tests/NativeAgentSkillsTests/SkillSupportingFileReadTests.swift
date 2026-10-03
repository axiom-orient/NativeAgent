import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

@Test
func readSkillFileReturnsExactPagedSnapshotContent() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-read-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        )
    )
    _ = try await library.addCustomTextSkill(
        name: "paged-reference",
        description: "Reads an exact supporting reference",
        instructions: "Read assets/references/guide.md before answering.",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        assets: ["references/guide.md": "alphaβgammaδomega"]
    )
    let runtime = SkillRuntime(
        library: library,
        scriptRunner: RecordingScriptRunner(response: SkillScriptResponse(result: "unused")),
        intentService: NoopIntentService()
    )

    let first = try await runtime.readSkillFile(
        skillName: "paged-reference",
        relativePath: "assets/references/guide.md",
        characterOffset: 0,
        maxCharacters: 6,
        callID: "read-1"
    )
    #expect(first.output["content"]?.stringValue == "alphaβ")
    #expect(first.output["nextCharacterOffset"]?.intValue == 6)
    let digest = try #require(first.output["contentSHA256"]?.stringValue)

    let second = try await runtime.readSkillFile(
        skillName: "paged-reference",
        relativePath: "assets/references/guide.md",
        characterOffset: 6,
        maxCharacters: 64,
        callID: "read-2"
    )
    #expect(second.output["content"]?.stringValue == "gammaδomega")
    #expect(second.output["nextCharacterOffset"]?.isNull == true)
    #expect(second.output["contentSHA256"]?.stringValue == digest)
}

@Test
func readSkillFileRejectsTraversalAndBinaryResources() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-read-reject-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = SkillLibrary(
        workspace: .init(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        )
    )
    _ = try await library.addCustomTextSkill(
        name: "safe-reference",
        description: "Reject invalid supporting paths",
        instructions: "Read resources when needed.",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        binaryAssets: ["images/blob.bin": Data([0, 1, 2])]
    )
    let runtime = SkillRuntime(
        library: library,
        scriptRunner: RecordingScriptRunner(response: SkillScriptResponse(result: "unused")),
        intentService: NoopIntentService()
    )

    await #expect(throws: AgentError.self) {
        _ = try await runtime.readSkillFile(
            skillName: "safe-reference",
            relativePath: "../escape.md",
            characterOffset: 0,
            maxCharacters: 64,
            callID: "traversal"
        )
    }
    await #expect(throws: AgentError.self) {
        _ = try await runtime.readSkillFile(
            skillName: "safe-reference",
            relativePath: "assets/images/blob.bin",
            characterOffset: 0,
            maxCharacters: 64,
            callID: "binary"
        )
    }
}
