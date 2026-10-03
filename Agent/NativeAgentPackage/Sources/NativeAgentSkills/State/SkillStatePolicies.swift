import Foundation
import NativeAgentDomain

struct SkillStatePersistence: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    var directoryURL: URL {
        fileURL.deletingLastPathComponent()
    }

    func prepare(fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func load(fileManager: FileManager) throws -> SkillState {
        try prepare(fileManager: fileManager)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let data = try JSONEncoder.nativeAgent().encode(SkillState())
            try data.write(to: fileURL, options: .atomic)
            return try JSONDecoder.nativeAgent().decode(SkillState.self, from: data)
        }
        let data = try SkillBoundedFileReader.read(
            from: fileURL,
            maximumByteCount: SkillLocalFileLimits.maximumStateBytes,
            label: "Skill state"
        )
        return try JSONDecoder.nativeAgent().decode(SkillState.self, from: data)
    }

    func save(_ state: SkillState, fileManager: FileManager) throws {
        try prepare(fileManager: fileManager)
        guard state.hasCurrentContractVersions else {
            throw AgentError.persistenceFailure(
                "Skill state contains an unsupported first-party contract version."
            )
        }
        let data = try JSONEncoder.nativeAgent().encode(state)
        guard data.count <= SkillLocalFileLimits.maximumStateBytes else {
            throw AgentError.budgetExceeded(
                "Skill state exceeds \(SkillLocalFileLimits.maximumStateBytes) bytes."
            )
        }
        try data.write(to: fileURL, options: .atomic)
    }
}
