import Foundation
import NativeAgentDomain

struct SkillCustomTextPackage: Sendable {
    let name: String
    let description: String
    let instructions: String
    let requiresSecret: Bool
    let requiresSecretDescription: String
    let homepage: String
    let capabilityRequirements: SkillCapabilityRequirements
    let defaultSelected: Bool?
    let scripts: [String: String]
    let assets: [String: String]
    let binaryAssets: [String: Data]
}

struct SkillCustomTextPackageBuilder {
    let fileManager: FileManager
    let pathPolicy: SkillPathPolicy

    func write(
        _ package: SkillCustomTextPackage,
        to directoryURL: URL
    ) throws -> String {
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let markdown = SkillMarkdownParser.render(
            document: SkillMarkdownDocument(
                name: package.name,
                description: package.description.trimmingCharacters(in: .whitespacesAndNewlines),
                instructions: package.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                requiresSecret: package.requiresSecret,
                requiresSecretDescription: package.requiresSecretDescription.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                homepage: package.homepage.trimmingCharacters(in: .whitespacesAndNewlines),
                capabilityRequirements: package.capabilityRequirements,
                defaultSelected: package.defaultSelected
            )
        )
        try markdown.write(
            to: directoryURL.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try writeEntries(
            package.scripts,
            into: directoryURL,
            subdirectory: "scripts",
            kind: "script"
        ) { content, fileURL in
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        try writeEntries(
            package.assets,
            into: directoryURL,
            subdirectory: "assets",
            kind: "asset"
        ) { content, fileURL in
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        try writeEntries(
            package.binaryAssets,
            into: directoryURL,
            subdirectory: "assets",
            kind: "asset"
        ) { data, fileURL in
            try data.write(to: fileURL, options: .atomic)
        }
        return markdown
    }

    private func writeEntries<Value>(
        _ entries: [String: Value],
        into directoryURL: URL,
        subdirectory: String,
        kind: String,
        writeValue: (Value, URL) throws -> Void
    ) throws {
        guard !entries.isEmpty else { return }
        let rootURL = directoryURL.appendingPathComponent(subdirectory, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for relativeName in entries.keys.sorted() {
            guard let value = entries[relativeName] else { continue }
            let sanitizedName = try pathPolicy.sanitizeRelativeSkillPath(relativeName, kind: kind)
            let fileURL = try pathPolicy.validatedChildURL(named: sanitizedName, within: rootURL)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeValue(value, fileURL)
        }
    }
}
