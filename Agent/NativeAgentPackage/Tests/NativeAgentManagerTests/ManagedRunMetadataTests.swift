import NativeAgentDomain
import LanguageModelCore
import Testing

@testable import NativeAgentManager

@Suite struct ManagedRunMetadataTests {
  @Test func allManagedEntryPathsRejectReservedIdentity() {
    for key in [
      AgentManager.agentMetadataKey, AgentManager.soulSnapshotMetadataKey,
      AgentManager.skillSnapshotMetadataKey, AgentManager.responseSnapshotMetadataKey,
    ] {
      let metadata: [String: JSONValue] = [key: .string("caller-owned")]
      #expect(throws: AgentError.self) { try ManagedRunMetadata.validateCaller(metadata) }
      #expect(throws: AgentError.self) {
        try ManagedRunMetadata(
          caller: metadata, agentID: "a", soulDigest: "s", skillDigest: "k", responseDigest: "r")
      }
    }
  }

  @Test func responseOptionsAreRequestScopedAndIdentityIsStamped() throws {
    let options: JSONValue = .object(["fixture": .string("response")])
    let original: [String: JSONValue] = [
      "trace": .string("kept"), AgentResponseOptions.metadataKey: options,
    ]
    let value = try ManagedRunMetadata(
      caller: original, agentID: "a", soulDigest: "s", skillDigest: "k", responseDigest: "r")
    #expect(value.request == [AgentResponseOptions.metadataKey: options])
    #expect(value.session[AgentResponseOptions.metadataKey] == nil)
    #expect(value.session["trace"] == .string("kept"))
    #expect(value.session[AgentManager.agentMetadataKey] == .string("a"))
    #expect(value.session[AgentManager.soulSnapshotMetadataKey] == .string("s"))
    #expect(value.session[AgentManager.skillSnapshotMetadataKey] == .string("k"))
    #expect(value.session[AgentManager.responseSnapshotMetadataKey] == .string("r"))
    #expect(original[AgentResponseOptions.metadataKey] == options)
  }

  @Test func callerValidationDoesNotStripUnreservedMetadata() throws {
    let original: [String: JSONValue] = ["trace": .string("kept")]
    #expect(try ManagedRunMetadata.validateCaller(original) == original)
    let value = try ManagedRunMetadata(
      caller: original, agentID: "a", soulDigest: "s", skillDigest: "k", responseDigest: "r")
    #expect(value.request.isEmpty)
  }
}
