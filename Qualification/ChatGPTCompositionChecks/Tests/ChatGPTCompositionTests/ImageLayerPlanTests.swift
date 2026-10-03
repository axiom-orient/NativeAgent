@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Foundation
import Testing
import NativeAgentDomain
import LanguageModelCore

@Suite("Layer plan identity, ordering and Codable admission")
struct ImageLayerPlanTests {
  private let digest = String(repeating: "a", count: 64)

  @Test func canonicalRoundTripIsStableAndOrderIsMeaningful() throws {
    let back = try ChatGPTImageLayers.Layer(id: "wall", subject: "Wall", role: .background)
    let front = try ChatGPTImageLayers.Layer(id: "lamp", subject: "  Lamp  ", occlusion: .restore(description: "Hidden base"))
    let plan = try ChatGPTImageLayers.Plan(sourceSHA256: digest, width: 2, height: 1, layers: [back, front])
    let encoded = try plan.encoded()
    #expect(try ChatGPTImageLayers.Plan.decode(encoded) == plan)
    #expect(try plan.encoded() == encoded)
    #expect(try plan.digest() == SHA256HexDigest.digest(encoded))
    #expect(plan.layers.map(\.id) == ["wall", "lamp"])
    #expect(front.subject == "Lamp" && front.occlusion == .restore(description: "Hidden base"))
  }

  @Test func duplicateIDsAndInvalidBackgroundPositionsAreRejected() throws {
    let element = try ChatGPTImageLayers.Layer(id: "a", subject: "One")
    let back = try ChatGPTImageLayers.Layer(id: "b", subject: "Background", role: .background)
    let secondBack = try ChatGPTImageLayers.Layer(id: "c", subject: "Another background", role: .background)
    for layers in [[element, element], [element, back], [back, secondBack], []] {
      #expect(throws: AgentError.self) { _ = try ChatGPTImageLayers.Plan(sourceSHA256: digest, width: 2, height: 1, layers: layers) }
    }
  }

  @Test func countAndIdentifierBoundariesAreExplicit() throws {
    let all = try (0..<65).map { try ChatGPTImageLayers.Layer(id: "layer-\($0)", subject: "Subject \($0)") }
    #expect(try ChatGPTImageLayers.Plan(sourceSHA256: digest, width: 1, height: 1, layers: Array(all.prefix(64))).layers.count == 64)
    #expect(throws: AgentError.self) { _ = try ChatGPTImageLayers.Plan(sourceSHA256: digest, width: 1, height: 1, layers: all) }
    for id in ["", "../a", "한글", "a b", String(repeating: "a", count: 65)] {
      #expect(throws: AgentError.self) { _ = try ChatGPTImageLayers.Layer(id: id, subject: "Subject") }
    }
    #expect(try ChatGPTImageLayers.Layer(id: String(repeating: "a", count: 64), subject: "Subject").id.count == 64)
  }

  @Test func descriptionsRejectBlankNULAndByteOverflow() {
    for value in [" ", "x\0y", String(repeating: "한", count: 667)] {
      #expect(throws: AgentError.self) { _ = try ChatGPTImageLayers.Layer(id: "a", subject: value) }
      #expect(throws: AgentError.self) { _ = try ChatGPTImageLayers.Layer(id: "a", subject: "Subject", occlusion: .restore(description: value)) }
    }
  }

  @Test func decodedLayerCannotBypassValidatedInitializer() throws {
    let bad = Data(#"{"id":"../a","subject":"Subject","role":"element","occlusion":{"none":{}}}"#.utf8)
    #expect(throws: AgentError.self) { _ = try JSONDecoder().decode(ChatGPTImageLayers.Layer.self, from: bad) }
    let layer = try ChatGPTImageLayers.Layer(id: "a", subject: "Subject")
    let encoded = try ChatGPTImageLayers.Plan(sourceSHA256: digest, width: 2, height: 1, layers: [layer]).encoded()
    let text = String(decoding: encoded, as: UTF8.self)
    let wrongVersion = Data(text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)
    #expect(throws: AgentError.self) { _ = try ChatGPTImageLayers.Plan.decode(wrongVersion) }
    let wrongWidth = Data(text.replacingOccurrences(of: "\"width\":2", with: "\"width\":0").utf8)
    #expect(throws: AgentError.self) { _ = try ChatGPTImageLayers.Plan.decode(wrongWidth) }
    #expect(throws: AgentError.self) {
      _ = try ChatGPTImageLayers.Plan.decode(Data(repeating: 32, count: ChatGPTImageLayers.Plan.maximumEncodedBytes + 1))
    }
  }

  @Test func promptSelectsOneLayerAndCarriesCanvasAndOcclusionContract() throws {
    let first = try ChatGPTImageLayers.Layer(id: "cloud", subject: "left cloud", occlusion: .restore(description: "hidden cloud edge"))
    let other = try ChatGPTImageLayers.Layer(id: "bird", subject: "distinct bird description")
    let plan = try ChatGPTImageLayers.Plan(sourceSHA256: digest, width: 120, height: 80, layers: [first, other])
    let prompt = try plan.prompt(for: "cloud")
    #expect(prompt.contains("120x80") && prompt.contains("top-left") && prompt.contains("contact sheet"))
    #expect(prompt.contains("hidden cloud edge") && prompt.contains("inference"))
    #expect(prompt.contains("#00B140") && prompt.contains("#FF00FF"))
    #expect(!prompt.contains("distinct bird description"))
    #expect(throws: AgentError.self) { _ = try plan.prompt(for: "missing") }
  }
}
