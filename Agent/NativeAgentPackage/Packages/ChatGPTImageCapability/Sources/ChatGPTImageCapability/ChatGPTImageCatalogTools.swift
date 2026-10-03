import Foundation
import NativeAgentDomain
import LanguageModelCore

/// Read-only discovery and one approval-gated execution path for reviewed, bundled prompts.
enum ChatGPTImageCatalogTools {
  static func executors(client: any ChatGPTImageServing) -> [any ToolExecutor] {
    [
      ClosureToolExecutor(definition: listDefinition) { call, _ in
        let catalog = try ChatGPTImagePromptCatalog.bundled()
        let query = call.arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matches = catalog.prompts.filter {
          query.isEmpty || [$0.id, $0.title, $0.summary, $0.category].joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
        return ToolResult(callID: call.id, toolName: call.name, output: .object([
          "revision": .string(catalog.revision),
          "categories": try json(catalog.categories),
          "prompts": .array(matches.map { .object([
            "id": .string($0.id), "title": .string($0.title), "summary": .string($0.summary),
            "mode": .string($0.mode.rawValue), "requiredVariables": .array($0.requiredVariables.map(JSONValue.string)),
          ]) }),
        ]))
      },
      ClosureToolExecutor(definition: readDefinition) { call, _ in
        let catalog = try ChatGPTImagePromptCatalog.bundled()
        let promptID = call.arguments["prompt_id"]?.stringValue
        let categoryID = call.arguments["category_id"]?.stringValue
        guard promptID != nil || categoryID != nil else { throw AgentError.invalidToolCall("Provide prompt_id or category_id") }
        let prompt = try promptID.map { try catalog.prompt(id: $0) }
        let category = try categoryID.map { try catalog.category(id: $0) }
          ?? catalog.categories.first { $0.promptIDs.contains(promptID ?? "") }
        if let promptID, let category, !category.promptIDs.contains(promptID) {
          throw AgentError.invalidToolCall("The category does not contain this prompt")
        }
        var artifacts: [ArtifactWriteRequest] = []
        if let category {
          let url = try catalog.previewURL(categoryID: category.id)
          artifacts = [ArtifactWriteRequest(preferredFilename: category.previewFile, mimeType: "image/webp",
            data: try Data(contentsOf: url), metadata: [
              "role": .string("category_example"), "notGenerationResult": .bool(true),
              "categoryID": .string(category.id), "catalogRevision": .string(catalog.revision),
            ])]
        }
        return ToolResult(callID: call.id, toolName: call.name, output: .object([
          "revision": .string(catalog.revision),
          "prompt": try prompt.map { try json($0) } ?? .null,
          "category": try category.map { try json($0) } ?? .null,
          "notice": .string("Example only, not a generated result or reference input. Inspect the selected prompt's required variables before images.catalog.run."),
        ]), artifacts: artifacts)
      },
      ClosureToolExecutor(definition: runDefinition) { call, context in
        let catalog: ChatGPTImagePromptCatalog
        let prompt: ChatGPTImagePromptCatalog.ImagePrompt
        var parameters: [String: JSONValue]
        do {
          catalog = try ChatGPTImagePromptCatalog.bundled()
          guard let object = call.arguments.objectValue,
            let id = object["prompt_id"]?.stringValue,
            object["catalog_revision"]?.stringValue == catalog.revision else {
            throw AgentError.invalidToolCall("Read the current catalog and provide its exact catalog_revision and prompt_id")
          }
          prompt = try catalog.prompt(id: id)
          var variables: [String: String] = [:]
          if let raw = object["variables"] {
            guard let fields = raw.objectValue else { throw AgentError.invalidToolCall("variables must be an object") }
            for (key, value) in fields {
              guard let text = value.stringValue else { throw AgentError.invalidToolCall("Variable values must be strings") }
              variables[key] = text
            }
          }
          if let images = object["images"], images.arrayValue == nil {
            throw AgentError.invalidToolCall("images must be an array")
          }
          if prompt.variables.contains("BACKGROUND"), let background = object["background"]?.stringValue {
            if background == "transparent" {
              if let requested = variables["BACKGROUND"], requested != "transparent" {
                throw AgentError.invalidToolCall("BACKGROUND and background conflict")
              }
              variables["BACKGROUND"] = "transparent"
            } else if background == "opaque", variables["BACKGROUND"] == "transparent" {
              throw AgentError.invalidToolCall("BACKGROUND and background conflict")
            }
          }
          let prepared = try catalog.prepare(promptID: id, variables: variables,
            referenceImageCount: object["images"]?.arrayValue?.count ?? 0)
          parameters = object.filter { ["images", "background", "quality", "size", "output_filename"].contains($0.key) }
          parameters["prompt"] = .string(prepared)
          // A transparent brief must flow into native alpha verification, not only into prose.
          if variables["BACKGROUND"] == "transparent" {
            if let background = parameters["background"]?.stringValue, background != "transparent" {
              throw AgentError.invalidToolCall("BACKGROUND and background conflict")
            }
            parameters["background"] = "transparent"
          }
        } catch {
          throw EffectFailure.definiteFailure(operation: "images.catalog.run.preflight", cause: error.localizedDescription)
        }
        let result: ToolResult
        switch prompt.mode {
        case .textOnly:
          let arguments = try ChatGPTImagesToolPack.generateArguments(.object(parameters), operation: "images.catalog.run.preflight")
          result = try await ChatGPTImagesToolPack.generateResult(client: client, arguments: arguments,
            callID: call.id, toolName: call.name)
        case .referenceImageRequired:
          let arguments = try ChatGPTImagesToolPack.editArguments(.object(parameters), context: context, operation: "images.catalog.run.preflight")
          result = try await ChatGPTImagesToolPack.editResult(client: client, arguments: arguments,
            callID: call.id, toolName: call.name)
        }
        let provenance: [String: JSONValue] = [
          "catalogRevision": .string(catalog.revision), "promptID": .string(prompt.id),
          "semanticVerification": .string("not_run"),
          "reviewCriteria": .array(prompt.failureCriteria.map(JSONValue.string)),
        ]
        let artifacts = result.artifacts.map {
          ArtifactWriteRequest(preferredFilename: $0.preferredFilename, mimeType: $0.mimeType,
            data: $0.data, metadata: $0.metadata.merging(provenance) { _, new in new })
        }
        var output = result.output.objectValue ?? [:]
        output.merge(provenance) { _, new in new }
        return ToolResult(callID: result.callID, toolName: result.toolName, output: .object(output),
          isError: result.isError, artifacts: artifacts, metadata: result.metadata.merging(provenance) { _, new in new })
      },
    ]
  }

  static var listDefinition: ToolDefinition {
    ToolDefinition(name: "images.catalog.list", description: "Find prepared image prompts and illustrated categories. Read a selected prompt before running it.",
      capabilityID: .images, inputSchema: ToolSchema.object(properties: [
        "query": ToolSchema.string(description: "Optional name, ID or style search.", maxLength: 200),
      ], required: [], additionalProperties: false), approvalPolicy: .automatic, effect: .readOnly)
  }

  static var readDefinition: ToolDefinition {
    ToolDefinition(name: "images.catalog.read", description: "Read a prompt's complete brief, variables and failure criteria, or a category explanation. Returns a bundled WebP example artifact, never a generation or input image.",
      capabilityID: .images, inputSchema: ToolSchema.object(properties: [
        "prompt_id": ToolSchema.string(description: "Exact catalog prompt ID.", minLength: 1),
        "category_id": ToolSchema.string(description: "Exact category ID.", minLength: 1),
      ], required: [], additionalProperties: false), approvalPolicy: .automatic, effect: .readOnly)
  }

  static var runDefinition: ToolDefinition {
    var fields = ChatGPTImagesToolPack.editDefinition.inputSchema["properties"]?.objectValue ?? [:]
    fields.removeValue(forKey: "prompt")
    fields["prompt_id"] = ToolSchema.string(description: "Exact ID read from the catalog.", minLength: 1)
    fields["catalog_revision"] = ToolSchema.string(description: "Exact revision returned by catalog.read/list. Stale revisions fail before dispatch.", minLength: 1)
    fields["variables"] = .object(["type": "object", "additionalProperties": .object(["type": "string"]),
      "description": "Only variables declared by the selected prompt. MICRO_STORIES uses newlines; EXPRESSIONS uses commas."])
    return ToolDefinition(name: "images.catalog.run", description: "Run one prepared prompt using the ChatGPT subscription. Reference prompts require exactly one real PNG; text-only prompts generate without images. Preserves normal approval, artifact and failure handling.",
      capabilityID: .images, inputSchema: ToolSchema.object(properties: fields,
        required: ["prompt_id", "catalog_revision"], additionalProperties: false), approvalPolicy: .requireApproval, effect: .mutation)
  }

  private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }
}
