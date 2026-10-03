import Foundation
import NativeAgentDomain

struct SkillRuntimeResultBuilder {
    private let artifacts = SkillRuntimeArtifacts()

    func missingSkillResult(
        callID: String,
        toolName: String,
        skillName: String,
        scriptName: String? = nil
    ) -> ToolResult {
        var metadata: [String: JSONValue] = ["skillName": .string(skillName)]
        if let scriptName {
            metadata["scriptName"] = .string(scriptName)
        }
        return ToolResult.text(
            callID: callID,
            toolName: toolName,
            content: "Skill not found or not selected: \(skillName)",
            isError: true,
            metadata: metadata
        )
    }

    func loadSkillResult(
        skill: ManagedSkill,
        supportingFiles: [SkillSupportingFileSummary] = [],
        callID: String
    ) -> ToolResult {
        let supportingFileContext = supportingFiles.isEmpty
            ? ""
            : "\n\n## Installed Supporting Files\n\n" + supportingFiles.map(\.renderedContext).joined(separator: "\n\n")
        let content = "---\nname: \(skill.name)\ndescription: \(skill.description)\n---\n\n\(skill.instructions)\(supportingFileContext)"
        return ToolResult(
            callID: callID,
            toolName: "load_skill",
            output: .object([
                "cardKind": .string("skill.load"),
                "skillName": .string(skill.name),
                "title": .string(skill.title),
                "description": .string(skill.description),
                "instructions": .string(skill.instructions),
                "supportingFiles": .array(supportingFiles.map(\.jsonValue)),
                "content": .string(content),
                "requiresSecret": .bool(skill.requiresSecret),
                "capabilityRequirements": skill.capabilityRequirements.jsonValue,
                "requiresExplicitHostPolicy": .bool(skill.requiresExplicitHostPolicy),
                "hostPolicySummary": .string(skill.hostPolicySummary),
                "source": .string(skill.sourceLabel)
            ]),
            metadata: [
                "cardTitle": .string(skill.title),
                "cardSubtitle": .string(skill.description),
                "skillName": .string(skill.name),
                "requiresExplicitHostPolicy": .bool(skill.requiresExplicitHostPolicy)
            ]
        )
    }

    func missingSecretResult(
        skill: ManagedSkill,
        scriptName: String,
        callID: String
    ) -> ToolResult {
        ToolResult(
            callID: callID,
            toolName: "run_js",
            output: .object([
                "cardKind": .string("skill.missing-secret"),
                "skillName": .string(skill.name),
                "content": .string("Missing secret for skill \(skill.title). Open Skill Manager to configure it."),
                "requiresSecretDescription": .string(skill.requiresSecretDescription)
            ]),
            isError: true,
            metadata: [
                "skillName": .string(skill.name),
                "scriptName": .string(scriptName),
                "missingSecret": .bool(true)
            ]
        )
    }

    func scriptErrorResult(
        skill: ManagedSkill,
        scriptName: String,
        error: String,
        callID: String
    ) -> ToolResult {
        ToolResult(
            callID: callID,
            toolName: "run_js",
            output: .object([
                "cardKind": .string("skill.error"),
                "skillName": .string(skill.name),
                "content": .string(error)
            ]),
            isError: true,
            metadata: [
                "skillName": .string(skill.name),
                "scriptName": .string(scriptName)
            ]
        )
    }

    func scriptSuccessResult(
        skill: ManagedSkill,
        scriptName: String,
        response: SkillScriptResponse,
        resolvedWebViewURL: URL?,
        callID: String
    ) throws -> ToolResult {
        var output: [String: JSONValue] = [
            "skillName": .string(skill.name),
            "scriptName": .string(scriptName),
            "content": .string(response.result?.ifEmpty("Skill executed.") ?? "Skill executed.")
        ]
        var metadata: [String: JSONValue] = [
            "skillName": .string(skill.name),
            "scriptName": .string(scriptName)
        ]

        let artifactResult = try artifacts.makeArtifactRequests(skill: skill, scriptName: scriptName, response: response)
        if artifactResult.descriptors.isEmpty == false {
            output["artifacts"] = .array(artifactResult.descriptors)
        }

        if let webview = response.webview, let resolvedWebViewURL {
            output["cardKind"] = .string("skill.webview")
            output["webview"] = .object([
                "kind": .string("url"),
                "url": .string(resolvedWebViewURL.absoluteString),
                "aspectRatio": webview.aspectRatio.map(JSONValue.number) ?? .number(1.333),
                "iframe": .bool(webview.iframe ?? false),
                "title": webview.title.map(JSONValue.string) ?? .string(skill.title)
            ])
            metadata["cardTitle"] = .string(webview.title?.ifEmpty(skill.title) ?? skill.title)
            metadata["cardSubtitle"] = .string("Interactive view")
        }

        if output["webview"] == nil,
           let artifactBackedWebView = try artifacts.artifactBackedWebViewPayload(response: response, artifactDescriptors: artifactResult.descriptors)
        {
            output["cardKind"] = .string("skill.webview")
            output["webview"] = artifactBackedWebView
            metadata["cardTitle"] = .string(response.webview?.title?.ifEmpty(skill.title) ?? skill.title)
            metadata["cardSubtitle"] = .string("Interactive view")
        }

        if let image = response.image {
            output["cardKind"] = .string("skill.image")
            output["image"] = .object(["base64": .string(image.base64)])
            metadata["cardTitle"] = .string(skill.title)
            metadata["cardSubtitle"] = .string("Generated image")
        }

        if let genres = response.availableGenres, !genres.isEmpty {
            output["cardKind"] = .string("skill.genres")
            output["available_genres"] = try JSONValue.encode(genres)
            metadata["cardTitle"] = .string(skill.title)
            metadata["cardSubtitle"] = .string("Available genres")
        }

        if output["cardKind"] == nil, artifactResult.requests.isEmpty == false {
            output["cardKind"] = .string("skill.artifacts")
            metadata["cardTitle"] = .string(skill.title)
            metadata["cardSubtitle"] = .string("Generated files")
        }

        if output["cardKind"] == nil {
            output["cardKind"] = .string("skill.generic")
        }

        return ToolResult(
            callID: callID,
            toolName: "run_js",
            output: .object(output),
            artifacts: artifactResult.requests,
            metadata: metadata
        )
    }
}
