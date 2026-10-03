import Foundation
import NativeAgent

/// First-party iOS writing skills. They compile bundled instructions and use Swift validation;
/// they do not import desktop SKILL.md runners or depend on provider tool-call support.
public enum AgentNativeWritingSkill: String, CaseIterable, Sendable {
  case fluentKorean = "fluent-korean"
  case koreanize
  case englishPolish = "english-polish"
  case japanesePolish = "japanese-polish"
  case chinesePolish = "chinese-polish"
  case spanishPolish = "spanish-polish"

  public var language: AgentResponseLanguage {
    switch self {
    case .fluentKorean, .koreanize: .korean
    case .englishPolish: .english
    case .japanesePolish: .japanese
    case .chinesePolish: .chinese
    case .spanishPolish: .spanish
    }
  }

  public static func available(for identifier: String) throws -> [Self] {
    let language = try AgentResponseLanguage(identifier: identifier)
    return allCases.filter { $0.language == language }
  }

  public func writingRequest(
    source: String, mode: AgentResponseOptions.Mode = .polish,
    candidates: [String] = [], target: String? = nil, language identifier: String? = nil
  ) throws -> AgentWritingRequest {
    guard self != .fluentKorean else { throw AgentResponseError.invalidRequest }
    if let identifier, try AgentResponseLanguage(identifier: identifier) != language {
      throw AgentResponseError.invalidRequest
    }
    return try AgentWritingRequest(
      source: source, mode: mode, language: identifier ?? language.rawValue, candidates: candidates,
      target: target)
  }
}

public struct AgentWritingResult: Sendable {
  /// The provider result is preserved, including malformed output. The guard never rewrites it.
  public let run: AgentRun
  /// Nil for choose: selecting expressions is not a whole-source preservation comparison.
  public let preservation: AgentProseGuard.Report?
  /// Conservative dominant-language comparison; mixed/short text can remain unknown.
  public let languageCheck: LanguageCheck

  public enum LanguageCheck: String, Sendable {
    case consistent, different, unknown
  }
}

extension AgentManager {
  /// Executes a native editorial skill and checks the returned text locally in Swift.
  /// A completed run plus a failed/unsupported guard is not an accepted edit.
  public func runWriting(
    agentID: String, request: AgentWritingRequest, sessionID: String? = nil,
    anchors: [String] = []
  ) async throws -> AgentWritingResult {
    try validateGuardInput(request: request, anchors: anchors)
    let run = try await run(
      agentID: agentID, input: request.input,
      sessionID: sessionID, metadata: request.metadata)
    return writingResult(run: run, request: request, anchors: anchors)
  }

  public func sendWriting(
    agentID: String, request: AgentWritingRequest, to sessionID: String,
    anchors: [String] = []
  ) async throws -> AgentWritingResult {
    try validateGuardInput(request: request, anchors: anchors)
    let run = try await send(
      agentID: agentID, input: request.input,
      to: sessionID, metadata: request.metadata)
    return writingResult(run: run, request: request, anchors: anchors)
  }

  private func writingResult(run: AgentRun, request: AgentWritingRequest, anchors: [String])
    -> AgentWritingResult
  {
    let report: AgentProseGuard.Report?
    if request.mode == .choose {
      report = nil
    } else {
      report = AgentProseGuard.compare(
        source: request.source, candidate: run.output ?? "", anchors: anchors)
    }
    let expected = request.language ?? AgentResponseLanguage.detectIdentifier(request.source)
    let actual = run.output.flatMap(AgentResponseLanguage.detectIdentifier)
    let languageCheck: AgentWritingResult.LanguageCheck
    if let expected, let actual {
      let expectedBase = expected.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        .first?.lowercased()
      let actualBase = actual.split(separator: "-").first?.lowercased()
      languageCheck = expectedBase == actualBase ? .consistent : .different
    } else {
      languageCheck = .unknown
    }
    return AgentWritingResult(run: run, preservation: report, languageCheck: languageCheck)
  }

  private func validateGuardInput(request: AgentWritingRequest, anchors: [String]) throws {
    if request.mode == .choose {
      guard anchors.isEmpty else { throw AgentResponseError.invalidRequest }
      return
    }
    let baseline = AgentProseGuard.compare(
      source: request.source, candidate: request.source, anchors: anchors)
    guard baseline.status != .inputError else { throw AgentResponseError.invalidRequest }
  }
}
