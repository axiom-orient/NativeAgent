import Foundation
import Testing

@testable import NativeAgentManager

struct AgentCharacterLocaleTests {
  @Test
  func regionalExamplesDoNotBleedIntoAnotherScriptOrRegion() throws {
    let character = try AgentCharacterProfile(
      name: "Guide",
      examples: [
        .init(language: "zh-Hans", user: "你好", character: "simplified-only"),
        .init(language: "zh-Hant", user: "你好", character: "traditional-only"),
        .init(language: "en-GB", user: "Hi", character: "british-only"),
        .init(language: "en-US", user: "Hi", character: "american-only"),
        .init(language: "en", user: "Hi", character: "generic-only"),
      ])
    let compiler = try AgentResponsePromptAugmentor(configuration: .init(character: character))
    let traditional = try compiler.compile(
      input: "你好", metadata: AgentResponseOptions(language: "zh-Hant-TW").metadata)
    #expect(traditional.instructions.contains("traditional-only"))
    #expect(!traditional.instructions.contains("simplified-only"))
    let british = try compiler.compile(
      input: "Hi", metadata: AgentResponseOptions(language: "EN_gb").metadata)
    #expect(british.instructions.contains("british-only"))
    #expect(!british.instructions.contains("american-only"))
    #expect(!british.instructions.contains("generic-only"))
    let generic = try compiler.compile(
      input: "Hi", metadata: AgentResponseOptions(language: "en-AU").metadata)
    #expect(generic.instructions.contains("generic-only"))
    #expect(!generic.instructions.contains("british-only"))
    #expect(!generic.instructions.contains("american-only"))
  }

  @Test
  func localizedVoiceRefinesOnlyTheCurrentConversation() throws {
    let profile = try AgentCharacterProfile(
      name: "Lumi", personality: "Careful and curious", speakingStyle: "Warm and concise",
      voices: [
        .init(
          language: "ko", speakingStyle: "ko-voice-only", selfReference: "저", addressForm: "방문객님"),
        .init(language: "en-GB", speakingStyle: "british-voice-only"),
        .init(language: "en", speakingStyle: "english-voice-only"),
      ])
    let compiler = try AgentResponsePromptAugmentor(configuration: .init(character: profile))
    let korean = try compiler.compile(
      input: "안녕", metadata: AgentResponseOptions(language: "ko-KR").metadata)
    #expect(korean.instructions.contains("ko-voice-only"))
    #expect(korean.instructions.contains("방문객님"))
    #expect(!korean.instructions.contains("english-voice-only"))
    let british = try compiler.compile(
      input: "Hi", metadata: AgentResponseOptions(language: "en-GB").metadata)
    #expect(british.instructions.contains("british-voice-only"))
    #expect(!british.instructions.contains("english-voice-only"))
    #expect(british.instructions.contains("Careful and curious"))
    let generic = try compiler.compile(
      input: "Hi", metadata: AgentResponseOptions(language: "en").metadata)
    #expect(generic.instructions.contains("english-voice-only"))
    #expect(!generic.instructions.contains("british-voice-only"))
    #expect(!generic.instructions.contains("ko-voice-only"))
    let unknown = try compiler.compile(input: "🙂")
    #expect(unknown.instructions.contains("Warm and concise"))
    #expect(!unknown.instructions.contains("voice-only"))
    let request = try AgentWritingRequest(source: "The test use memory.", language: "en")
    let editing = try compiler.compile(input: request.input, metadata: request.metadata)
    #expect(!editing.instructions.contains("Lumi"))
    #expect(!editing.instructions.contains("voice-only"))
  }

  @Test
  func fallbackRetainsLocaleAndNeverOverridesConfidentUnsupportedInput() throws {
    let profile = try AgentCharacterProfile(
      name: "Guide",
      voices: [
        .init(language: "zh-Hant", speakingStyle: "traditional-voice"),
        .init(language: "zh-Hans", speakingStyle: "simplified-voice"),
      ])
    let compiler = try AgentResponsePromptAugmentor(
      configuration: .init(character: profile, fallbackLanguage: "zh-Hant-TW"))
    let fallback = try compiler.compile(input: "🙂")
    #expect(fallback.languageIdentifier == "zh-Hant-TW")
    #expect(fallback.instructions.contains("traditional-voice"))
    #expect(!fallback.instructions.contains("simplified-voice"))
    let unsupported = try compiler.compile(
      input: "Ich möchte heute in der Bibliothek ein interessantes Buch über Geschichte lesen.")
    #expect(unsupported.languageIdentifier == nil)
    #expect(!unsupported.instructions.contains("traditional-voice"))
    let editing = try AgentWritingRequest(
      source: "Ich möchte heute in der Bibliothek ein interessantes Buch über Geschichte lesen.")
    #expect(throws: AgentResponseError.unsupportedLanguage("de")) {
      try compiler.compile(input: editing.input, metadata: editing.metadata)
    }
  }

  @Test
  func localeLookupRemovesExtensionSingletonsAndDoesNotGuessRegions() {
    #expect(
      AgentResponseLocale.bestMatch(
        for: "zh-Hant-CN-x-private1-private2", available: ["zh", "zh-Hant", "zh-Hans"]) == "zh-hant"
    )
    #expect(
      AgentResponseLocale.bestMatch(for: "en-US-u-ca-gregory", available: ["en-US-u", "en-US"])
        == "en-us")
    #expect(AgentResponseLocale.bestMatch(for: "en", available: ["en-US", "en-GB"]) == nil)
    #expect(AgentResponseLocale.bestMatch(for: "zh-TW", available: ["zh-Hant"]) == nil)
    #expect(AgentResponseLocale.bestMatch(for: nil, available: ["ko"]) == nil)
  }

  @Test
  func profilesRequireVoicesAndCurrentVoicesRoundTripWithoutSilentRepair() throws {
    let original = try AgentCharacterProfile(name: "Guide", personality: "curious")
    let encoder = JSONEncoder()
    var old = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
    old.removeValue(forKey: "voices")
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        AgentCharacterProfile.self, from: JSONSerialization.data(withJSONObject: old))
    }
    let localized = try AgentCharacterProfile(
      name: "Guide", voices: [.init(language: "ko", speakingStyle: "존댓말")])
    let settings = try AgentResponseConfiguration(character: localized)
    #expect(
      try JSONDecoder().decode(AgentResponseConfiguration.self, from: encoder.encode(settings))
        == settings)
    #expect(
      try settings.snapshotDigest()
        != AgentResponseConfiguration(character: original).snapshotDigest())
    old["voices"] = [
      ["language": "ko", "speakingStyle": "", "selfReference": "", "addressForm": ""]
    ]
    #expect(throws: AgentResponseError.invalidCharacterProfile) {
      try JSONDecoder().decode(
        AgentCharacterProfile.self, from: JSONSerialization.data(withJSONObject: old))
    }
    #expect(throws: AgentResponseError.invalidCharacterProfile) {
      try AgentCharacterProfile(
        name: "Guide",
        voices: [
          .init(language: "en-GB", speakingStyle: "first"),
          .init(language: "EN_gb", speakingStyle: "duplicate"),
        ])
    }
    #expect(throws: AgentResponseError.invalidCharacterProfile) {
      try AgentCharacterProfile(
        name: "Guide",
        voices: [.init(language: "ko", speakingStyle: String(repeating: "말", count: 3_000))])
    }
  }

  @Test
  func currentProfileAtTheByteLimitRoundTripsAndMissingVoicesIsRejected() throws {
    var fields: [String: Any] = [
      "name": "A", "background": "", "personality": "", "speakingStyle": "",
      "relationship": "", "scenario": "", "knowledgeBoundaries": "", "examples": [String](), "voices": [String](),
    ]
    let overhead = try JSONSerialization.data(withJSONObject: fields).count
    fields["background"] = String(repeating: "a", count: 6 * 1_024 - overhead)
    let encoded = try JSONSerialization.data(withJSONObject: fields)
    #expect(encoded.count == 6 * 1_024)
    let profile = try JSONDecoder().decode(AgentCharacterProfile.self, from: encoded)
    #expect(profile.voices.isEmpty)
    #expect(try JSONEncoder().encode(profile).count == encoded.count)
    fields.removeValue(forKey: "voices")
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(AgentCharacterProfile.self, from: JSONSerialization.data(withJSONObject: fields))
    }
  }

  @Test
  func namedWritingSkillPreservesLocaleAndRejectsCrossLanguageDispatch() throws {
    let writing = try AgentNativeWritingSkill.englishPolish.writingRequest(
      source: "The programme use colour.", language: "en-GB")
    #expect(writing.language == "en-GB")
    let compiled = try AgentResponsePromptAugmentor().compile(
      input: writing.input, metadata: writing.metadata)
    #expect(compiled.languageIdentifier == "en-GB")
    #expect(compiled.loadedPolicies == ["editorial", "en-editorial"])
    #expect(throws: AgentResponseError.invalidRequest) {
      try AgentNativeWritingSkill.englishPolish.writingRequest(source: "원문", language: "ko")
    }
  }
}
