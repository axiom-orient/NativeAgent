import Foundation
import ChatGPTAccount
import ChatGPTImage
import NativeAgentDomain
import LanguageModelCore
import NativeAgentSkills

public enum ChatGPTImageSkillIntents {
  public static let transform = "chatgpt.images.transform"
  public static func effect(_ id: String) -> String { "chatgpt.images.effect.\(id)" }
}

public struct ChatGPTImageEffectPreset: Hashable, Sendable, Identifiable {
  public let id: String
  public let skillName: String
  public let title: String
  public let description: String
  public let promptPrefix: String
  public let defaultBackground: ChatGPTImageBackground
  public let defaultQuality: ChatGPTImageQuality
  public let defaultSize: String

  public init(
    id: String,
    skillName: String,
    title: String,
    description: String,
    promptPrefix: String,
    defaultBackground: ChatGPTImageBackground,
    defaultQuality: ChatGPTImageQuality = .high,
    defaultSize: String = "auto"
  ) {
    self.id = id
    self.skillName = skillName
    self.title = title
    self.description = description
    self.promptPrefix = promptPrefix
    self.defaultBackground = defaultBackground
    self.defaultQuality = defaultQuality
    self.defaultSize = defaultSize
  }

  public var intentName: String { ChatGPTImageSkillIntents.effect(id) }

  public static let defaults: [ChatGPTImageEffectPreset] = [
    .init(
      id: "transparent-asset", skillName: "image-transparent-asset", title: "Transparent Asset",
      description: "Generate isolated assets with true transparent-background intent.",
      promptPrefix: "Create one clean isolated production asset. Keep the full subject readable. Require a genuinely transparent background with true alpha; no checkerboard, white backdrop, watermark, or extra subjects.",
      defaultBackground: .transparent),
    .init(
      id: "sticker-cutout", skillName: "image-sticker-cutout", title: "Sticker Cutout",
      description: "Generate readable sticker-style cutout illustrations.",
      promptPrefix: "Create a polished sticker-style cutout illustration with a strong silhouette, restrained outline, production-ready edge quality, and true transparent background. No watermark or extra subjects.",
      defaultBackground: .transparent),
    .init(
      id: "app-icon", skillName: "image-app-icon", title: "App Icon",
      description: "Generate centered mobile app icon concepts.",
      promptPrefix: "Create a refined mobile app icon concept with one clear symbol, centered composition, strong small-size readability, controlled depth, no mockup device, no watermark, and no unnecessary text.",
      defaultBackground: .transparent),
    .init(
      id: "cinematic-poster", skillName: "image-cinematic-poster", title: "Cinematic Poster",
      description: "Generate cinematic poster artwork from a brief.",
      promptPrefix: "Create a cinematic poster composition with a strong focal hierarchy, dramatic but readable lighting, deliberate negative space for optional typography, restrained detail, and no watermark.",
      defaultBackground: .opaque),
    .init(
      id: "product-shot", skillName: "image-product-shot", title: "Product Shot",
      description: "Generate premium product photography-style images.",
      promptPrefix: "Create a premium product-shot image with accurate object geometry, clean material rendering, controlled studio lighting, believable contact shadows, uncluttered composition, and no watermark.",
      defaultBackground: .opaque),
    .init(
      id: "watercolor", skillName: "image-watercolor", title: "Watercolor",
      description: "Render a subject as refined watercolor artwork.",
      promptPrefix: "Render the requested subject as refined watercolor artwork on natural paper: controlled pigment blooms, layered washes, clean silhouette, selective detail, tasteful negative space, and no watermark.",
      defaultBackground: .opaque),
    .init(
      id: "pen-sketch", skillName: "image-pen-sketch", title: "Pen Sketch",
      description: "Render a subject as clean ink and pen sketch artwork.",
      promptPrefix: "Render the requested subject as a confident pen-and-ink sketch: deliberate line weight, sparse hatching, readable construction, white-space discipline, no fake notebook UI, and no watermark.",
      defaultBackground: .opaque),
    .init(
      id: "pixel-art", skillName: "image-pixel-art", title: "Pixel Art",
      description: "Generate crisp pixel-art assets with intentional clusters.",
      promptPrefix: "Create crisp pixel art with intentional pixel clusters, limited palette, readable silhouette, no antialiased pseudo-pixels, no watermark, and no extra subjects.",
      defaultBackground: .transparent),
    .init(
      id: "photorealistic", skillName: "image-photorealistic", title: "Photorealistic",
      description: "Generate natural photorealistic imagery.",
      promptPrefix: "Create a natural photorealistic image with physically plausible lighting, lens behavior, material texture, anatomy, depth, and restrained grading. Avoid synthetic over-sharpening and watermarks.",
      defaultBackground: .opaque),
    .init(
      id: "mobile-screen", skillName: "image-mobile-screen", title: "Mobile Screen",
      description: "Generate a flat readable mobile UI screen image.",
      promptPrefix: "Create one flat portrait mobile UI screen, not a device mockup. Preserve requested copy exactly, coherent hierarchy, safe areas, navigation and selected state. No overlapping text, truncation, invented labels, watermark, or phone frame.",
      defaultBackground: .opaque, defaultSize: "1024x1536"),
  ]
}

public enum ChatGPTImageSkills {
  public struct InstalledSkill: Sendable {
    public let name: String
    public let operation: CustomTextSkillUpsertOperation
  }

  public static var effectCatalog: [ChatGPTImageEffectPreset] {
    ChatGPTImageEffectPreset.defaults
  }

  public static func makeIntentRouter(client: any ChatGPTImageServing) -> SkillIntentRouterService {
    SkillIntentRouterService(handlers: defaultHandlers(client: client))
  }

  public static func registerDefaultHandlers(
    on router: SkillIntentRouterService,
    client: any ChatGPTImageServing
  ) async {
    for (intent, handler) in defaultHandlers(client: client) {
      await router.register(intent: intent, handler: handler)
    }
  }

  @discardableResult
  public static func installDefaultSkills(
    into library: SkillLibrary,
    selected: Bool = true
  ) async throws -> [InstalledSkill] {
    var installed: [InstalledSkill] = []

    for preset in effectCatalog {
      let result = try await library.upsertCustomTextSkill(
        name: preset.skillName,
        description: preset.description,
        instructions: effectSkillInstructions(preset),
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        capabilityRequirements: SkillCapabilityRequirements(hostIntents: [preset.intentName]),
        defaultSelected: selected,
        selected: selected
      )
      installed.append(InstalledSkill(name: result.skill.name, operation: result.operation))
    }

    let transform = try await library.upsertCustomTextSkill(
      name: "image-transform",
      description: "Transform real image artifacts while preserving explicit invariants.",
      instructions: transformSkillInstructions,
      requiresSecret: false,
      requiresSecretDescription: "",
      homepage: "",
      capabilityRequirements: SkillCapabilityRequirements(hostIntents: [ChatGPTImageSkillIntents.transform]),
      defaultSelected: selected,
      selected: selected
    )
    installed.append(InstalledSkill(name: transform.skill.name, operation: transform.operation))
    return installed
  }

  private static func defaultHandlers(
    client: any ChatGPTImageServing
  ) -> [String: SkillIntentHandler] {
    var handlers: [String: SkillIntentHandler] = [:]

    for preset in effectCatalog {
      handlers[preset.intentName] = SkillIntentHandler(
        definition: ToolDefinition(
          name: preset.intentName,
          description: preset.description,
          capabilityID: .images,
          inputSchema: ChatGPTImagesToolPack.generateInputSchema,
          approvalPolicy: .requireApproval,
          effect: .mutation,
          metadata: [
            "providerID": .string(ChatGPTImagesCapability.providerID),
            "requiresSelectedSkill": .bool(true),
            "effectID": .string(preset.id),
          ]
        )
      ) { parameters, _ in
        let arguments = try ChatGPTImagesToolPack.generateArguments(
          parameters,
          defaultBackground: preset.defaultBackground,
          defaultQuality: preset.defaultQuality,
          defaultSize: preset.defaultSize,
          operation: "\(preset.intentName).preflight"
        )
        return try await ChatGPTImagesToolPack.generateResult(
          client: client,
          arguments: arguments,
          callID: "intent-\(preset.id)",
          toolName: preset.intentName,
          promptPrefix: preset.promptPrefix
        )
      }
    }

    handlers[ChatGPTImageSkillIntents.transform] = SkillIntentHandler(
      definition: ToolDefinition(
        name: ChatGPTImageSkillIntents.transform,
        description: "Transform real image artifacts through ChatGPT image editing.",
        capabilityID: .images,
        inputSchema: ChatGPTImagesToolPack.editDefinition.inputSchema,
        approvalPolicy: .requireApproval,
        effect: .mutation,
        metadata: [
          "providerID": .string(ChatGPTImagesCapability.providerID),
          "requiresSelectedSkill": .bool(true),
        ]
      )
    ) { parameters, context in
      let arguments = try ChatGPTImagesToolPack.editArguments(
        parameters,
        context: context,
        operation: "\(ChatGPTImageSkillIntents.transform).preflight"
      )
      return try await ChatGPTImagesToolPack.editResult(
        client: client,
        arguments: arguments,
        callID: "intent-image-transform",
        toolName: ChatGPTImageSkillIntents.transform,
        promptPrefix: "Transform only the supplied image content according to the user request. Preserve every explicitly named invariant, identity, text, layout or object that the user asked to keep. Do not invent missing source pixels or claim exact preservation without evidence."
      )
    }
    return handlers
  }

  private static func effectSkillInstructions(_ preset: ChatGPTImageEffectPreset) -> String {
    """
Use this skill for: \(preset.description)

1. Load this skill before execution. Preserve the user's subject, required text, composition constraints and exclusions.
2. Call `run_intent` with intent `\(preset.intentName)` and JSON parameters containing `prompt`; optional keys are `background`, `quality`, `size`, and `output_filename`.
3. The preset supplies its medium/effect policy. Do not add unrelated subjects, logos or watermarks.
4. Treat the returned artifact and `verification.status` as the result authority. `needs_repair` or `structural_only` is not a verified final constraint.
5. Never switch provider, billing path, model or skill because generation failed.
"""
  }

  private static let transformSkillInstructions = """
Use this skill only when real source images are available.

1. Load this skill. Identify what must change and what must remain invariant.
2. Call `run_intent` with intent `chatgpt.images.transform`.
3. For each source, prefer the exact prior Agent artifact `artifact_relative_path` plus `sha256`. Use inline `base64` only for a caller-supplied image that is not already an Agent artifact.
4. Never invent, reconstruct or guess an artifact path/digest. Never substitute a preview or unrelated image.
5. Treat the returned artifact and `verification.status` as the result authority. Do not claim exact preservation unless the actual result supports it.
"""
}

