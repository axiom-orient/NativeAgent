import Foundation
import Testing
import KnowledgeCore
import KnowledgeRuntime
import SourceCapture

private func tempDir(_ prefix: String) throws -> URL {
    try SimulatorTestSupport.makeTemporaryDirectory(prefix)
}

private func sampleProjectionWrite(slug: String, title: String, body: String, kind: ProjectionKind, space: ProjectionSpace, authorityIDs: [String] = [], generatedAt: String = "2026-04-07T12:00:00Z") -> ProjectionWrite {
    let metadata = ProjectionMetadata(
        projectionKind: kind,
        projectionSpace: space,
        subjectKind: "project",
        subjectID: "swift-ios",
        authorityIDs: authorityIDs,
        sourceIDs: ["src_bridge"],
        claimIDs: [],
        historical: false,
        approvalRequired: space == .playbook
    )
    var document = ProjectionDocument(
        version: projectionDocumentVersion,
        slug: slug,
        title: title,
        bodyMD: body,
        metadata: metadata,
        generatedFromHash: "",
        generatedAt: generatedAt
    )
    document.generatedFromHash = projectionDocumentHash(document)
    return ProjectionWrite(slug: slug, state: .accepted, document: document)
}

@Test func searchToolRoundTripsJSON() async throws {
    let root = try tempDir("ask-bridge")
    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()
    let write = sampleProjectionWrite(slug: "wiki/current-swift-ios", title: "Current design", body: "Ask remains the truth owner.", kind: .currentSnapshot, space: .wiki, authorityIDs: ["auth_current"])
    let patch = try runtime.planProjectionRefresh(RefreshProjectionRequest(version: refreshProjectionRequestVersion, requestedAt: "2026-04-07T12:10:00Z", trigger: "seed", proposedWrites: [write]))
    let receipt = try runtime.buildReceipt(for: patch.patch, decision: .approved, decidedBy: "reviewer", decidedAt: "2026-04-07T12:11:00Z")
    _ = try runtime.apply(patch.patch, receipt)

    let bridge = ASKJSONToolExecutor(runtime: runtime)
    let json = try await bridge.execute(tool: "ask.search", argumentsJSON: #"{"query":"truth owner","limit":5}"#)
    let result = try CanonicalJSON.decoder().decode(SearchResult.self, from: Data(json.utf8))
    #expect(result.hits.first?.projectionSlug == "wiki/current-swift-ios")
}

@Test func queryToolReturnsFileBackPatchWithoutApplying() async throws {
    let root = try tempDir("ask-bridge-query")
    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()
    let playbook = sampleProjectionWrite(slug: "playbook/ask-design", title: "Ask design guidance", body: "Use a thin bridge and keep truth ownership in Ask.", kind: .playbookEntry, space: .playbook, authorityIDs: ["auth_current"])
    let patch = try runtime.planProjectionRefresh(RefreshProjectionRequest(version: refreshProjectionRequestVersion, requestedAt: "2026-04-07T12:20:00Z", trigger: "seed", proposedWrites: [playbook]))
    let receipt = try runtime.buildReceipt(for: patch.patch, decision: .approved, decidedBy: "reviewer", decidedAt: "2026-04-07T12:21:00Z")
    _ = try runtime.apply(patch.patch, receipt)

    let bridge = ASKJSONToolExecutor(runtime: runtime)
    let json = try await bridge.execute(tool: "ask.query", argumentsJSON: #"{"question":"How should I design the bridge?","requested_at":"2026-04-07T12:22:00Z","file_back_slug":"query/bridge"}"#)
    let result = try CanonicalJSON.decoder().decode(QueryResult.self, from: Data(json.utf8))
    #expect(result.fileBackPatch?.projectionWrites.first?.slug == "query/bridge")
    let state = try runtime.snapshot()
    #expect(state.visibleProjections["query/bridge"] == nil)
}

@Test func verifyToolReturnsVerificationReport() async throws {
    let root = try tempDir("ask-bridge-verify")
    let runtime = ASKRuntime(root: root)
    let write = sampleProjectionWrite(slug: "wiki/current-swift-ios", title: "Current design", body: "Ask remains the truth owner.", kind: .currentSnapshot, space: .wiki, authorityIDs: ["auth_current"])
    let patch = try runtime.planProjectionRefresh(RefreshProjectionRequest(version: refreshProjectionRequestVersion, requestedAt: "2026-04-07T12:30:00Z", trigger: "seed", proposedWrites: [write]))
    let payload = try CanonicalJSON.data(for: ["plan": patch.patch])
    let bridge = ASKJSONToolExecutor(runtime: runtime)
    let json = try await bridge.execute(tool: "ask.verify", argumentsJSON: String(decoding: payload, as: UTF8.self))
    let result = try CanonicalJSON.decoder().decode(VerificationReport.self, from: Data(json.utf8))
    #expect(result.patchID == patch.patch.patchID)
}

@Test func importCollectedToolCopiesStagedCaptureAndPreservesMetadata() async throws {
    let staging = try tempDir("ask-bridge-staging")
    let vault = try tempDir("ask-bridge-vault")
    let bundle = try WebCapture.captureHTMLText(
        "<html><head><title>Bridge Import</title></head><body><main><p>This capture should import through the JSON bridge with enough detail to make one fragment.</p></main></body></html>",
        pageURL: "https://example.com/bridge",
        sourceID: "src_bridge",
        observedAt: "2026-04-07T12:40:00Z",
        rawRelpath: defaultRawRelpath(sourceID: "src_bridge", observedAt: "2026-04-07T12:40:00Z")
    )
    let paths = try CaptureStager.stage(bundle, at: staging)
    let bridge = ASKJSONToolExecutor(root: vault)
    let escaped = paths.manifestPath.path
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let args = #"{"manifest_path":""# + escaped + #""}"#
    let json = try await bridge.execute(tool: "ask.import_collected", argumentsJSON: args)
    let result = try CanonicalJSON.decoder().decode(ASKImportedCapture.self, from: Data(json.utf8))
    #expect(result.sourceID == "src_bridge")
    #expect(result.rawRelpath == bundle.manifest.rawRelpath)
    #expect(result.contentHash == bundle.manifest.contentHash)
    #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent(bundle.manifest.rawRelpath).path))
}


@Test func contractListsCanonicalToolNames() async throws {
    let bridge = ASKJSONToolExecutor(root: try tempDir("ask-bridge-contract"))
    let json = try await bridge.execute(tool: "ask.contract")
    let contract = try CanonicalJSON.decoder().decode(ASKJSONBridgeContract.self, from: Data(json.utf8))
    #expect(contract.version == ASKJSONBridgeSchema.version)
    let expected = Set([
        "ask.contract",
        "ask.state.summary",
        "ask.search",
        "ask.read_projection",
        "ask.query",
        "ask.review_queue",
        "ask.pending_patches",
        "ask.read_patch",
        "ask.lint",
        "ask.import_collected",
        "ask.plan_evidence_ingest",
        "ask.verify",
    ])
    let names = contract.tools.map(\.name)
    #expect(Set(names) == expected)
    #expect(Set(names).count == names.count)
    #expect(!names.contains("ask.apply"))
    #expect(!names.contains("ask.rebuild"))
}

@Test func mutationToolsAreRejected() async throws {
    let bridge = ASKJSONToolExecutor(root: try tempDir("ask-bridge-policy"))
    do {
        _ = try await bridge.execute(tool: "ask.apply", argumentsJSON: "{}")
        Issue.record("ask.apply should not be exposed")
    } catch let error as ASKJSONBridgeError {
        #expect(error == .mutationDenied("ask.apply"))
    }
}

@Test func nonCanonicalAliasesAreRejected() async throws {
    let bridge = ASKJSONToolExecutor(root: try tempDir("ask-bridge-aliases"))
    for alias in ["ask.reviewQueue", "ask.importCollected", "ask.planEvidenceIngest"] {
        do {
            _ = try await bridge.execute(tool: alias, argumentsJSON: "{}")
            Issue.record("\(alias) must not bypass the canonical snake_case contract")
        } catch let error as ASKJSONBridgeError {
            #expect(error == .unknownTool(alias))
        }
    }
}

@Test func unknownArgumentsAreRejectedInsteadOfIgnored() async throws {
    let root = try tempDir("ask-bridge-extra-field")
    let bridge = ASKJSONToolExecutor(root: root)
    do {
        _ = try await bridge.execute(tool: "ask.state.summary", argumentsJSON: #"{"unexpected":true}"#)
        Issue.record("unknown arguments must not be ignored")
    } catch let error as ASKJSONBridgeError {
        #expect(error == .invalidArguments(
            tool: "ask.state.summary",
            reason: "unknown fields: unexpected"
        ))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func missingRequiredArgumentsUseOneExplicitFailure() async throws {
    let bridge = ASKJSONToolExecutor(root: try tempDir("ask-bridge-missing-field"))
    do {
        _ = try await bridge.execute(tool: "ask.search", argumentsJSON: "{}")
        Issue.record("missing query must be rejected")
    } catch let error as ASKJSONBridgeError {
        #expect(error == .invalidArguments(
            tool: "ask.search",
            reason: "missing required fields: query"
        ))
    }
}

@Test func nonObjectArgumentsUseOneExplicitFailure() async throws {
    let bridge = ASKJSONToolExecutor(root: try tempDir("ask-bridge-non-object"))
    do {
        _ = try await bridge.execute(tool: "ask.search", argumentsJSON: "[]")
        Issue.record("array arguments must be rejected")
    } catch let error as ASKJSONBridgeError {
        #expect(error == .invalidArguments(
            tool: "ask.search",
            reason: "arguments must be a JSON object"
        ))
    }
}


@Test func readProjectionToolReturnsProjectionDocument() async throws {
    let root = try tempDir("ask-bridge-read-projection")
    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()
    let write = sampleProjectionWrite(slug: "current/swift-ios", title: "Current design", body: "ASK remains the truth owner.", kind: .currentSnapshot, space: .wiki, authorityIDs: ["auth_current"])
    let patch = try runtime.planProjectionRefresh(RefreshProjectionRequest(version: refreshProjectionRequestVersion, requestedAt: "2026-04-10T12:50:00Z", trigger: "seed", proposedWrites: [write]))
    let receipt = try runtime.buildReceipt(for: patch.patch, decision: .approved, decidedBy: "reviewer", decidedAt: "2026-04-10T12:51:00Z")
    _ = try runtime.apply(patch.patch, receipt)

    let bridge = ASKJSONToolExecutor(runtime: runtime)
    let json = try await bridge.execute(tool: "ask.read_projection", argumentsJSON: #"{"slug":"current/swift-ios"}"#)
    let result = try CanonicalJSON.decoder().decode(ProjectionDocument?.self, from: Data(json.utf8))
    #expect(result?.slug == "current/swift-ios")
    #expect(result?.title == "Current design")
}

@Test func pendingPatchToolsExposeStagedPlan() async throws {
    let root = try tempDir("ask-bridge-pending-patch")
    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()

    let rawText = Data("Bridge pending patch".utf8)
    let rawRelpath = "raw/evidence/2026-04-11/src_bridge_pending.txt"
    let rawURL = root.appendingPathComponent(rawRelpath)
    try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rawText.write(to: rawURL)

    let collected = CollectedSource(
        sourceID: "src_bridge_pending",
        connector: "local-file-import",
        sourceKind: .file,
        title: "Bridge Pending",
        observedAt: "2026-04-11T18:00:00Z",
        capturedAt: "2026-04-11T18:00:00Z",
        rawRelpath: rawRelpath,
        contentHash: ASKSHA256.prefixedDigest(rawText),
        mimeType: "text/plain",
        language: "en",
        tags: ["pending"],
        metadata: [:],
        fragments: [
            CollectedFragment(
                fragmentID: "frag_bridge_pending_0",
                ordinal: 0,
                locator: [:],
                text: "Bridge pending patch",
                fingerprint: stableHash(["Bridge pending patch"])
            )
        ]
    )
    let request = try toIngestEvidenceRequest(collected, domain: "notes/bridge", requestedAt: "2026-04-11T18:01:00Z")
    let outcome = try runtime.planEvidenceIngest(request)
    try runtime.stage(outcome.patch)

    let bridge = ASKJSONToolExecutor(runtime: runtime)
    let pendingJSON = try await bridge.execute(tool: "ask.pending_patches", argumentsJSON: "{}")
    let pending = try CanonicalJSON.decoder().decode([KnowledgePatchPlan].self, from: Data(pendingJSON.utf8))
    #expect(pending.map(\.patchID).contains(outcome.patch.patchID))

    let readJSON = try await bridge.execute(tool: "ask.read_patch", argumentsJSON: #"{"patch_id":"\#(outcome.patch.patchID)"}"#)
    let loaded = try CanonicalJSON.decoder().decode(KnowledgePatchPlan?.self, from: Data(readJSON.utf8))
    #expect(loaded?.patchID == outcome.patch.patchID)
}
