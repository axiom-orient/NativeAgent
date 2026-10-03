import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentTools

private struct CatalogToolPack: ToolPack {
    let packID = "toolpack.catalog"

    func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(
                definition: ToolDefinition(
                    name: "catalog.echo",
                    description: "Echo catalog input.",
                    capabilityID: .files,
                    inputSchema: ToolSchema.object(properties: [:]),
                    approvalPolicy: .automatic,
                    effect: .readOnly
                )
            ) { call, _ in
                .text(callID: call.id, toolName: call.name, content: "ok")
            }
        ]
    }
}

private func makeCatalogManifestURL(_ directory: URL, filename: String = "catalog.json") throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(filename, isDirectory: false)
    let manifest: [String: Any] = [
        "entries": [
            [
                "packID": "manifest.pack",
                "definition": [
                    "name": "manifest.echo",
                    "description": "Manifest declared tool.",
                    "capabilityID": CapabilityID.files.rawValue,
                    "inputSchema": ["type": "object", "properties": [:]],
                    "approvalPolicy": ApprovalPolicy.automatic.rawValue,
                    "effect": ToolEffectKind.readOnly.rawValue,
                    "metadata": [:]
                ],
                "metadata": ["origin": "manifest"]
            ]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    return url
}

@Test
func toolPackCatalogSourceExportsDefinitions() async throws {
    let source = ToolPackCatalogSource(toolPacks: [CatalogToolPack()], sourceID: "host.tests")
    let entries = try await source.loadEntries()

    #expect(entries.count == 1)
    #expect(entries.first?.packID == "toolpack.catalog")
    #expect(entries.first?.definition.name == "catalog.echo")
    #expect(entries.first?.source.kind == .hostSupplied)
    #expect(entries.first?.source.identifier == "host.tests")
}

@Test
func manifestToolCatalogSourceLoadsBundledStyleManifest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let manifestURL = try makeCatalogManifestURL(root)
    let source = ManifestToolCatalogSource(
        manifestURL: manifestURL,
        source: ToolCatalogSourceDescriptor(kind: .bundledManifest, identifier: "catalog.json")
    )

    let entries = try await source.loadEntries()

    #expect(entries.count == 1)
    #expect(entries.first?.definition.name == "manifest.echo")
    #expect(entries.first?.source.kind == .bundledManifest)
    #expect(entries.first?.metadata["origin"]?.stringValue == "manifest")
}

@Test
func appGroupMetadataSourceResolvesExplicitContainerURL() async throws {
    let containerURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let manifestURL = try makeCatalogManifestURL(
        containerURL.appendingPathComponent("ToolCatalog", isDirectory: true)
    )

    let source = try ManifestToolCatalogSource.appGroupMetadata(
        appGroupIdentifier: "group.example.nativeagent",
        containerURL: containerURL,
        relativePath: "ToolCatalog/\(manifestURL.lastPathComponent)"
    )

    let entries = try await source.loadEntries()

    #expect(entries.first?.source.kind == .appGroupMetadata)
    #expect(entries.first?.source.identifier == "group.example.nativeagent")
    #expect(entries.first?.definition.name == "manifest.echo")
}

@Test
func compositeToolCatalogRejectsDuplicateToolNames() async throws {
    let entry = ToolCatalogEntry(
        packID: "host.pack",
        definition: ToolDefinition(
            name: "duplicate.echo",
            description: "duplicate",
            capabilityID: .files,
            inputSchema: ToolSchema.object(properties: [:]),
            approvalPolicy: .automatic
        ),
        source: ToolCatalogSourceDescriptor(kind: .hostSupplied, identifier: "host")
    )
    let composite = CompositeToolCatalogSource(
        sources: [
            HostSuppliedToolCatalogSource(entries: [entry]),
            HostSuppliedToolCatalogSource(entries: [entry])
        ]
    )

    do {
        _ = try await composite.loadEntries()
        Issue.record("Expected duplicate tool catalog entry failure")
    } catch let error as AgentError {
        guard case .invariantViolation(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message.contains("Duplicate tool catalog entry"))
    }
}
