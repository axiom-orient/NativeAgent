import Foundation

struct ASKHWPXImageAccumulator: Sendable, Hashable {
  private var builder: ImageBuilder?

  var isActive: Bool { builder != nil }

  mutating func consumeStart(
    localName: String,
    depth: Int,
    attributes: AttributeLookup,
    sourcePath: String,
    completedBlockCount: Int
  ) -> Bool {
    if builder == nil, ASKHWPXAttributeDecoder.startsImage(localName) {
      builder = ImageBuilder(
        id: attributes.string(["id", "instanceID", "instid", "name"])
          ?? "image-\(completedBlockCount + 1)",
        sourcePath: sourcePath,
        depth: depth,
        binaryPath: ASKHWPXAttributeDecoder.imageBinaryPath(attributes),
        referenceID: attributes.string([
          "binaryItemIDRef", "binaryItemIdRef", "binItemIDRef", "binDataIDRef", "refID", "refId",
          "href",
        ]),
        altText: attributes.string(["alt", "altText", "description", "desc", "name"]),
        width: ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["width", "w", "imgW", "orgWidth"]
        ),
        height: ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["height", "h", "imgH", "orgHeight"]
        )
      )
      return true
    }

    guard var builder else { return false }
    if let binaryPath = ASKHWPXAttributeDecoder.imageBinaryPath(attributes) {
      builder.binaryPath = builder.binaryPath ?? binaryPath
      builder.referenceID = builder.referenceID ?? binaryPath
    }
    builder.referenceID =
      builder.referenceID
      ?? attributes.string([
        "binaryItemIDRef", "binaryItemIdRef", "binItemIDRef", "binDataIDRef", "refID", "refId",
        "href",
      ])
    builder.altText =
      builder.altText
      ?? attributes.string(["alt", "altText", "description", "desc", "name"])
    if localName == "sz" || localName == "orgsz" || localName == "cursz" || localName == "imgdim" {
      builder.width =
        builder.width
        ?? ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["width", "w", "dimwidth"]
        )
      builder.height =
        builder.height
        ?? ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["height", "h", "dimheight"]
        )
    }
    self.builder = builder
    return true
  }

  mutating func consumeCharacters(_ characters: String) -> Bool {
    guard var builder else { return false }
    let text = characters.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
      if let altText = builder.altText, !altText.isEmpty {
        builder.altText = altText + " " + text
      } else {
        builder.altText = text
      }
    }
    self.builder = builder
    return true
  }

  mutating func consumeEnd(localName: String, depth: Int) -> ASKHWPImage? {
    guard let builder else { return nil }
    guard depth == builder.depth, ASKHWPXAttributeDecoder.startsImage(localName) else {
      return nil
    }
    self.builder = nil
    return ASKHWPImage(
      id: builder.id,
      sourcePath: builder.sourcePath,
      binaryPath: builder.binaryPath,
      referenceID: builder.referenceID,
      altText: builder.altText,
      width: builder.width,
      height: builder.height
    )
  }
}
