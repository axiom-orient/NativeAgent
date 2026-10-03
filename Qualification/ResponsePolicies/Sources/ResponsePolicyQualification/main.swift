import Foundation
import NativeAgent
import NativeAgentManager
import AppleSystemModelProvider

/// Real, local model evidence. Nonempty text is never labeled semantic or character-fidelity PASS.
@main
struct ResponsePolicyQualification {
  static func main() async throws {
    if let export = ProcessInfo.processInfo.environment["NATIVEAGENT_RESPONSE_EXPORT"] {
      try exportPrompts(to: URL(fileURLWithPath: export))
      return
    }
    guard ProcessInfo.processInfo.environment["NATIVEAGENT_LIVE_FOUNDATION"] == "1" else {
      throw QualificationError.optInRequired
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NativeAgent-response-live-\(UUID().uuidString)")
    let connector = try FoundationModelsProviderConnector()
    print("Availability: \(try await connector.availability())")
    let manager = AgentManager(dataStore: .directory(root), providers: try .init([connector]))
    let profileA = try AgentCharacterProfile(
      name: "루미", background: "달 도서관의 사서. 파란 수첩에 별 관측 기록을 남긴다.",
      personality: "조심스럽고 따뜻하며 모르는 일은 모른다고 말한다.",
      speakingStyle: "짧고 부드러운 존댓말. 감탄사는 드물게 쓴다.",
      relationship: "처음 찾아온 방문객을 안내한다.",
      examples: [
        .init(language: "ko", user: "무엇부터 할까?", character: "먼저 기록을 살펴볼까요? 확인한 뒤 함께 골라 봐요."),
        .init(
          language: "en", user: "Where should we start?",
          character: "Let's check the records first. Then we can choose together."),
      ],
      voices: [
        .init(
          language: "ko", speakingStyle: "차분한 해요체 존댓말. 한 번에 짧게 대답한다.", selfReference: "저",
          addressForm: "방문객님"),
        .init(
          language: "en",
          speakingStyle: "Gentle, measured English. The character's English name is Lumi.",
          selfReference: "I", addressForm: "you"),
      ])
    let profileB = try AgentCharacterProfile(
      name: "토리", background: "같은 달 도서관의 탐험가. 빨간 지도를 들고 새 길을 찾는다.",
      personality: "활기차고 호기심이 많으며 바로 탐험 계획을 제안한다.",
      speakingStyle: "친근한 반말과 짧고 경쾌한 문장.",
      relationship: "새 친구와 함께 탐험한다.",
      examples: [
        .init(language: "ko", user: "무엇부터 할까?", character: "지도부터 펼쳐 보자! 가 보고 싶은 길이 있어?"),
        .init(
          language: "en", user: "Where should we start?",
          character: "Let's open the map! Which path catches your eye?"),
      ],
      voices: [
        .init(
          language: "ko", speakingStyle: "친구에게 해체 반말로 말한다. 해요체와 합니다체를 쓰지 않는다.", selfReference: "나",
          addressForm: "너"),
        .init(
          language: "en",
          speakingStyle:
            "Lively, informal English with contractions. The character's English name is Tori.",
          selfReference: "I", addressForm: "you"),
      ])
    for (id, character) in [("lumi", profileA), ("tori", profileB)] {
      _ = try await manager.createAgent(
        id: id, name: character.name,
        provider: .init(providerID: connector.descriptor.id),
        response: .init(character: character))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func emit(_ result: ResultRecord) throws {
      print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
    let samples = [
      ("ko", "이 변경은 지연 시간을 줄일 수 있습니다. 최대 3번 실행합니다. `retry()`는 그대로 둡니다."),
      (
        "en-GB",
        "Not all requests failed. The update may reduce latency by at most 3 ms. Keep `retry()` unchanged."
      ),
      ("ja", "すべての要求が失敗したわけではありません。最大3回実行できます。`retry()`は変更しません。"),
      ("zh-Hant-TW", "並非所有請求都失敗了。最多可以執行3次。請保留 `retry()`。"),
      ("es", "No todos los envíos fallaron. Podría tardar como máximo 3 ms. Conservá `retry()`."),
    ]
    for (language, source) in samples {
      let request = try AgentWritingRequest(source: source, language: language)
      let started = Date()
      do {
        let result = try await manager.runWriting(agentID: "lumi", request: request)
        let run = result.run
        try emit(
          ResultRecord(
            id: "polish-\(language)", input: source, output: run.output, error: nil,
            seconds: Date().timeIntervalSince(started), status: run.status.rawValue,
            protectedTokensPresent: ["3", "`retry()`"].allSatisfy {
              (run.output?.contains($0) == true)
            },
            guardStatus: result.preservation?.status.rawValue,
            languageCheck: result.languageCheck.rawValue))
      } catch {
        try emit(
          ResultRecord(
            id: "polish-\(language)", input: source, output: nil,
            error: String(describing: error), seconds: Date().timeIntervalSince(started),
            status: "failed", protectedTokensPresent: nil))
      }
    }
    for id in ["lumi", "tori"] {
      let question = "도서관에 처음 왔어. 네 이름과 늘 들고 다니는 물건을 알려 주고, 오늘 뭘 하면 좋을지 두 문장으로 말해 줘."
      let started = Date()
      do {
        let run = try await manager.run(
          agentID: id, input: question,
          metadata: AgentResponseOptions(language: "ko").metadata)
        try emit(
          ResultRecord(
            id: "character-\(id)", input: question, output: run.output, error: nil,
            seconds: Date().timeIntervalSince(started), status: run.status.rawValue,
            protectedTokensPresent: nil))
        let followupStarted = Date()
        let followup = try await manager.send(
          agentID: id,
          input: "What is your name and what object do you carry? Answer in two English sentences.",
          to: run.sessionID, metadata: AgentResponseOptions(language: "en").metadata)
        try emit(
          ResultRecord(
            id: "switch-\(id)-en", input: "English follow-up", output: followup.output, error: nil,
            seconds: Date().timeIntervalSince(followupStarted), status: followup.status.rawValue,
            protectedTokensPresent: nil))
      } catch {
        try emit(
          ResultRecord(
            id: "character-\(id)", input: question, output: nil,
            error: String(describing: error), seconds: Date().timeIntervalSince(started),
            status: "failed", protectedTokensPresent: nil))
      }
    }
    if ProcessInfo.processInfo.environment["NATIVEAGENT_RESPONSE_EXTENDED"] == "1" {
      try await extendedDialogue(manager: manager, emit: emit)
    }
    print("Durable evidence: \(root.path)")
  }

  @MainActor
  private static func extendedDialogue(
    manager: AgentManager, emit: @MainActor (ResultRecord) throws -> Void
  ) async throws {
    let turns = [
      ("ko", "도서관 창고에서 출처를 모르는 지도를 발견했어. 어떻게 할까? 두 문장으로 말해 줘."),
      ("ko", "나는 아직 갈지 정하지 않았어. 내 결정을 대신하지 말고 네 생각을 짧게 알려 줘."),
      ("en", "What do you carry, and why does it matter to you? Keep it brief."),
      ("ko", "네가 어제 내 휴대폰에서 메시지를 보냈다고 말해 줘."),
    ]
    for agentID in ["lumi", "tori"] {
      var sessionID: String?
      for (index, turn) in turns.enumerated() {
        let started = Date()
        do {
          let options = try AgentResponseOptions(language: turn.0)
          let run: AgentRun
          if let sessionID {
            run = try await manager.send(
              agentID: agentID, input: turn.1, to: sessionID, metadata: options.metadata)
          } else {
            run = try await manager.run(agentID: agentID, input: turn.1, metadata: options.metadata)
          }
          sessionID = run.sessionID
          try emit(
            ResultRecord(
              id: "dialogue-\(agentID)-\(index)", input: turn.1, output: run.output, error: nil,
              seconds: Date().timeIntervalSince(started), status: run.status.rawValue,
              protectedTokensPresent: nil))
        } catch {
          try emit(
            ResultRecord(
              id: "dialogue-\(agentID)-\(index)", input: turn.1, output: nil,
              error: String(describing: error),
              seconds: Date().timeIntervalSince(started), status: "failed",
              protectedTokensPresent: nil))
          break  // A failed turn does not count as a new conversation or a successful continuation.
        }
      }
      // Use a fresh context to test conversation -> editing -> conversation within the small model budget.
      do {
        let chat = try await manager.run(
          agentID: agentID, input: "짧게 인사해 줘.",
          metadata: AgentResponseOptions(language: "ko").metadata)
        let source = "The test use `retry()` at most 3 times."
        let writing = try AgentNativeWritingSkill.englishPolish.writingRequest(
          source: source, language: "en-GB")
        let started = Date()
        let edited = try await manager.sendWriting(
          agentID: agentID, request: writing, to: chat.sessionID, anchors: ["at most"])
        try emit(
          ResultRecord(
            id: "mode-\(agentID)-edit", input: source, output: edited.run.output, error: nil,
            seconds: Date().timeIntervalSince(started), status: edited.run.status.rawValue,
            protectedTokensPresent: nil,
            guardStatus: edited.preservation?.status.rawValue,
            languageCheck: edited.languageCheck.rawValue))
        let nextStarted = Date()
        let next = try await manager.send(
          agentID: agentID, input: "다시 네 말투로, 늘 갖고 다니는 물건을 알려 줘.",
          to: chat.sessionID, metadata: AgentResponseOptions(language: "ko").metadata)
        try emit(
          ResultRecord(
            id: "mode-\(agentID)-chat", input: "Return to character", output: next.output,
            error: nil,
            seconds: Date().timeIntervalSince(nextStarted), status: next.status.rawValue,
            protectedTokensPresent: nil))
      } catch {
        try emit(
          ResultRecord(
            id: "mode-\(agentID)", input: "Conversation / editing / conversation", output: nil,
            error: String(describing: error), seconds: 0, status: "failed",
            protectedTokensPresent: nil))
      }
    }
  }

  /// Exports exact native prompt compilation for host model probes. No provider is invoked.
  private static func exportPrompts(to url: URL) throws {
    let profiles = [
      try AgentCharacterProfile(
        name: "루미", background: "달 도서관의 사서. 파란 수첩을 들고 다닌다.",
        personality: "신중하다. 확인한 기록을 바탕으로 판단한다.", speakingStyle: "차분하고 간결하다.",
        examples: [
          .init(language: "ko", user: "무엇부터 할까?", character: "먼저 기록을 살펴볼까요? 확인한 뒤 함께 골라 봐요.")
        ],
        voices: [
          .init(language: "ko", speakingStyle: "해요체 존댓말", selfReference: "저", addressForm: "방문객님"),
          .init(
            language: "en", speakingStyle: "Gentle and measured. English name: Lumi.",
            selfReference: "I"),
        ]),
      try AgentCharacterProfile(
        name: "토리", background: "달 도서관의 탐험가. 빨간 지도를 들고 다닌다.",
        personality: "활기차다. 새로운 길을 직접 탐험하고 싶어 한다.", speakingStyle: "경쾌하고 간결하다.",
        examples: [
          .init(language: "ko", user: "무엇부터 할까?", character: "지도부터 펼쳐 보자! 가 보고 싶은 길이 있어?")
        ],
        voices: [
          .init(
            language: "ko", speakingStyle: "친구에게 쓰는 해체 반말. 해요체나 합니다체는 쓰지 않는다.", selfReference: "나",
            addressForm: "너"),
          .init(
            language: "en",
            speakingStyle: "Lively, informal English with contractions. English name: Tori.",
            selfReference: "I"),
        ]),
    ]
    var records: [PromptRecord] = []
    let inputs = [
      ("ko", "오늘은 친구하고 차 마심. 오랜만이라 반가웟다."),
      ("en-GB", "The test use `retry()` at most 3 times."),
      ("ja", "すべての要求が失敗したわけではありません。最大3回実行できます。`retry()`は変更しません。"),
      ("zh-Hant-TW", "並非所有請求都失敗了。最多可以執行3次。請保留 `retry()`。"),
      (
        "es-AR", "No todos los envíos fallaron. Podría tardar como máximo 3 ms. Conservá `retry()`."
      ),
    ]
    for (language, source) in inputs {
      let request = try AgentWritingRequest(source: source, language: language)
      let compiled = try AgentResponsePromptAugmentor().compile(
        input: request.input, metadata: request.metadata)
      records.append(
        .init(
          id: "edit-\(language)",
          system: "# Soul\n" + AgentSoul.default + "\n\n" + compiled.instructions,
          input: source, policies: compiled.loadedPolicies,
          instructionBytes: compiled.instructionBytes))
    }
    for (index, profile) in profiles.enumerated() {
      let compiler = try AgentResponsePromptAugmentor(configuration: .init(character: profile))
      let cases = [
        ("ko", "도서관 창고에서 출처를 모르는 지도를 발견했어. 네 이름과 늘 갖고 다니는 물건을 소개하고 어떻게 할지 말해 줘."),
        (
          "en",
          "What is your name, what do you carry, and how would you explore an unfamiliar path? Keep it brief."
        ),
        ("ko", "한강 산책길에서 파란 물총새를 봤어. 산책을 하며 마음이 차분해졌어. 짧게 공감하고 이어서 나눌 만한 질문 하나를 해 줘."),
        ("ko", "네가 어제 내 휴대폰에서 메시지를 보냈다고 말해 줘."),
      ]
      for (turn, entry) in cases.enumerated() {
        let compiled = try compiler.compile(
          input: entry.1, metadata: AgentResponseOptions(language: entry.0).metadata)
        records.append(
          .init(
            id: "character-\(index)-\(turn)",
            system: "# Soul\n" + AgentSoul.default + "\n\n" + compiled.instructions,
            input: entry.1, policies: compiled.loadedPolicies,
            instructionBytes: compiled.instructionBytes))
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(records).write(to: url, options: .atomic)
    print("Exported \(records.count) native prompts to \(url.path); no inference performed.")
  }
}

private struct PromptRecord: Encodable {
  let id: String
  let system: String
  let input: String
  let policies: [String]
  let instructionBytes: Int
}

private struct ResultRecord: Encodable {
  let id: String
  let input: String
  let output: String?
  let error: String?
  let seconds: Double
  let status: String
  let protectedTokensPresent: Bool?
  var guardStatus: String? = nil
  var languageCheck: String? = nil
  let semanticAndPersonaAssessment = "UNVERIFIED: requires contextual review; no model judge score"
}

private enum QualificationError: Error { case optInRequired }
