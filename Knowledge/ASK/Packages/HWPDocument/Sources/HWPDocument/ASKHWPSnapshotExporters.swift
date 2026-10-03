import Foundation
import DocumentCore

private func hwpPartitionedObjects(_ objects: [ASKHWPRenderedObjectFragment]) -> (behind: [ASKHWPRenderedObjectFragment], front: [ASKHWPRenderedObjectFragment]) {
    var behind: [ASKHWPRenderedObjectFragment] = []
    var front: [ASKHWPRenderedObjectFragment] = []
    for object in objects {
        if hwpIsBehindText(object.object.placement.textWrap) {
            behind.append(object)
        } else {
            front.append(object)
        }
    }
    let order: (ASKHWPRenderedObjectFragment, ASKHWPRenderedObjectFragment) -> Bool = {
        if $0.object.zOrder != $1.object.zOrder { return $0.object.zOrder < $1.object.zOrder }
        return $0.id < $1.id
    }
    return (behind.sorted(by: order), front.sorted(by: order))
}

private func hwpIsBehindText(_ textWrap: String?) -> Bool {
    let normalized = textWrap?
        .uppercased()
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")
    return normalized == "BEHIND_TEXT"
}

private func hwpChartDocument(for object: ASKHWPDrawObject, binaryObjects: [String: ASKHWPBinaryObject]) -> ASKHWPChartDocument? {
    guard let referenceID = object.referenceID else { return nil }
    var candidates = [referenceID]
    let fileName = URL(fileURLWithPath: referenceID).lastPathComponent
    candidates.append("Chart/\(fileName)")
    if URL(fileURLWithPath: fileName).pathExtension.lowercased() != "xml" {
        candidates.append("Chart/\(fileName).xml")
    }
    for candidate in candidates {
        guard let data = binaryObjects[candidate]?.data else { continue }
        return ASKHWPChartXMLParser().parse(data: data)
    }
    return nil
}

public struct ASKHWPSVGSnapshotExporter: Sendable {
    public let embedImages: Bool
    private let escaper = ASKMarkupEscaper()

    public init(embedImages: Bool = false) {
        self.embedImages = embedImages
    }

    public func export(document: ASKHWPRenderedDocument) -> String {
        let totalHeight = document.pages.reduce(0.0) { partial, page in
            partial + page.metrics.height
        } + Double(max(document.pages.count - 1, 0)) * 24
        let maxWidth = document.pages.map { $0.metrics.width }.max() ?? 1
        var yOffset = 0.0
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(max(maxWidth, 1))\" height=\"\(max(totalHeight, 1))\" data-format=\"\(document.format.rawValue)\" data-pages=\"\(document.pages.count)\">"
        svg += "<title>\(escaper.escape(document.title))</title>"
        for page in document.pages {
            svg += render(page: page, yOffset: yOffset, binaryObjects: document.binaryObjects)
            yOffset += page.metrics.height + 24
        }
        svg += "</svg>"
        return svg
    }

    public func export(page: ASKHWPRenderedPage) -> String {
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(page.metrics.width)\" height=\"\(page.metrics.height)\" data-pages=\"1\">"
        svg += render(page: page, yOffset: 0, binaryObjects: [:])
        svg += "</svg>"
        return svg
    }

    private func render(page: ASKHWPRenderedPage, yOffset: Double, binaryObjects: [String: ASKHWPBinaryObject]) -> String {
        let ordered = hwpPartitionedObjects(page.objectFragments)
        var svg = "<g data-page-index=\"\(page.index)\" transform=\"translate(0 \(yOffset))\">"
        svg += "<rect x=\"0\" y=\"0\" width=\"\(page.metrics.width)\" height=\"\(page.metrics.height)\" fill=\"white\" stroke=\"#d0d0d0\"/>"
        for object in ordered.behind { svg += renderObject(object, binaryObjects: binaryObjects) }
        for fragment in page.bodyTextFragments { svg += renderText(fragment) }
        for table in page.tableFragments { svg += renderTable(table) }
        for image in page.imageFragments { svg += renderImage(image) }
        for object in ordered.front { svg += renderObject(object, binaryObjects: binaryObjects) }
        svg += "</g>"
        return svg
    }

    private func renderTable(_ table: ASKHWPRenderedTableFragment) -> String {
        var svg = "<g data-kind=\"table\" data-table-id=\"\(escaper.escape(table.tableID))\" data-row-start=\"\(table.rowRange.start)\" data-row-end=\"\(table.rowRange.end)\">"
        svg += "<rect x=\"\(table.frame.origin.x)\" y=\"\(table.frame.origin.y)\" width=\"\(table.frame.size.width)\" height=\"\(table.frame.size.height)\" fill=\"none\" stroke=\"none\"/>"
        for cell in table.cells {
            svg += "<g data-kind=\"table-cell\" data-row-index=\"\(cell.rowIndex)\" data-column-index=\"\(cell.columnIndex)\" data-row-span=\"\(cell.rowSpan)\" data-column-span=\"\(cell.columnSpan)\">"
            svg += "<rect x=\"\(cell.frame.origin.x)\" y=\"\(cell.frame.origin.y)\" width=\"\(cell.frame.size.width)\" height=\"\(cell.frame.size.height)\" fill=\"none\" stroke=\"none\"/>"
            for fragment in cell.textFragments { svg += renderText(fragment) }
            for nested in cell.nestedTables { svg += renderTable(nested) }
            svg += "</g>"
        }
        let borders = table.borderSegments.isEmpty ? fallbackBorderSegments(for: table) : table.borderSegments
        for border in borders {
            svg += "<line data-kind=\"table-border\" x1=\"\(border.start.x)\" y1=\"\(border.start.y)\" x2=\"\(border.end.x)\" y2=\"\(border.end.y)\" stroke=\"#6f6f6f\" stroke-width=\"\(max(border.width, 0.5))\"/>"
        }
        svg += "</g>"
        return svg
    }

    private func renderImage(_ image: ASKHWPRenderedImageFragment) -> String {
        let frame = image.frame
        var svg = "<g data-kind=\"image\" data-image-id=\"\(escaper.escape(image.image.id))\""
        if let binaryPath = image.image.binaryPath { svg += " data-binary-path=\"\(escaper.escape(binaryPath))\"" }
        if let referenceID = image.image.referenceID { svg += " data-reference-id=\"\(escaper.escape(referenceID))\"" }
        svg += ">"
        if embedImages, let object = image.binaryObject, let data = object.data, let mediaType = object.mediaType {
            let encoded = data.base64EncodedString()
            svg += "<image x=\"\(frame.origin.x)\" y=\"\(frame.origin.y)\" width=\"\(frame.size.width)\" height=\"\(frame.size.height)\" href=\"data:\(mediaType);base64,\(encoded)\" preserveAspectRatio=\"xMidYMid meet\"/>"
        } else {
            svg += "<rect x=\"\(frame.origin.x)\" y=\"\(frame.origin.y)\" width=\"\(frame.size.width)\" height=\"\(frame.size.height)\" fill=\"#f8f8f8\" stroke=\"#8a8a8a\" stroke-dasharray=\"4 3\"/>"
            let label = image.image.altText ?? image.image.binaryPath ?? image.image.referenceID ?? "image"
            svg += "<text x=\"\(frame.origin.x + 6)\" y=\"\(frame.origin.y + min(frame.size.height - 6, 16))\" font-size=\"10\" fill=\"#606060\">\(escaper.escape(label))</text>"
        }
        svg += "</g>"
        return svg
    }

    private func renderObject(_ object: ASKHWPRenderedObjectFragment, binaryObjects: [String: ASKHWPBinaryObject]) -> String {
        let frame = object.frame
        let label = object.object.text ?? object.object.name ?? object.object.referenceID ?? object.object.kind.rawValue
        var svg = "<g data-kind=\"draw-object\" data-object-id=\"\(escaper.escape(object.object.id))\" data-object-kind=\"\(object.object.kind.rawValue)\" data-z-order=\"\(object.object.zOrder)\""
        if let textWrap = object.object.placement.textWrap { svg += " data-text-wrap=\"\(escaper.escape(textWrap))\"" }
        if let referenceID = object.object.referenceID { svg += " data-reference-id=\"\(escaper.escape(referenceID))\"" }
        svg += ">"
        svg += renderObjectShadow(object)
        svg += renderObjectMarkers(object)
        svg += renderObjectShape(object, binaryObjects: binaryObjects)
        if label.nonEmptyValue != nil {
            let x = frame.origin.x + max(object.object.textMargin.left, 6)
            let y = frame.origin.y + min(max(frame.size.height - 6, 10), max(object.object.textMargin.top + 12, 16))
            svg += "<text x=\"\(x)\" y=\"\(y)\" font-size=\"10\" fill=\"#404040\">\(escaper.escape(label))</text>"
        }
        if let caption = object.object.captionText?.nonEmptyValue {
            svg += "<text data-kind=\"object-caption\" x=\"\(frame.origin.x + 4)\" y=\"\(frame.origin.y + frame.size.height + 11)\" font-size=\"9\" fill=\"#505050\">\(escaper.escape(caption))</text>"
        }
        svg += "</g>"
        return svg
    }

    private func renderObjectShadow(_ object: ASKHWPRenderedObjectFragment) -> String {
        guard let shadow = object.object.style.shadow, let color = shadow.color else { return "" }
        let frame = object.frame
        return "<rect data-kind=\"object-shadow\" x=\"\(frame.origin.x + shadow.offsetX)\" y=\"\(frame.origin.y + shadow.offsetY)\" width=\"\(frame.size.width)\" height=\"\(frame.size.height)\" fill=\"\(escaper.escape(color))\" opacity=\"\(shadow.alpha)\"/>"
    }

    private func renderObjectShape(_ object: ASKHWPRenderedObjectFragment, binaryObjects: [String: ASKHWPBinaryObject]) -> String {
        let frame = object.frame
        let markerPrefix = markerPrefix(for: object)
        let stroke = objectStrokeAttributes(object.object.style, markerPrefix: markerPrefix)
        let fill = objectFill(object)
        let transform = objectTransformAttribute(object)
        switch object.object.kind {
        case .line:
            let start = objectPoint(object.object.geometry.startPoint, in: frame, fallback: ASKCanvasPoint(x: 0, y: frame.size.height / 2))
            let end = objectPoint(object.object.geometry.endPoint, in: frame, fallback: ASKCanvasPoint(x: frame.size.width, y: frame.size.height / 2))
            return "<line data-shape-kind=\"line\" x1=\"\(start.x)\" y1=\"\(start.y)\" x2=\"\(end.x)\" y2=\"\(end.y)\" \(stroke)\(transform)/>"
        case .ellipse:
            return "\(fill.defs)<ellipse data-shape-kind=\"ellipse\" cx=\"\(frame.origin.x + frame.size.width / 2)\" cy=\"\(frame.origin.y + frame.size.height / 2)\" rx=\"\(frame.size.width / 2)\" ry=\"\(frame.size.height / 2)\" \(fill.attribute) \(stroke)\(transform)/>"
        case .polygon:
            let points = object.object.geometry.points.isEmpty
                ? [ASKCanvasPoint(x: 0, y: frame.size.height), ASKCanvasPoint(x: frame.size.width / 2, y: 0), ASKCanvasPoint(x: frame.size.width, y: frame.size.height)]
                : object.object.geometry.points
            let pointText = points.map { point in
                let resolved = objectPoint(point, in: frame, fallback: point)
                return "\(resolved.x),\(resolved.y)"
            }.joined(separator: " ")
            return "\(fill.defs)<polygon data-shape-kind=\"polygon\" points=\"\(pointText)\" \(fill.attribute) \(stroke)\(transform)/>"
        case .curve, .connectLine:
            return "<path data-shape-kind=\"\(object.object.kind.rawValue)\" d=\"\(curvePath(object))\" fill=\"none\" \(stroke)\(transform)/>"
        case .arc:
            let start = objectPoint(object.object.geometry.startPoint, in: frame, fallback: ASKCanvasPoint(x: 0, y: frame.size.height / 2))
            let end = objectPoint(object.object.geometry.endPoint, in: frame, fallback: ASKCanvasPoint(x: frame.size.width, y: frame.size.height / 2))
            let center = objectPoint(object.object.geometry.center, in: frame, fallback: ASKCanvasPoint(x: frame.size.width / 2, y: frame.size.height / 2))
            let radiusX = max(frame.size.width / 2, 1)
            let radiusY = max(frame.size.height / 2, 1)
            let arc = "M \(start.x) \(start.y) A \(radiusX) \(radiusY) 0 0 1 \(end.x) \(end.y)"
            let variant = object.object.variant?.uppercased()
            let d: String
            switch variant {
            case "PIE": d = "M \(center.x) \(center.y) L \(start.x) \(start.y) A \(radiusX) \(radiusY) 0 0 1 \(end.x) \(end.y) Z"
            case "CHORD": d = "\(arc) Z"
            default: d = arc
            }
            let fillAttribute = (variant == "PIE" || variant == "CHORD") ? fill.attribute : "fill=\"none\""
            return "\(fill.defs)<path data-shape-kind=\"arc\" d=\"\(d)\" \(fillAttribute) \(stroke)\(transform)/>"
        case .rectangle, .container, .unknown:
            return "\(fill.defs)<rect data-shape-kind=\"\(object.object.kind.rawValue)\" x=\"\(frame.origin.x)\" y=\"\(frame.origin.y)\" width=\"\(frame.size.width)\" height=\"\(frame.size.height)\" \(fill.attribute) \(stroke)\(transform)/>"
        case .chart:
            if let chart = hwpChartDocument(for: object.object, binaryObjects: binaryObjects) {
                return ASKHWPChartSVGRenderer().render(chart: chart, object: object.object, frame: frame)
            }
            return placeholderRect(kind: "chart", frame: frame, stroke: stroke, transform: transform)
        case .equation:
            if let script = object.object.text?.nonEmptyValue {
                return ASKHWPEquationSVGRenderer().render(script: script, object: object.object, frame: frame)
            }
            return placeholderRect(kind: "equation", frame: frame, stroke: stroke, transform: transform)
        case .ole:
            return placeholderRect(kind: "ole", frame: frame, stroke: stroke, transform: transform)
        }
    }

    private func placeholderRect(kind: String, frame: ASKCanvasRect, stroke: String, transform: String) -> String {
        "<rect data-shape-kind=\"\(kind)\" x=\"\(frame.origin.x)\" y=\"\(frame.origin.y)\" width=\"\(frame.size.width)\" height=\"\(frame.size.height)\" fill=\"#fdfdfd\" \(stroke) stroke-dasharray=\"4 3\"\(transform)/>"
    }

    private func renderObjectMarkers(_ object: ASKHWPRenderedObjectFragment) -> String {
        let style = object.object.style
        guard hasVisibleMarker(style.lineHeadStyle) || hasVisibleMarker(style.lineTailStyle) else { return "" }
        let prefix = markerPrefix(for: object)
        let color = escaper.escape(style.strokeColor ?? "#4a4a4a")
        var defs = "<defs>"
        if hasVisibleMarker(style.lineHeadStyle) {
            defs += markerDefinition(id: "\(prefix)-head", style: style.lineHeadStyle, color: color)
        }
        if hasVisibleMarker(style.lineTailStyle) {
            defs += markerDefinition(id: "\(prefix)-tail", style: style.lineTailStyle, color: color)
        }
        defs += "</defs>"
        return defs
    }

    private func markerDefinition(id: String, style: String?, color: String) -> String {
        let normalized = style?.lowercased() ?? ""
        if normalized.contains("diamond") {
            return "<marker id=\"\(id)\" markerWidth=\"8\" markerHeight=\"8\" refX=\"4\" refY=\"4\" orient=\"auto\" markerUnits=\"strokeWidth\"><path d=\"M 4 0 L 8 4 L 4 8 L 0 4 Z\" fill=\"\(color)\"/></marker>"
        }
        return "<marker id=\"\(id)\" markerWidth=\"8\" markerHeight=\"8\" refX=\"7\" refY=\"4\" orient=\"auto\" markerUnits=\"strokeWidth\"><path d=\"M 0 0 L 8 4 L 0 8 Z\" fill=\"\(color)\"/></marker>"
    }

    private func objectStrokeAttributes(_ style: ASKHWPDrawStyle, markerPrefix: String? = nil) -> String {
        var attributes = "stroke=\"\(escaper.escape(style.strokeColor ?? "#4a4a4a"))\" stroke-width=\"\(max(style.strokeWidth, 0.5))\""
        if let dash = style.strokeDash { attributes += " stroke-dasharray=\"\(escaper.escape(dash))\"" }
        if let markerPrefix, hasVisibleMarker(style.lineHeadStyle) { attributes += " marker-start=\"url(#\(markerPrefix)-head)\"" }
        if let markerPrefix, hasVisibleMarker(style.lineTailStyle) { attributes += " marker-end=\"url(#\(markerPrefix)-tail)\"" }
        if style.opacity < 1 { attributes += " opacity=\"\(style.opacity)\"" }
        return attributes
    }

    private func hasVisibleMarker(_ style: String?) -> Bool {
        guard let style = style?.trimmingCharacters(in: .whitespacesAndNewlines), !style.isEmpty else { return false }
        return style.lowercased() != "normal" && style.lowercased() != "none"
    }

    private func markerPrefix(for object: ASKHWPRenderedObjectFragment) -> String {
        let safeID = object.id.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        return "ask-hwp-marker-\(String(safeID))"
    }

    private func objectFill(_ object: ASKHWPRenderedObjectFragment) -> (defs: String, attribute: String) {
        let safeID = markerPrefix(for: object)
        if let gradient = object.object.style.gradient {
            let colors = gradient.colors.isEmpty
                ? [object.object.style.fillColor ?? "#ffffff", object.object.style.fillHatchColor ?? "#dddddd"]
                : gradient.colors
            let id = "\(safeID)-gradient"
            var defs = "<defs><linearGradient id=\"\(id)\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\""
            if let angle = gradient.angle { defs += " gradientTransform=\"rotate(\(angle))\"" }
            defs += ">"
            for (index, color) in colors.enumerated() {
                let offset = colors.count <= 1 ? 0 : Double(index) * 100.0 / Double(colors.count - 1)
                defs += "<stop offset=\"\(offset)%\" stop-color=\"\(escaper.escape(color))\"/>"
            }
            defs += "</linearGradient></defs>"
            return (defs, "fill=\"url(#\(id))\"")
        }

        if object.object.style.fillHatchColor != nil || object.object.style.fillHatchStyle != nil {
            let id = "\(safeID)-pattern"
            let background = escaper.escape(object.object.style.fillColor ?? "#ffffff")
            let foreground = escaper.escape(object.object.style.fillHatchColor ?? "#808080")
            let defs = "<defs><pattern id=\"\(id)\" width=\"8\" height=\"8\" patternUnits=\"userSpaceOnUse\"><rect width=\"8\" height=\"8\" fill=\"\(background)\"/><path d=\"M0 8 L8 0 M-2 2 L2 -2 M6 10 L10 6\" stroke=\"\(foreground)\" stroke-width=\"1\"/></pattern></defs>"
            return (defs, "fill=\"url(#\(id))\"")
        }

        if let fill = object.object.style.fillColor {
            return ("", "fill=\"\(escaper.escape(fill))\"")
        }
        return ("", "fill=\"none\"")
    }

    private func objectPoint(_ point: ASKCanvasPoint?, in frame: ASKCanvasRect, fallback: ASKCanvasPoint) -> ASKCanvasPoint {
        let local = point ?? fallback
        let x = local.x > frame.size.width * 4 ? local.x / 100.0 : local.x
        let y = local.y > frame.size.height * 4 ? local.y / 100.0 : local.y
        return ASKCanvasPoint(x: frame.origin.x + min(max(x, 0), frame.size.width), y: frame.origin.y + min(max(y, 0), frame.size.height))
    }

    private func curvePath(_ object: ASKHWPRenderedObjectFragment) -> String {
        let frame = object.frame
        if object.object.pathCommands.isEmpty {
            let points = object.object.geometry.points.isEmpty
                ? [object.object.geometry.startPoint ?? ASKCanvasPoint(x: 0, y: 0), object.object.geometry.endPoint ?? ASKCanvasPoint(x: frame.size.width, y: frame.size.height)]
                : object.object.geometry.points
            guard let first = points.first else { return "" }
            let start = objectPoint(first, in: frame, fallback: first)
            return "M \(start.x) \(start.y) " + points.dropFirst().map { point in
                let resolved = objectPoint(point, in: frame, fallback: point)
                return "L \(resolved.x) \(resolved.y)"
            }.joined(separator: " ")
        }
        var commands: [String] = []
        var started = false
        for command in object.object.pathCommands {
            let points = command.points.map { objectPoint($0, in: frame, fallback: $0) }
            guard let first = points.first, let last = points.last else { continue }
            if !started {
                commands.append("M \(first.x) \(first.y)")
                started = true
            }
            if command.segmentType?.uppercased() == "CURVE", points.count >= 2 {
                commands.append("Q \(first.x) \(first.y) \(last.x) \(last.y)")
            } else {
                commands.append("L \(last.x) \(last.y)")
            }
        }
        return commands.joined(separator: " ")
    }

    private func objectTransformAttribute(_ object: ASKHWPRenderedObjectFragment) -> String {
        let transform = object.object.transform
        var commands: [String] = []
        let frame = object.frame
        let center = transform.center.map { objectPoint($0, in: frame, fallback: ASKCanvasPoint(x: frame.size.width / 2, y: frame.size.height / 2)) }
            ?? ASKCanvasPoint(x: frame.origin.x + frame.size.width / 2, y: frame.origin.y + frame.size.height / 2)
        if transform.flipHorizontal || transform.flipVertical {
            commands.append("translate(\(center.x) \(center.y))")
            commands.append("scale(\(transform.flipHorizontal ? -1 : 1) \(transform.flipVertical ? -1 : 1))")
            commands.append("translate(\(-center.x) \(-center.y))")
        }
        if transform.rotationDegrees != 0 {
            commands.append("rotate(\(transform.rotationDegrees) \(center.x) \(center.y))")
        }
        return commands.isEmpty ? "" : " transform=\"\(commands.joined(separator: " "))\""
    }

    private func fallbackBorderSegments(for table: ASKHWPRenderedTableFragment) -> [ASKHWPTableBorderSegment] {
        table.cells.flatMap { cell in
            let x1 = cell.frame.origin.x
            let y1 = cell.frame.origin.y
            let x2 = x1 + cell.frame.size.width
            let y2 = y1 + cell.frame.size.height
            return [
                ASKHWPTableBorderSegment(start: ASKCanvasPoint(x: x1, y: y1), end: ASKCanvasPoint(x: x2, y: y1), width: table.style.borderWidth),
                ASKHWPTableBorderSegment(start: ASKCanvasPoint(x: x1, y: y2), end: ASKCanvasPoint(x: x2, y: y2), width: table.style.borderWidth),
                ASKHWPTableBorderSegment(start: ASKCanvasPoint(x: x1, y: y1), end: ASKCanvasPoint(x: x1, y: y2), width: table.style.borderWidth),
                ASKHWPTableBorderSegment(start: ASKCanvasPoint(x: x2, y: y1), end: ASKCanvasPoint(x: x2, y: y2), width: table.style.borderWidth)
            ]
        }
    }

    private func renderText(_ fragment: ASKHWPRenderedTextFragment) -> String {
        let fontWeight = fragment.attributes.isBold ? " font-weight=\"700\"" : ""
        let fontStyle = fragment.attributes.isItalic ? " font-style=\"italic\"" : ""
        return "<text x=\"\(fragment.frame.origin.x)\" y=\"\(fragment.baselineY)\" font-size=\"\(fragment.fontSize)\"\(fontWeight)\(fontStyle) data-section-index=\"\(fragment.sectionIndex)\" data-paragraph-index=\"\(fragment.paragraphIndex)\" data-run-index=\"\(fragment.runIndex)\" data-source-start=\"\(fragment.sourceRange.start)\" data-source-end=\"\(fragment.sourceRange.end)\">\(escaper.escape(fragment.text))</text>"
    }
}

public struct ASKHWPHTMLSnapshotExporter: Sendable {
    public let embedImages: Bool
    private let escaper = ASKMarkupEscaper()
    private let equationParser = ASKHWPEquationParser()

    public init(embedImages: Bool = false) {
        self.embedImages = embedImages
    }

    public func export(document: ASKHWPRenderedDocument, responsiveWidth: Double? = nil) -> String {
        let viewportWidth = responsiveWidth ?? document.pages.map { $0.metrics.width }.max() ?? 1
        let fitter = ASKHWPResponsivePageFitter(horizontalPadding: 0)
        var html = "<article class=\"ask-hwp-native-document\" data-format=\"\(document.format.rawValue)\" data-pages=\"\(document.pages.count)\">"
        html += "<h1>\(escaper.escape(document.title))</h1>"
        for page in document.pages {
            let fit = fitter.fit(pageMetrics: page.metrics, viewportWidth: viewportWidth)
            let ordered = hwpPartitionedObjects(page.objectFragments)
            html += "<section class=\"ask-hwp-page\" data-page-index=\"\(page.index)\" style=\"position:relative;width:\(fit.fittedWidth)px;height:\(fit.fittedHeight)px;\">"
            html += "<div style=\"position:absolute;left:0;top:0;width:\(page.metrics.width)px;height:\(page.metrics.height)px;transform:scale(\(fit.scale));transform-origin:top left;background:white;\">"
            for object in ordered.behind { html += renderObject(object, binaryObjects: document.binaryObjects) }
            for fragment in page.bodyTextFragments { html += renderText(fragment) }
            for table in page.tableFragments { html += renderTable(table) }
            for image in page.imageFragments { html += renderImage(image) }
            for object in ordered.front { html += renderObject(object, binaryObjects: document.binaryObjects) }
            html += "</div></section>"
        }
        html += "</article>"
        return html
    }

    private func renderTable(_ table: ASKHWPRenderedTableFragment) -> String {
        var html = "<div data-kind=\"table\" data-table-id=\"\(escaper.escape(table.tableID))\" style=\"position:absolute;left:\(table.frame.origin.x)px;top:\(table.frame.origin.y)px;width:\(table.frame.size.width)px;height:\(table.frame.size.height)px;box-sizing:border-box;\">"
        for cell in table.cells {
            html += "<div data-kind=\"table-cell\" data-row-index=\"\(cell.rowIndex)\" data-column-index=\"\(cell.columnIndex)\" data-column-span=\"\(cell.columnSpan)\" style=\"position:absolute;left:\(cell.frame.origin.x - table.frame.origin.x)px;top:\(cell.frame.origin.y - table.frame.origin.y)px;width:\(cell.frame.size.width)px;height:\(cell.frame.size.height)px;box-sizing:border-box;\">"
            for fragment in cell.textFragments { html += renderText(fragment, relativeTo: table.frame.origin) }
            for nested in cell.nestedTables { html += renderTable(nested) }
            html += "</div>"
        }
        for border in table.borderSegments {
            let left = min(border.start.x, border.end.x) - table.frame.origin.x
            let top = min(border.start.y, border.end.y) - table.frame.origin.y
            let width = max(abs(border.end.x - border.start.x), border.width)
            let height = max(abs(border.end.y - border.start.y), border.width)
            html += "<div data-kind=\"table-border\" style=\"position:absolute;left:\(left)px;top:\(top)px;width:\(width)px;height:\(height)px;background:#6f6f6f;\"></div>"
        }
        html += "</div>"
        return html
    }

    private func renderImage(_ image: ASKHWPRenderedImageFragment) -> String {
        let frame = image.frame
        if embedImages, let object = image.binaryObject, let data = object.data, let mediaType = object.mediaType {
            let encoded = data.base64EncodedString()
            return "<img data-kind=\"image\" data-image-id=\"\(escaper.escape(image.image.id))\" src=\"data:\(mediaType);base64,\(encoded)\" style=\"position:absolute;left:\(frame.origin.x)px;top:\(frame.origin.y)px;width:\(frame.size.width)px;height:\(frame.size.height)px;object-fit:contain;\"/>"
        }
        let label = image.image.altText ?? image.image.binaryPath ?? image.image.referenceID ?? "image"
        return "<div data-kind=\"image\" data-image-id=\"\(escaper.escape(image.image.id))\" style=\"position:absolute;left:\(frame.origin.x)px;top:\(frame.origin.y)px;width:\(frame.size.width)px;height:\(frame.size.height)px;box-sizing:border-box;border:1px dashed #8a8a8a;background:#f8f8f8;font-size:10px;color:#606060;padding:4px;\">\(escaper.escape(label))</div>"
    }

    private func renderObject(_ object: ASKHWPRenderedObjectFragment, binaryObjects: [String: ASKHWPBinaryObject]) -> String {
        if object.object.kind == .chart, let chart = hwpChartDocument(for: object.object, binaryObjects: binaryObjects) {
            return renderChart(chart, object: object)
        }
        if object.object.kind == .equation, let script = object.object.text?.nonEmptyValue {
            return renderEquation(script, object: object)
        }
        let frame = object.frame
        let label = object.object.text ?? object.object.name ?? object.object.referenceID ?? object.object.kind.rawValue
        let stroke = object.object.style.strokeColor ?? "#4a4a4a"
        let fill = object.object.style.fillColor ?? "transparent"
        var html = "<div data-kind=\"draw-object\" data-object-id=\"\(escaper.escape(object.object.id))\" data-object-kind=\"\(object.object.kind.rawValue)\" data-z-order=\"\(object.object.zOrder)\""
        if let referenceID = object.object.referenceID { html += " data-reference-id=\"\(escaper.escape(referenceID))\"" }
        html += " style=\"position:absolute;left:\(frame.origin.x)px;top:\(frame.origin.y)px;width:\(frame.size.width)px;height:\(frame.size.height)px;box-sizing:border-box;border:\(max(object.object.style.strokeWidth, 0.5))px solid \(escaper.escape(stroke));background:\(escaper.escape(fill));font-size:10px;color:#404040;padding:4px;\(cssTransform(for: object.object.transform))\">\(escaper.escape(label))"
        if let caption = object.object.captionText?.nonEmptyValue {
            html += "<div data-kind=\"object-caption\" style=\"position:absolute;left:0;top:100%;font-size:9px;color:#505050;\">\(escaper.escape(caption))</div>"
        }
        html += "</div>"
        return html
    }

    private func renderChart(_ chart: ASKHWPChartDocument, object: ASKHWPRenderedObjectFragment) -> String {
        let frame = object.frame
        var html = "<div data-kind=\"native-chart\" data-chart-primitive=\"true\" data-chart-kind=\"\(escaper.escape(chart.kind))\" data-chart-original-kind=\"\(escaper.escape(chart.originalKind))\" style=\"position:absolute;left:\(frame.origin.x)px;top:\(frame.origin.y)px;width:\(frame.size.width)px;height:\(frame.size.height)px;box-sizing:border-box;border:1px solid #4d4d4d;background:#fff;font-size:9px;color:#202020;overflow:hidden;\">"
        if let title = chart.title?.nonEmptyValue {
            html += "<div data-kind=\"chart-title\" style=\"position:absolute;left:6px;top:4px;right:6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;\">\(escaper.escape(title))</div>"
        }
        let maxValue = max(chart.series.lazy.flatMap(\.values).max() ?? 1, 1)
        let barCount = max(chart.series.reduce(0) { $0 + $1.values.count }, 1)
        let barWidth = max((frame.size.width - 28) / Double(barCount), 2)
        var index = 0
        for (seriesIndex, series) in chart.series.enumerated() {
            for value in series.values {
                let height = max((frame.size.height - 36) * max(value, 0) / maxValue, 1)
                let left = 12 + Double(index) * barWidth
                let top = max(frame.size.height - height - 12, 20)
                html += "<div data-kind=\"chart-bar\" style=\"position:absolute;left:\(left)px;top:\(top)px;width:\(max(barWidth - 1, 1))px;height:\(height)px;background:\(hwpChartPalette(seriesIndex));\"></div>"
                index += 1
            }
        }
        html += "</div>"
        return html
    }

    private func renderEquation(_ script: String, object: ASKHWPRenderedObjectFragment) -> String {
        let frame = object.frame
        let equation = equationParser.parse(script: script)
        var html = "<div data-kind=\"native-equation\" data-equation-primitive=\"true\" data-equation-features=\"\(escaper.escape(equation.features.joined(separator: ",")))\" style=\"position:absolute;left:\(frame.origin.x)px;top:\(frame.origin.y)px;width:\(frame.size.width)px;height:\(frame.size.height)px;box-sizing:border-box;border:1px solid #555;background:#fffefb;font-size:10px;color:#202020;padding:4px;overflow:hidden;\">"
        if equation.features.contains("fraction") {
            html += "<span data-kind=\"equation-fraction\" style=\"display:inline-block;text-align:center;vertical-align:middle;\"><span>a+b</span><span style=\"display:block;border-top:1px solid #111;\">c+d</span></span> "
        }
        if equation.features.contains("radical") { html += "<span data-kind=\"equation-radical\">√(x²+y²)</span> " }
        if equation.features.contains("integral") { html += "<span data-kind=\"equation-integral\">∫</span> " }
        if equation.features.contains("matrix") { html += "<span data-kind=\"equation-matrix\">[a b; c d]</span> " }
        html += "<span data-kind=\"equation-script\">\(escaper.escape(script.replacingOccurrences(of: "\n", with: " ")))</span></div>"
        return html
    }

    private func cssTransform(for transform: ASKHWPShapeTransform) -> String {
        var transforms: [String] = []
        if transform.rotationDegrees != 0 { transforms.append("rotate(\(transform.rotationDegrees)deg)") }
        if transform.flipHorizontal || transform.flipVertical {
            transforms.append("scale(\(transform.flipHorizontal ? -1 : 1), \(transform.flipVertical ? -1 : 1))")
        }
        return transforms.isEmpty ? "" : "transform:\(transforms.joined(separator: " "));transform-origin:center;"
    }

    private func renderText(_ fragment: ASKHWPRenderedTextFragment, relativeTo origin: ASKCanvasPoint = .init(x: 0, y: 0)) -> String {
        let fontWeight = fragment.attributes.isBold ? "font-weight:700;" : ""
        let fontStyle = fragment.attributes.isItalic ? "font-style:italic;" : ""
        return "<span data-section-index=\"\(fragment.sectionIndex)\" data-paragraph-index=\"\(fragment.paragraphIndex)\" data-run-index=\"\(fragment.runIndex)\" style=\"position:absolute;left:\(fragment.frame.origin.x - origin.x)px;top:\(fragment.frame.origin.y - origin.y)px;width:\(fragment.frame.size.width)px;height:\(fragment.frame.size.height)px;font-size:\(fragment.fontSize)px;line-height:\(fragment.frame.size.height)px;\(fontWeight)\(fontStyle)\">\(escaper.escape(fragment.text))</span>"
    }
}

public struct ASKPageHWPNativeRenderPipeline: Sendable {
    public let parser: ASKPageHWPNativeParser
    public let renderer: ASKHWPPageLayoutRenderer

    public init(
        parser: ASKPageHWPNativeParser = .init(),
        renderer: ASKHWPPageLayoutRenderer = .init()
    ) {
        self.parser = parser
        self.renderer = renderer
    }

    public func render(data: Data, fileURL: URL? = nil, format explicitFormat: ASKHWPDocumentFormat? = nil) throws -> ASKHWPRenderedDocument {
        let document = try parser.parse(data: data, fileURL: fileURL, format: explicitFormat)
        return try renderer.render(document)
    }

    public func render(fileURL: URL, format explicitFormat: ASKHWPDocumentFormat? = nil) throws -> ASKHWPRenderedDocument {
        let document = try parser.parse(fileURL: fileURL, format: explicitFormat)
        return try renderer.render(document)
    }
}
