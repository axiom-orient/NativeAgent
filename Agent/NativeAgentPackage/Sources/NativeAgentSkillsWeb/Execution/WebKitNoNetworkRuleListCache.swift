import NativeAgentDomain
import Foundation

#if canImport(WebKit)
import WebKit

@MainActor
enum WebKitNoNetworkRuleListCache {
    private static var cachedRuleList: WKContentRuleList?

    static func ruleList() async throws -> WKContentRuleList {
        if let cachedRuleList {
            return cachedRuleList
        }
        let ruleList = try await compileRuleList()
        cachedRuleList = ruleList
        return ruleList
    }

    private static func compileRuleList() async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: WebKitSkillScriptContract.noNetworkRuleIdentifier,
                encodedContentRuleList: noNetworkRulesJSON
            ) { ruleList, error in
                if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(
                        throwing: error
                            ?? AgentError.invariantViolation(
                                "Failed to compile the WebKit no-network policy"
                            )
                    )
                }
            }
        }
    }

    private static let noNetworkRulesJSON = """
    [
      {
        "trigger": {
          "url-filter": "https?://.*",
          "resource-type": [
            "document", "image", "style-sheet", "script", "font", "raw",
            "svg-document", "media", "popup"
          ]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": "wss?://.*",
          "resource-type": ["raw"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": "ftp://.*",
          "resource-type": [
            "document", "image", "style-sheet", "script", "font", "raw",
            "svg-document", "media", "popup"
          ]
        },
        "action": { "type": "block" }
      }
    ]
    """
}
#endif
