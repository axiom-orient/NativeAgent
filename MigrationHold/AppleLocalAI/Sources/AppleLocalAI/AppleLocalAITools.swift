import FoundationModels
#if !targetEnvironment(simulator)
import _Vision_FoundationModels
#endif

public enum AppleLocalAITools {
  /// Vision tools supplied by Apple. OCRTool isn't available in Simulator;
  /// callers should qualify image workflows on a physical iOS 27 device.
  public static func vision() -> [any Tool] {
#if targetEnvironment(simulator)
    preconditionFailure("Apple Vision Foundation Models tools are unavailable in Simulator.")
#else
    [OCRTool(), BarcodeReaderTool(), AppleLocalAIImageMetadataTool()]
#endif
  }
}

#if !targetEnvironment(simulator)
@Generable
struct AppleLocalAIImageMetadataArguments {
  @Guide(description: "The image from the current prompt to inspect.")
  var image: ImageReference
}

struct AppleLocalAIImageMetadataTool: Tool, Sendable {
  let name = "inspect_image"
  let description = "Inspect the dimensions and orientation of an image attached to the current prompt."

  @SessionProperty(\.history) var history

  func call(arguments: AppleLocalAIImageMetadataArguments) async throws -> String {
    guard let attachment = arguments.image.resolved(in: history) else {
      return "The referenced image is no longer available in the session history."
    }
    let image = attachment.cgImage
    return "Image \(arguments.image.attachmentLabel): \(image.width)x\(image.height) pixels, orientation \(attachment.orientation.rawValue)."
  }
}
#endif
