import Foundation
import NativeAgentDomain

struct SkillRuntimeArtifacts {
    func makeArtifactRequests(
        skill: ManagedSkill,
        scriptName: String,
        response: SkillScriptResponse
    ) throws -> (requests: [ArtifactWriteRequest], descriptors: [JSONValue]) {
        var requests: [ArtifactWriteRequest] = []
        var descriptors: [JSONValue] = []

        if let image = response.image {
            guard let imageData = Data(base64Encoded: stripDataURLPrefix(fromBase64: image.base64)) else {
                throw AgentError.invalidToolCall("Skill image base64 payload is invalid")
            }
            let preferredFilename = "\(skill.name)-\(scriptName).png"
            let metadata: [String: JSONValue] = [
                "skillName": .string(skill.name),
                "scriptName": .string(scriptName),
                "preferredFilename": .string(preferredFilename),
                "role": .string("primary")
            ]
            requests.append(
                ArtifactWriteRequest(
                    preferredFilename: preferredFilename,
                    mimeType: "image/png",
                    data: imageData,
                    metadata: metadata
                )
            )
            descriptors.append(
                .object([
                    "filename": .string(preferredFilename),
                    "mimeType": .string("image/png"),
                    "role": .string("primary")
                ])
            )
        }

        for artifact in response.artifacts ?? [] {
            let trimmedFilename = artifact.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedFilename.isEmpty == false else {
                throw AgentError.invalidToolCall("Skill artifact filename must not be empty")
            }
            guard artifact.text == nil || artifact.base64 == nil else {
                throw AgentError.invalidToolCall(
                    "Skill artifact \(trimmedFilename) must not provide both text and base64 content"
                )
            }

            let data: Data
            if let text = artifact.text {
                data = Data(text.utf8)
            } else if let base64 = artifact.base64 {
                guard let decoded = Data(base64Encoded: stripDataURLPrefix(fromBase64: base64)) else {
                    throw AgentError.invalidToolCall("Skill artifact base64 payload is invalid for \(trimmedFilename)")
                }
                data = decoded
            } else {
                throw AgentError.invalidToolCall("Skill artifact \(trimmedFilename) must provide either text or base64 content")
            }

            var artifactMetadata = artifact.metadata
            artifactMetadata["skillName"] = .string(skill.name)
            artifactMetadata["scriptName"] = .string(scriptName)
            artifactMetadata["preferredFilename"] = .string(trimmedFilename)
            if let role = artifact.role {
                artifactMetadata["role"] = .string(role.rawValue)
            }

            requests.append(
                ArtifactWriteRequest(
                    preferredFilename: trimmedFilename,
                    mimeType: artifact.mimeType,
                    data: data,
                    metadata: artifactMetadata
                )
            )

            var descriptor: [String: JSONValue] = [
                "filename": .string(trimmedFilename),
                "mimeType": .string(artifact.mimeType),
                "byteCount": .integer(Int64(data.count))
            ]
            if let role = artifact.role {
                descriptor["role"] = .string(role.rawValue)
            }
            if artifact.metadata.isEmpty == false {
                descriptor["metadata"] = .object(artifact.metadata)
            }
            descriptors.append(.object(descriptor))
        }

        return (requests, descriptors)
    }

    func artifactBackedWebViewPayload(
        response: SkillScriptResponse,
        artifactDescriptors: [JSONValue]
    ) throws -> JSONValue? {
        let selectedFilename: String?
        if let explicitFilename = response.webview?.artifactFilename?.trimmingCharacters(in: .whitespacesAndNewlines), explicitFilename.isEmpty == false {
            selectedFilename = explicitFilename
        } else {
            selectedFilename = artifactDescriptors.first(where: { descriptor in
                descriptor.objectValue?["role"]?.stringValue == SkillScriptResponse.ArtifactPayload.Role.webview.rawValue
            })?.objectValue?["filename"]?.stringValue
        }

        guard let selectedFilename else {
            return nil
        }

        let matchingDescriptor = artifactDescriptors.first { descriptor in
            descriptor.objectValue?["filename"]?.stringValue == selectedFilename
        }

        if matchingDescriptor == nil {
            throw AgentError.invalidToolCall("Web view artifact \(selectedFilename) was requested but no matching artifact was produced")
        }

        let mimeType = matchingDescriptor?.objectValue?["mimeType"]?.stringValue ?? "text/html"

        return .object([
            "kind": .string("artifact"),
            "artifactFilename": .string(selectedFilename),
            "mimeType": .string(mimeType),
            "aspectRatio": response.webview?.aspectRatio.map(JSONValue.number) ?? .number(1.333),
            "iframe": .bool(response.webview?.iframe ?? false),
            "title": response.webview?.title.map(JSONValue.string) ?? .null
        ])
    }

    private func stripDataURLPrefix(fromBase64 value: String) -> String {
        if let separatorRange = value.range(of: ","), value[..<separatorRange.lowerBound].contains(";base64") {
            return String(value[separatorRange.upperBound...])
        }
        return value
    }
}
