import ASK
import Foundation
import FoundationModels
import Testing

@testable import ASKFoundationModels

/// Creates a small indexed workspace through the public facade so tool calls
/// run against real committed state instead of mocks.
private func makeIndexedWorkspace() async throws -> URL {
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("ask-fm-tests-\(UUID().uuidString)", isDirectory: true)
    let sourceRoot = workspace.deletingLastPathComponent()
        .appendingPathComponent("ask-fm-sources-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    for index in 0..<3 {
        let file = sourceRoot.appendingPathComponent("note-\(index).md")
        try Data("""
        # Note \(index): spaced repetition checkpoint

        The quarterly review checkpoint for subject \(index) explains how memory
        retention decays and why spaced repetition schedules reviews.
        The review interval is \(7 + index * 4) days. This is not a deadline.
        """.utf8).write(to: file)
    }

    let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
    let plan = try client.plan(.importWorkspace(ASKImportWorkspaceCommand(
        sourceRootURL: sourceRoot,
        title: "FM tool fixtures",
        queryText: "spaced repetition checkpoint",
        requestedAt: "2026-08-24T00:00:00Z",
        resetExistingWorkspace: true
    )))
    _ = try client.dryRun(plan)
    _ = try await client.apply(plan)
    return workspace
}

@Suite("ASK Foundation Models tools")
struct ASKFMToolTests {
    @Test func toolNamesAreUniqueAndContractNamed() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let names = [
            ASKEvidenceSearchTool.toolName,
            ASKEvidenceRetrieveTool.toolName,
            ASKKnowledgeSearchTool.toolName,
            ASKProjectionTool.toolName,
            ASKPendingWorkTool.toolName,
            ASKPendingPatchTool.toolName,
        ]
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.isEmpty })
    }

    @Test func evidenceSearchToolReturnsTitledExcerpts() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let workspace = try await makeIndexedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let suite = ASKFoundationModelsToolSuite(configuration: ASKConfiguration(workspaceURL: workspace))
        let tool = try #require(suite.tools.compactMap { $0 as? ASKEvidenceSearchTool }.first)
        let arguments = try GeneratedContent(json: #"{"text":"spaced repetition","limit":5}"#)
        let output = try await tool.call(arguments: ASKEvidenceSearchTool.Arguments(arguments))

        #expect(output.contains("Note 0"))
        #expect(output.contains("spaced repetition"))
    }

    @Test func evidenceSearchClampsLimitToContractBounds() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let workspace = try await makeIndexedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let suite = ASKFoundationModelsToolSuite(configuration: ASKConfiguration(workspaceURL: workspace))
        let tool = try #require(suite.tools.compactMap { $0 as? ASKEvidenceSearchTool }.first)
        let arguments = try GeneratedContent(json: #"{"text":"checkpoint","limit":999}"#)
        let output = try await tool.call(arguments: ASKEvidenceSearchTool.Arguments(arguments))

        #expect(output.contains("[1]"))
        #expect(output.split(separator: "\n\n").count <= 500)
    }

    @Test func knowledgeSearchAndPendingWorkRoundTrip() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let workspace = try await makeIndexedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let suite = ASKFoundationModelsToolSuite(configuration: ASKConfiguration(workspaceURL: workspace))
        let search = try #require(suite.tools.compactMap { $0 as? ASKKnowledgeSearchTool }.first)
        let searchArguments = try GeneratedContent(json: #"{"text":"checkpoint","limit":5}"#)
        let searchOutput = try await search.call(arguments: ASKKnowledgeSearchTool.Arguments(searchArguments))
        #expect(!searchOutput.isEmpty)
        guard case .knowledgeSearch(let knowledge) = try await suite.client.query(.searchKnowledge(ASKKnowledgeSearchQuery(text: "checkpoint", limit: 5))) else {
            Issue.record("Unexpected knowledge result")
            return
        }
        let slug = try #require(knowledge.items.compactMap(\.projectionSlug).first)
        #expect(searchOutput.contains("slug=\(slug)"))
        let projection = try #require(suite.tools.compactMap { $0 as? ASKProjectionTool }.first)
        let slugJSON = String(decoding: try JSONEncoder().encode(["slug": slug]), as: UTF8.self)
        let fullNote = try await projection.call(arguments: ASKProjectionTool.Arguments(try GeneratedContent(json: slugJSON)))
        #expect(fullNote.contains("spaced repetition"))
        let missing = try await projection.call(arguments: ASKProjectionTool.Arguments(try GeneratedContent(json: #"{"slug":"src_not_a_projection"}"#)))
        #expect(missing.hasPrefix("Error:"))
        #expect(missing.contains("search_knowledge"))

        let pending = try #require(suite.tools.compactMap { $0 as? ASKPendingWorkTool }.first)
        let pendingOutput = try await pending.call(
            arguments: ASKPendingWorkTool.Arguments(try GeneratedContent(json: #"{}"#))
        )
        #expect(pendingOutput.contains("committed") || pendingOutput.contains("pending"))
    }

    @Test func readOnlyPendingWorkAcceptsEmptyArguments() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let workspace = try await makeIndexedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let suite = ASKFoundationModelsToolSuite(configuration: ASKConfiguration(workspaceURL: workspace))
        let pending = try #require(suite.tools.compactMap { $0 as? ASKPendingWorkTool }.first)
        let output = try await pending.call(
            arguments: ASKPendingWorkTool.Arguments(try GeneratedContent(json: #"{}"#))
        )
        #expect(!output.isEmpty)
    }

    @Test func vectorlessRetrieveReturnsAddressableEvidence() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let workspace = try await makeIndexedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let suite = ASKFoundationModelsToolSuite(configuration: ASKConfiguration(workspaceURL: workspace))
        let retrieve = try #require(suite.tools.compactMap { $0 as? ASKEvidenceRetrieveTool }.first)
        let output = try await retrieve.call(arguments: ASKEvidenceRetrieveTool.Arguments(
            try GeneratedContent(json: #"{"question":"spaced repetition checkpoint"}"#)
        ))
        #expect(output.contains("source="))
        #expect(output.contains("node="))
        #expect(output.contains("range="))
    }

    @Test func sourceToolsRejectChangedOriginalInsteadOfAnsweringFromOldNumbers() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-fm-accuracy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("contract.md")
        try Data("# Contract approved\n\nThe approved invoice amount is 48271 won.".utf8).write(to: file)
        let suite = ASKFoundationModelsToolSuite(configuration: ASKConfiguration(workspaceURL: root.appendingPathComponent("workspace")))
        _ = try await suite.client.apply(try suite.client.plan(.importWorkspace(ASKImportWorkspaceCommand(
            sourceRootURL: source, title: "Contract verification", queryText: "invoice",
            requestedAt: "2026-09-12T10:00:00Z", resetExistingWorkspace: true
        ))))
        let search = try #require(suite.tools.compactMap { $0 as? ASKEvidenceSearchTool }.first)
        let retrieve = try #require(suite.tools.compactMap { $0 as? ASKEvidenceRetrieveTool }.first)
        let searchArgs = try ASKEvidenceSearchTool.Arguments(GeneratedContent(json: #"{"text":"invoice","limit":5}"#))
        let retrieveArgs = try ASKEvidenceRetrieveTool.Arguments(GeneratedContent(json: #"{"question":"invoice"}"#))
        #expect(try await search.call(arguments: searchArgs).contains("48271"))
        try Data("# Contract approved\n\nThe approved invoice amount is 84127 won.".utf8).write(to: file)
        let searchResult = try await search.call(arguments: searchArgs)
        let retrieveResult = try await retrieve.call(arguments: retrieveArgs)
        #expect(!searchResult.contains("48271") && !retrieveResult.contains("48271"))
        #expect(searchResult.contains("sourceStale") && retrieveResult.contains("sourceStale"))
        #expect(!searchResult.contains("84127") && !retrieveResult.contains("84127"), "Unindexed new content is not verified evidence either")
    }

    @Test func availabilityMappingCoversEveryReason() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let current = ASKFoundationModelAvailability.current()
        #expect(current.localizedDescription.isEmpty == false)
        #expect(ASKFoundationModelAvailability.deviceNotEligible.isUsable == false)
        #expect(ASKFoundationModelAvailability.available.isUsable == true)
    }
}

@Suite("ASK Foundation Models live", .serialized)
struct ASKFoundationModelsLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NATIVEAGENT_LIVE_FOUNDATION"] == "1"))
    func actualModelUsesIndexedNotes() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        try #require(ASKFoundationModelAvailability.current().isUsable)
        let workspace = try await makeIndexedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let session = try ASKFoundationModelsSessionFactory.makeSession(configuration: ASKConfiguration(workspaceURL: workspace))
        defer {
            for entry in session.transcript {
                switch entry {
                case .toolCalls(let calls):
                    for call in calls { print("LIVE_ASK_FM_CALL \(call.toolName) \(call.arguments)") }
                case .toolOutput(let output):
                    print("LIVE_ASK_FM_OUTPUT \(output.toolName) bytes=\(String(describing: output.segments).utf8.count)")
                default: break
                }
            }
        }
        let response = try await session.respond(to: "What review interval does Note 0 specify? Give the exact value and unit, explain it briefly, and cite the note title.", options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 256))
        try #require(!response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let calledSearch = session.transcript.contains { entry in
            if case .toolCalls(let calls) = entry { return calls.contains { $0.toolName == "search_evidence" } }
            return false
        }
        let returnedNote = session.transcript.contains { entry in
            guard case .toolOutput(let output) = entry, output.toolName == "search_evidence" else { return false }
            return output.segments.contains { segment in
                if case .text(let text) = segment { return text.content.contains("Note 0") && text.content.contains("7 days") }
                return false
            }
        }
        print("LIVE_ASK_FOUNDATION response=\(response.content)")
        try #require(calledSearch && returnedNote)
        #expect(response.content.range(of: #"(?i)\b(?:7|seven)\s+days?\b"#, options: .regularExpression) != nil)
        #expect(response.content.contains("Note 0"))
        #expect(!response.content.contains("src_") && !response.content.localizedCaseInsensitiveContains("couldn't find"))
        print("LIVE_ASK_FOUNDATION curated exact-value/unit/title oracle evaluated; not general semantic quality")
    }
}
