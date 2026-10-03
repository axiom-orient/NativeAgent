import NativeAgentSkills

struct AgentSkillSnapshot: Sendable {
  static var emptyDigest: String { SkillExecutionSnapshot.emptyDigest }

  let executionSnapshot: SkillExecutionSnapshot

  var selectedSkills: [ManagedSkill] { executionSnapshot.selectedSkills }
  var digest: String { executionSnapshot.digest }

  static func make(library: SkillLibrary) async throws -> AgentSkillSnapshot {
    do {
      return AgentSkillSnapshot(executionSnapshot: try await SkillExecutionSnapshot.capture(library: library))
    } catch SkillExecutionSnapshotError.unpinnedRemoteSkill(let name) {
      throw ManagedAgentError.unpinnedRemoteSkill(name)
    } catch {
      throw error
    }
  }
}
