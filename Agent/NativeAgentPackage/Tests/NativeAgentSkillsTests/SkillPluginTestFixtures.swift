import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

func skillMarkdown(name: String, description: String) -> String {
    """
    ---
    name: \(name)
    description: \(description)
    ---

    Use run_js when needed.
    """
}

func writeSkillPlugin(
    root: URL,
    manifest: SkillPluginManifest,
    skills: [String: (markdown: String, scripts: [String: String])]
) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let manifestData = try JSONEncoder.nativeAgent().encode(manifest)
    try manifestData.write(to: root.appendingPathComponent("native-agent-skill-plugin.json"), options: .atomic)

    for (relativePath, skill) in skills {
        let skillURL = root.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: skillURL, withIntermediateDirectories: true)
        try skill.markdown.write(
            to: skillURL.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        if !skill.scripts.isEmpty {
            let scriptsRoot = skillURL.appendingPathComponent("scripts", isDirectory: true)
            try fileManager.createDirectory(at: scriptsRoot, withIntermediateDirectories: true)
            for (name, content) in skill.scripts {
                let scriptURL = scriptsRoot.appendingPathComponent(name, isDirectory: false)
                try fileManager.createDirectory(
                    at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: scriptURL, atomically: true, encoding: .utf8)
            }
        }
    }
}

func remotePluginPackage(
    sourceLocation: String,
    relativePath: String,
    manifest: SkillPluginManifest,
    skills: [String: String]
) throws -> RemoteSkillPluginPackage {
    var files = [
        RemoteSkillPackageFile(
            relativePath: "native-agent-skill-plugin.json",
            data: try JSONEncoder.nativeAgent().encode(manifest)
        )
    ]
    for (path, markdown) in skills {
        files.append(
            RemoteSkillPackageFile(
                relativePath: "\(path)/SKILL.md",
                data: Data(markdown.utf8)
            )
        )
    }
    return RemoteSkillPluginPackage(
        sourceLocation: sourceLocation,
        relativePath: relativePath,
        files: files
    )
}

func githubContentFileJSON(name: String, path: String, downloadURL: String) -> Data {
    Data(
        """
        {
          "name": "\(name)",
          "path": "\(path)",
          "type": "file",
          "download_url": "\(downloadURL)"
        }
        """.utf8)
}

func githubContentDirectoryJSON(
    entries: [(name: String, path: String, type: String, downloadURL: String?)]
) -> Data {
    let objects = entries.map { entry in
        let downloadURL = entry.downloadURL.map { #","download_url":"\#($0)""# } ?? ""
        return
            #"{"name":"\#(entry.name)","path":"\#(entry.path)","type":"\#(entry.type)"\#(downloadURL)}"#
    }
    return Data("[\(objects.joined(separator: ","))]".utf8)
}

func addGitHubPluginResponses(
    to responses: inout [String: (status: Int, data: Data)],
    treeEntries: inout [(path: String, type: String)],
    pluginPath: String,
    skillName: String,
    skillDescription: String
) {
    let manifestPath = "\(pluginPath)/native-agent-skill-plugin.json"
    let skillMarkdownPath = "\(pluginPath)/skills/\(skillName)/SKILL.md"
    let manifestURL =
        "https://raw.githubusercontent.com/AxiomOrient/skillsPlugin/main/\(manifestPath)"
    let skillURL =
        "https://raw.githubusercontent.com/AxiomOrient/skillsPlugin/main/\(skillMarkdownPath)"
    treeEntries.append((manifestPath, "blob"))
    treeEntries.append((skillMarkdownPath, "blob"))
    responses["https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/\(pluginPath)"] = (
        200,
        githubContentDirectoryJSON(entries: [
            ("native-agent-skill-plugin.json", "\(pluginPath)/native-agent-skill-plugin.json", "file", manifestURL),
            ("skills", "\(pluginPath)/skills", "dir", nil),
        ])
    )
    responses[
        "https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/\(pluginPath)?ref=main"] =
        responses["https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/\(pluginPath)"]
    responses["https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/\(pluginPath)/skills"] =
        (
            200,
            githubContentDirectoryJSON(entries: [
                (skillName, "\(pluginPath)/skills/\(skillName)", "dir", nil)
            ])
        )
    responses[
        "https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/\(pluginPath)/skills?ref=main"] =
        responses["https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/\(pluginPath)/skills"]
    responses[
        "https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/\(pluginPath)/skills/\(skillName)"
    ] = (
        200,
        githubContentDirectoryJSON(entries: [
            ("SKILL.md", "\(pluginPath)/skills/\(skillName)/SKILL.md", "file", skillURL)
        ])
    )
    responses[
        "https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/\(pluginPath)/skills/\(skillName)?ref=main"
    ] =
        responses[
            "https://api.github.com/repos/AxiomOrient/skillsPlugin/contents/\(pluginPath)/skills/\(skillName)"
        ]
    responses[manifestURL] = (
        200,
        Data(
            """
            {
              "schemaVersion": "\(SkillPluginManifest.supportedSchemaVersion)",
              "id": "io.axiomorient.nativeagent.\(skillName)",
              "name": "\(skillName)",
              "version": "0.1.0",
              "description": "\(skillDescription)",
              "skills": [
                {"path": "skills/\(skillName)"}
              ]
            }
            """.utf8)
    )
    responses[skillURL] = (
        200,
        Data(
            """
            ---
            name: \(skillName)
            description: \(skillDescription)
            ---

            Call `run_intent` from NativeAgent.
            """.utf8)
    )
}

func githubTreeJSON(entries: [(path: String, type: String)]) -> Data {
    let objects = entries.map { entry in
        #"{"path":"\#(entry.path)","type":"\#(entry.type)"}"#
    }
    return Data(
        """
        {
          "tree": [\(objects.joined(separator: ","))],
          "truncated": false
        }
        """.utf8)
}

enum SupportingFileFixtureError: Error {
    case unavailable
}
