import Foundation
import NativeAgentDomain

private struct ToolCatalogManifest: Codable, Sendable, Equatable {
    var entries: [ToolCatalogManifestEntry]
}

private struct ToolCatalogManifestEntry: Codable, Sendable, Equatable {
    var packID: String
    var definition: ToolDefinition
    var metadata: [String: JSONValue]
}

public struct HostSuppliedToolCatalogSource: ToolCatalogSource {
    private let entriesProvider: @Sendable () async throws -> [ToolCatalogEntry]

    public init(entries: [ToolCatalogEntry]) {
        self.entriesProvider = { entries }
    }

    public init(
        entriesProvider: @escaping @Sendable () async throws -> [ToolCatalogEntry]
    ) {
        self.entriesProvider = entriesProvider
    }

    public func loadEntries() async throws -> [ToolCatalogEntry] {
        try await entriesProvider()
    }
}

public struct ToolPackCatalogSource: ToolCatalogSource {
    public let source: ToolCatalogSourceDescriptor
    private let toolPacks: [any ToolPack]

    public init(
        toolPacks: [any ToolPack],
        sourceID: String = "host.toolPacks"
    ) {
        self.source = ToolCatalogSourceDescriptor(kind: .hostSupplied, identifier: sourceID)
        self.toolPacks = toolPacks
    }

    public func loadEntries() async throws -> [ToolCatalogEntry] {
        toolPacks.flatMap { pack in
            pack.executors().map { executor in
                ToolCatalogEntry(
                    packID: pack.packID,
                    definition: executor.definition,
                    source: source
                )
            }
        }
    }
}

public struct ManifestToolCatalogSource: ToolCatalogSource {
    public let manifestURL: URL
    public let source: ToolCatalogSourceDescriptor

    public init(
        manifestURL: URL,
        source: ToolCatalogSourceDescriptor
    ) {
        self.manifestURL = manifestURL.standardizedFileURL
        self.source = source
    }

    public static func bundledManifest(
        resourceName: String,
        bundle: Bundle = .main,
        subdirectory: String? = nil
    ) throws -> ManifestToolCatalogSource {
        let name = (resourceName as NSString).deletingPathExtension
        let ext = (resourceName as NSString).pathExtension.isEmpty ? "json" : (resourceName as NSString).pathExtension
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) else {
            throw AgentError.notFound("Bundled tool catalog manifest not found: \(resourceName)")
        }
        return ManifestToolCatalogSource(
            manifestURL: url,
            source: ToolCatalogSourceDescriptor(kind: .bundledManifest, identifier: url.lastPathComponent)
        )
    }

    public static func appGroupMetadata(
        appGroupIdentifier: String,
        containerURL: URL? = nil,
        relativePath: String = "ToolCatalog/catalog.json",
        fileManager: FileManager = .default
    ) throws -> ManifestToolCatalogSource {
        let baseURL: URL
        if let containerURL {
            baseURL = containerURL.standardizedFileURL
        } else {
            #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            guard let resolved = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
                throw AgentError.persistenceFailure("App Group container is unavailable for \(appGroupIdentifier)")
            }
            baseURL = resolved.standardizedFileURL
            #else
            throw AgentError.unsupportedSurface("App Group metadata requires an explicit container URL on this platform")
            #endif
        }

        return ManifestToolCatalogSource(
            manifestURL: baseURL.appendingPathComponent(relativePath, isDirectory: false),
            source: ToolCatalogSourceDescriptor(kind: .appGroupMetadata, identifier: appGroupIdentifier)
        )
    }

    public func loadEntries() async throws -> [ToolCatalogEntry] {
        let data = try ToolPackBoundedFileReader.read(
            from: manifestURL,
            maximumByteCount: 4 * 1_024 * 1_024,
            label: "Tool catalog manifest"
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ToolCatalogManifest.self, from: data)
        return manifest.entries.map { entry in
            ToolCatalogEntry(
                packID: entry.packID,
                definition: entry.definition,
                source: source,
                metadata: entry.metadata
            )
        }
    }
}

public struct CompositeToolCatalogSource: ToolCatalogSource {
    private let sources: [any ToolCatalogSource]

    public init(sources: [any ToolCatalogSource]) {
        self.sources = sources
    }

    public func loadEntries() async throws -> [ToolCatalogEntry] {
        var seenNames: Set<String> = []
        var entries: [ToolCatalogEntry] = []

        for source in sources {
            for entry in try await source.loadEntries() {
                guard seenNames.insert(entry.definition.name).inserted else {
                    throw AgentError.invariantViolation("Duplicate tool catalog entry: \(entry.definition.name)")
                }
                entries.append(entry)
            }
        }

        return entries.sorted { $0.definition.name < $1.definition.name }
    }
}


extension AppIntentsToolPack: ToolCatalogSource {
    public func loadEntries() async throws -> [ToolCatalogEntry] {
        try await ToolPackCatalogSource(toolPacks: [self], sourceID: "host.appIntents").loadEntries()
    }
}
