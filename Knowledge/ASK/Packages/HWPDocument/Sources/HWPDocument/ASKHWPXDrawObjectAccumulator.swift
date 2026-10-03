import DocumentCore
import Foundation

struct ASKHWPXDrawObjectAccumulator: Sendable, Hashable {
  private var builder: DrawObjectBuilder?
  private var textDepth = 0
  private var textBuffer = ""

  var isActive: Bool { builder != nil }

  mutating func consumeStart(
    localName: String,
    depth: Int,
    attributes: AttributeLookup,
    sourcePath: String,
    completedBlockCount: Int
  ) -> Bool {
    if builder == nil, ASKHWPXAttributeDecoder.startsDrawObject(localName) {
      textDepth = 0
      textBuffer = ""
      builder = DrawObjectBuilder(
        id: attributes.string(["id", "instanceID", "instid", "name"])
          ?? "object-\(completedBlockCount + 1)",
        sourcePath: sourcePath,
        depth: depth,
        kind: ASKHWPXAttributeDecoder.drawObjectKind(localName),
        name: attributes.string(["name", "title", "desc", "description"]),
        referenceID: attributes.string([
          "chartIDRef", "chartIdRef", "refID", "refId", "href", "binaryItemIDRef", "binDataIDRef",
        ]),
        variant: attributes.string(["arcType", "type", "shapeType"]),
        width: ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["width", "w", "szX", "xSz"]
        ),
        height: ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["height", "h", "szY", "ySz"]
        ),
        placement: ASKHWPXAttributeDecoder.placement(from: attributes),
        zOrder: attributes.int(["zOrder", "zorder", "z"]) ?? 0
      )
      return true
    }

    guard builder != nil else { return false }
    updateActiveObject(localName, attributes: attributes)
    return true
  }

  mutating func consumeCharacters(_ characters: String) -> Bool {
    guard builder != nil else { return false }
    if textDepth > 0 {
      textBuffer += characters
    }
    return true
  }

  mutating func consumeEnd(localName: String, depth: Int) -> ASKHWPDrawObject? {
    guard let builder else { return nil }
    finishActiveTextElement(localName)
    guard depth == builder.depth, ASKHWPXAttributeDecoder.startsDrawObject(localName) else {
      return nil
    }
    self.builder = nil
    textDepth = 0
    textBuffer = ""
    return ASKHWPDrawObject(
      id: builder.id,
      sourcePath: builder.sourcePath,
      kind: builder.kind,
      name: builder.name,
      referenceID: builder.referenceID,
      text: builder.text.nonEmptyValue,
      width: builder.width,
      height: builder.height,
      variant: builder.variant,
      placement: builder.placement,
      style: builder.style.makeStyle(),
      geometry: builder.geometry.makeGeometry(),
      transform: builder.transform,
      pathCommands: builder.pathCommands,
      textMargin: builder.textMargin,
      captionText: builder.captionText.nonEmptyValue,
      zOrder: builder.zOrder
    )
  }

  private mutating func updateActiveObject(
    _ localName: String,
    attributes: AttributeLookup
  ) {
    guard var builder else { return }
    builder.name = builder.name ?? attributes.string(["name", "title", "desc", "description"])
    builder.referenceID =
      builder.referenceID
      ?? attributes.string([
        "chartIDRef", "chartIdRef", "refID", "refId", "href", "binaryItemIDRef", "binDataIDRef",
      ])
    builder.variant = builder.variant ?? attributes.string(["arcType", "type", "shapeType"])
    builder.zOrder = attributes.int(["zOrder", "zorder", "z"]) ?? builder.zOrder

    switch localName {
    case "sz", "orgsz", "cursz":
      builder.width =
        builder.width
        ?? ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["width", "w", "szX", "xSz"]
        )
      builder.height =
        builder.height
        ?? ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["height", "h", "szY", "ySz"]
        )
    case "pos":
      builder.placement = builder.placement.merged(
        with: ASKHWPXAttributeDecoder.placement(from: attributes)
      )
    case "lineshape":
      builder.style.strokeColor = ASKHWPXAttributeDecoder.normalizedColor(
        attributes.string(["color", "lineColor"])
      )
      builder.style.strokeWidth =
        ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["width", "w", "lineWidth"]
        ) ?? builder.style.strokeWidth
      builder.style.strokeDash = ASKHWPXAttributeDecoder.dashPattern(
        from: attributes.string(["style", "dash", "dashStyle", "type"])
      )
      builder.style.lineHeadStyle =
        attributes.string([
          "headStyle", "head", "startArrowType",
        ]) ?? builder.style.lineHeadStyle
      builder.style.lineTailStyle =
        attributes.string([
          "tailStyle", "tail", "endArrowType",
        ]) ?? builder.style.lineTailStyle
    case "fillbrush", "winbrush":
      builder.style.fillColor =
        ASKHWPXAttributeDecoder.normalizedColor(
          attributes.string(["faceColor", "color", "fillColor"])
        ) ?? builder.style.fillColor
      builder.style.fillHatchColor =
        ASKHWPXAttributeDecoder.normalizedColor(
          attributes.string(["hatchColor", "patternColor"])
        ) ?? builder.style.fillHatchColor
      builder.style.fillHatchStyle =
        attributes.string([
          "hatchStyle", "style", "type",
        ]) ?? builder.style.fillHatchStyle
    case "color":
      let color = ASKHWPXAttributeDecoder.normalizedColor(
        attributes.string(["value", "rgb", "color"])
      )
      if builder.style.gradientType != nil, let color {
        builder.style.gradientColors.append(color)
      } else {
        builder.style.fillColor = color ?? builder.style.fillColor
      }
    case "gradation", "gradient":
      builder.style.gradientType =
        attributes.string(["type", "style"])
        ?? builder.style.gradientType
      builder.style.gradientAngle =
        attributes.double(["angle", "degree"])
        ?? builder.style.gradientAngle
    case "rotationinfo":
      builder.transform = ASKHWPShapeTransform(
        rotationDegrees: ASKHWPXAttributeDecoder.normalizedRotationDegrees(
          attributes.double(["angle"]) ?? builder.transform.rotationDegrees
        ),
        center: ASKHWPXAttributeDecoder.pointFromXY(
          attributes, xKeys: ["centerX"], yKeys: ["centerY"]
        ) ?? builder.transform.center,
        flipHorizontal: builder.transform.flipHorizontal,
        flipVertical: builder.transform.flipVertical
      )
    case "flip":
      builder.transform = ASKHWPShapeTransform(
        rotationDegrees: builder.transform.rotationDegrees,
        center: builder.transform.center,
        flipHorizontal: attributes.bool(["horizontal"]) ?? builder.transform.flipHorizontal,
        flipVertical: attributes.bool(["vertical"]) ?? builder.transform.flipVertical
      )
    case "shadow":
      builder.style.shadow = ASKHWPShadow(
        type: attributes.string(["type", "style"]),
        color: ASKHWPXAttributeDecoder.normalizedColor(attributes.string(["color"])),
        offsetX: ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["offsetX", "xOffset", "x"]
        ) ?? 0,
        offsetY: ASKHWPXAttributeDecoder.pointDimension(
          attributes, keys: ["offsetY", "yOffset", "y"]
        ) ?? 0,
        alpha: attributes.double(["alpha", "opacity"])
          .map { $0 > 1 ? $0 / 255.0 : $0 } ?? 1
      )
    case "pt", "pt0", "pt1", "pt2", "pt3", "point":
      if let point = ASKHWPXAttributeDecoder.point(from: attributes) {
        builder.geometry.points.append(point)
      }
    case "startpt", "start":
      builder.geometry.startPoint =
        ASKHWPXAttributeDecoder.point(from: attributes)
        ?? builder.geometry.startPoint
    case "endpt", "end":
      builder.geometry.endPoint =
        ASKHWPXAttributeDecoder.point(from: attributes)
        ?? builder.geometry.endPoint
    case "center":
      builder.geometry.center =
        ASKHWPXAttributeDecoder.point(from: attributes)
        ?? builder.geometry.center
    case "ax1", "axis1":
      builder.geometry.axis1 =
        ASKHWPXAttributeDecoder.point(from: attributes)
        ?? builder.geometry.axis1
    case "ax2", "axis2":
      builder.geometry.axis2 =
        ASKHWPXAttributeDecoder.point(from: attributes)
        ?? builder.geometry.axis2
    case "seg":
      let first = ASKHWPXAttributeDecoder.pointFromXY(
        attributes, xKeys: ["x1"], yKeys: ["y1"]
      )
      let second = ASKHWPXAttributeDecoder.pointFromXY(
        attributes, xKeys: ["x2"], yKeys: ["y2"]
      )
      let points = [first, second].compactMap { $0 }
      if !points.isEmpty {
        builder.pathCommands.append(
          ASKHWPDrawPathCommand(
            command: "segment",
            points: points,
            segmentType: attributes.string(["type", "segmentType"])
          )
        )
        builder.geometry.points.append(contentsOf: points)
      }
    case "textmargin":
      builder.textMargin = ASKHWPXAttributeDecoder.insets(from: attributes)
    case "drawtext", "shapecomment", "script":
      if let text = attributes.string(["text", "value", "content"]) {
        builder.textParts.append(text)
      }
      textDepth += 1
      textBuffer = ""
    case "caption":
      textDepth += 1
      textBuffer = ""
    default:
      break
    }
    self.builder = builder
  }

  private mutating func finishActiveTextElement(_ localName: String) {
    guard builder != nil else { return }
    if localName == "drawtext" || localName == "shapecomment" || localName == "script" {
      let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        builder?.textParts.append(text)
      }
      textBuffer = ""
      textDepth = max(textDepth - 1, 0)
    } else if localName == "caption" {
      let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        builder?.captionParts.append(text)
      }
      textBuffer = ""
      textDepth = max(textDepth - 1, 0)
    }
  }
}
