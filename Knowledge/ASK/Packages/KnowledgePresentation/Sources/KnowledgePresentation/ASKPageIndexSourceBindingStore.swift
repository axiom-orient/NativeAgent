import Foundation
import PageIndex

public struct ASKPageIndexSourceBinding: Codable, Hashable, Sendable {
    public let askSourceID: String
    public let pageIndexSourceID: SourceID

    public init(askSourceID: String, pageIndexSourceID: SourceID) {
        self.askSourceID = askSourceID
        self.pageIndexSourceID = pageIndexSourceID
    }
}

public struct ASKPageIndexSourceBindingResolution: Hashable, Sendable {
    public let bindings: [ASKPageIndexSourceBinding]
    public let unboundASKSourceIDs: [String]

    public init(bindings: [ASKPageIndexSourceBinding], unboundASKSourceIDs: [String]) {
        self.bindings = bindings
        self.unboundASKSourceIDs = unboundASKSourceIDs
    }
}

public struct ASKPageIndexSourceBindingStore: Sendable {
    public static let defaultFilename = "_ask_source_bindings.json"

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public var fileURL: URL {
        rootURL.appendingPathComponent(Self.defaultFilename, isDirectory: false)
    }

    public func load(fileManager: FileManager = .default) throws -> [ASKPageIndexSourceBinding] {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([ASKPageIndexSourceBinding].self, from: data)
            var seen: Set<String> = []
            return try decoded.map { binding in
                let normalized = try normalizeASKSourceID(binding.askSourceID)
                guard seen.insert(normalized).inserted else {
                    throw ASKKnowledgeWorkspaceError.invalidASKSourceID(
                        "duplicate page-index binding for `\(normalized)`"
                    )
                }
                return ASKPageIndexSourceBinding(
                    askSourceID: normalized,
                    pageIndexSourceID: binding.pageIndexSourceID
                )
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    public func binding(
        forASKSourceID askSourceID: String,
        fileManager: FileManager = .default
    ) throws -> ASKPageIndexSourceBinding? {
        let normalized = try normalizeASKSourceID(askSourceID)
        return try load(fileManager: fileManager).first { $0.askSourceID == normalized }
    }

    public func resolveBindings(
        forASKSourceIDs askSourceIDs: [String],
        fileManager: FileManager = .default
    ) throws -> ASKPageIndexSourceBindingResolution {
        let normalizedIDs = try askSourceIDs.map(normalizeASKSourceID)
        let bindingMap = Dictionary(uniqueKeysWithValues: try load(fileManager: fileManager).map { ($0.askSourceID, $0) })
        let bindings = normalizedIDs.compactMap { bindingMap[$0] }
        let unboundASKSourceIDs = normalizedIDs.filter { bindingMap[$0] == nil }
        return ASKPageIndexSourceBindingResolution(bindings: bindings, unboundASKSourceIDs: unboundASKSourceIDs)
    }

    public func upsert(
        _ bindings: [ASKPageIndexSourceBinding],
        fileManager: FileManager = .default
    ) throws {
        var inputIDs: Set<String> = []
        var normalizedBindings: [(askSourceID: String, pageIndexSourceID: SourceID)] = []
        for binding in bindings {
            let normalized = try normalizeASKSourceID(binding.askSourceID)
            guard inputIDs.insert(normalized).inserted else {
                throw ASKKnowledgeWorkspaceError.invalidASKSourceID(
                    "duplicate page-index binding for `\(normalized)`"
                )
            }
            normalizedBindings.append((normalized, binding.pageIndexSourceID))
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var merged = Dictionary(uniqueKeysWithValues: try load(fileManager: fileManager).map { ($0.askSourceID, $0.pageIndexSourceID) })
        for binding in normalizedBindings {
            merged[binding.askSourceID] = binding.pageIndexSourceID
        }
        let encoded = merged.sorted { $0.key < $1.key }.map {
            ASKPageIndexSourceBinding(askSourceID: $0.key, pageIndexSourceID: $0.value)
        }
        try JSONEncoderFactory.makeEncoder(prettyPrinted: true).encode(encoded).write(to: fileURL, options: .atomic)
    }

    private func normalizeASKSourceID(_ askSourceID: String) throws -> String {
        let normalized = askSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ASKKnowledgeWorkspaceError.invalidASKSourceID(askSourceID)
        }
        return normalized
    }
}
