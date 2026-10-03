import Foundation
import ChatGPTAccount
import ChatGPTImage
import NativeAgentDomain
import LanguageModelCore

/// Existing Agent effect/artifact machinery owns execution. This adapter writes no files.
enum ChatGPTImageLayerTools {
  static func executors(client: any ChatGPTImageServing) -> [any ToolExecutor] {
    [
      ClosureToolExecutor(definition: planDefinition) { call, context in
        let object = try ChatGPTImageInputPolicy.object(call.arguments, allowing: ["image", "layers"])
        guard let imageValue = object["image"], let values = object["layers"]?.arrayValue,
          (1...ChatGPTImageLayers.Plan.maximumLayers).contains(values.count) else {
          throw AgentError.invalidToolCall("Provide a real source image and a bounded back-to-front layer list")
        }
        let layers = try values.map { value -> ChatGPTImageLayers.Layer in
          let fields = try ChatGPTImageInputPolicy.object(value, allowing: ["id", "subject", "role", "restore_hidden"])
          let id = try ChatGPTImageInputPolicy.string("id", in: fields, required: true) ?? ""
          let subject = try ChatGPTImageInputPolicy.string("subject", in: fields, required: true) ?? ""
          let roleText = try ChatGPTImageInputPolicy.string("role", in: fields, required: true) ?? ""
          guard let role = ChatGPTImageLayers.Role(rawValue: roleText) else {
            throw AgentError.invalidToolCall("Layer role must be background or element")
          }
          let occlusion: ChatGPTImageLayers.Occlusion
          if let description = try ChatGPTImageInputPolicy.string("restore_hidden", in: fields) {
            occlusion = .restore(description: description)
          } else { occlusion = .none }
          return try .init(id: id, subject: subject, role: role, occlusion: occlusion)
        }
        let source = try ChatGPTEditImageToolArguments.decodeImage(imageValue, context: context)
        let plan = try ChatGPTImageLayers(client: client).prepare(source: source, layers: layers)
        let metadata: [String: JSONValue] = [
          "role": .string("image_layer_plan"), "sourceSHA256": .string(plan.sourceSHA256),
          "planSHA256": .string(try plan.digest()),
          "contractVerification": .string("verified"),
          "contractVerificationScope": .array(["source_binding", "canvas", "plan_schema", "stack_order"].map(JSONValue.string)),
          "semanticVerification": .string("not_run"), "stackOrder": .string("back_to_front"),
        ]
        return ToolResult(callID: call.id, toolName: call.name, output: .object([
          "content": .string("Layer plan recorded. Render one layer per call using this plan artifact. This is a proposal, not measured segmentation."),
          "sourceSHA256": .string(plan.sourceSHA256), "planSHA256": .string(try plan.digest()),
          "width": .integer(Int64(plan.width)), "height": .integer(Int64(plan.height)),
          "layerIDsBackToFront": .array(plan.layers.map { .string($0.id) }),
          "contractVerification": .string("verified"),
          "semanticVerification": .string("not_run"),
        ]), artifacts: [ArtifactWriteRequest(preferredFilename: "image-layer-plan.json",
          mimeType: "application/json", data: try plan.encoded(), metadata: metadata)], metadata: metadata)
      },
      ClosureToolExecutor(definition: renderDefinition) { call, context in
        let plan: ChatGPTImageLayers.Plan
        let source: ModelBinaryContent
        let layerID: String
        do {
          let object = try ChatGPTImageInputPolicy.object(call.arguments,
            allowing: ["plan_artifact_relative_path", "plan_sha256", "image", "layer_id"])
          let path = try ChatGPTImageInputPolicy.string("plan_artifact_relative_path", in: object, required: true) ?? ""
          let digest = try ChatGPTImageInputPolicy.string("plan_sha256", in: object, required: true) ?? ""
          let data = try ChatGPTSessionArtifactInputResolver.read(relativePath: path,
            expectedSHA256: digest, context: context, maximumBytes: ChatGPTImageLayers.Plan.maximumEncodedBytes)
          plan = try ChatGPTImageLayers.Plan.decode(data)
          layerID = try ChatGPTImageInputPolicy.string("layer_id", in: object, required: true) ?? ""
          guard let image = object["image"] else { throw AgentError.invalidToolCall("A real source image is required") }
          source = try ChatGPTEditImageToolArguments.decodeImage(image, context: context)
        } catch {
          throw EffectFailure.definiteFailure(operation: "images.layers.render.preflight", cause: error.localizedDescription)
        }
        let outcome = try await ChatGPTImageLayers(client: client).render(
          plan: plan, layerID: layerID, source: source, turnID: UUID())
        // After remote completion, publication failures have unknown durable outcome.
        do { return try result(outcome, plan: plan, call: call) }
        catch {
          throw EffectFailure.outcomeUnknown(operation: "images.layers.render.publication",
            cause: error.localizedDescription, context: ["providerReturned": "true"])
        }
      },
    ]
  }

  static var planDefinition: ToolDefinition {
    ToolDefinition(name: "images.layers.plan",
      description: "Record a semantic layer proposal from the actual source image. List independently editable subjects back-to-front. This tool validates source/canvas/plan contracts; it is not a segmentation model and makes no remote call.",
      capabilityID: .images, inputSchema: ToolSchema.object(properties: [
        "image": imageSchema,
        "layers": ToolSchema.array(items: ToolSchema.object(properties: [
          "id": ToolSchema.string(description: "Unique ASCII layer ID; used as a filename.", minLength: 1, maxLength: 64),
          "subject": ToolSchema.string(description: "One actual visual element, identified unambiguously from the source.", minLength: 1, maxLength: 2_000),
          "role": ToolSchema.string(enum: ["background", "element"]),
          "restore_hidden": ToolSchema.string(description: "Only when occluded: describe the hidden structure to infer. Omit otherwise.", minLength: 1, maxLength: 2_000),
        ], required: ["id", "subject", "role"], additionalProperties: false),
          minItems: 1, maxItems: ChatGPTImageLayers.Plan.maximumLayers),
      ], required: ["image", "layers"], additionalProperties: false),
      approvalPolicy: .automatic, effect: .readOnly)
  }

  static var renderDefinition: ToolDefinition {
    ToolDefinition(name: "images.layers.render",
      description: "Render exactly one layer candidate from an immutable plan and the identical source. Returns one visible chroma PNG plus a non-display RGBA-source sidecar. Approval required. Never a contact sheet; never claims source fidelity or hidden-part correctness.",
      capabilityID: .images, inputSchema: ToolSchema.object(properties: [
        "plan_artifact_relative_path": ToolSchema.string(minLength: 1, maxLength: 1_024),
        "plan_sha256": ToolSchema.string(minLength: 64, maxLength: 64),
        "image": imageSchema,
        "layer_id": ToolSchema.string(minLength: 1, maxLength: 64),
      ], required: ["plan_artifact_relative_path", "plan_sha256", "image", "layer_id"], additionalProperties: false),
      approvalPolicy: .requireApproval, effect: .mutation,
      metadata: ["providerID": .string(ChatGPTImagesCapability.providerID),
        "resultAuthority": .string("runtime_artifact"), "semanticVerification": .string("not_run")])
  }

  private static var imageSchema: JSONValue {
    // Reuse the existing image-reference wire contract, including its exact-one-source decoder.
    ChatGPTImagesToolPack.imageInputSchema
  }

  private static func result(
    _ outcome: ChatGPTImageLayers.Outcome, plan: ChatGPTImageLayers.Plan, call: ToolCall
  ) throws -> ToolResult {
    let planDigest = try plan.digest()
    switch outcome {
    case .candidate(let layer):
      guard let stackIndex = plan.layers.firstIndex(where: { $0.id == layer.layerID }) else {
        throw AgentError.invariantViolation("Rendered layer is absent from its plan")
      }
      let rgbaSHA256 = SHA256HexDigest.digest(layer.rgbaSourcePNG)
      let metadata: [String: JSONValue] = [
        "role": .string("image_layer_candidate"), "layerID": .string(layer.layerID),
        "planSHA256": .string(planDigest), "sourceSHA256": .string(plan.sourceSHA256),
        "stackIndex": .integer(Int64(stackIndex)),
        "width": .integer(Int64(layer.width)), "height": .integer(Int64(layer.height)),
        "origin": .string("top_left"), "workingColorSpace": .string("sRGB"),
        "chromaKey": .string(layer.chromaKey),
        "minimumSquaredRGBDistance": .integer(Int64(layer.minimumSquaredRGBDistance)),
        "chromaOnlyCollision": .bool(layer.minimumSquaredRGBDistance == 0),
        "rgbaSourceSHA256": .string(rgbaSHA256),
        "rgbaSourceEncoding": .string("PNG, original provider bytes, alpha retained"),
        "providerImageSHA256": .string(layer.providerImageSHA256),
        "providerRequestID": layer.providerRequestID.map(JSONValue.string) ?? .null,
        "providerTurnID": .string(layer.turnID.uuidString),
        "contractVerification": .string(layer.verification.status),
        "contractVerificationScope": .array([
          "source_binding", "plan_binding", "canvas", "alpha_admission", "chroma_projection", "stack_index"
        ].map(JSONValue.string)),
        "alphaAdmission": .string(layer.verification.alphaAdmission.rawValue),
        "chromaProjectionSHA256": .string(layer.verification.chromaProjectionSHA256),
        "semanticVerification": .string("not_run"), "recompositionVerification": .string("not_run"),
        "status": .string("candidate_review_required"),
      ]
      return ToolResult(callID: call.id, toolName: call.name, output: .object(metadata.merging([
        "content": .string("One independent chroma layer candidate created. Source fidelity, segmentation and hidden-part reconstruction require review. The RGBA sidecar is required for faithful alpha recomposition."),
      ]) { _, new in new }), artifacts: [
        ArtifactWriteRequest(preferredFilename: "\(layer.layerID).png", mimeType: "image/png",
          data: layer.chromaImage.data, metadata: metadata),
        ArtifactWriteRequest(preferredFilename: "\(layer.layerID).rgba-source", mimeType: "application/octet-stream",
          data: layer.rgbaSourcePNG, metadata: metadata.merging([
            "role": .string("image_layer_recomposition_source"), "display": .bool(false),
          ]) { _, new in new }),
      ], metadata: metadata)
    case .rejected(let candidate):
      let metadata: [String: JSONValue] = [
        "role": .string("rejected_image_layer_candidate"), "layerID": .string(candidate.layerID),
        "planSHA256": .string(planDigest), "sourceSHA256": .string(plan.sourceSHA256),
        "providerImageSHA256": .string(candidate.providerImageSHA256),
        "providerRequestID": candidate.providerRequestID.map(JSONValue.string) ?? .null,
        "semanticVerification": .string("not_run"), "status": .string("needs_repair"),
        "reason": .string(candidate.reason), "display": .bool(false),
      ]
      return ToolResult(callID: call.id, toolName: call.name, output: .object(metadata.merging([
        "content": .string("Provider candidate rejected by local output admission. No resizing, false chroma export or automatic remote retry occurred."),
      ]) { _, new in new }), isError: true, artifacts: [
        ArtifactWriteRequest(preferredFilename: "\(candidate.layerID).rejected-source", mimeType: "application/octet-stream",
          data: candidate.bytes, metadata: metadata),
      ], metadata: metadata)
    }
  }
}
