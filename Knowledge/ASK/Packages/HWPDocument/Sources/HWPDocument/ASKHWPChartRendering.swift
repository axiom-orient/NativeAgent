import Foundation
import DocumentCore
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct ASKHWPChartDocument: Sendable, Hashable, Codable {
    public let kind: String
    public let originalKind: String
    public let title: String?
    public let series: [ASKHWPChartSeries]
    public let unsupportedFeatures: [String]

    public init(kind: String, originalKind: String, title: String? = nil, series: [ASKHWPChartSeries] = [], unsupportedFeatures: [String] = []) {
        self.kind = kind
        self.originalKind = originalKind
        self.title = title
        self.series = series
        self.unsupportedFeatures = unsupportedFeatures
    }
}

public struct ASKHWPChartSeries: Sendable, Hashable, Codable {
    public let name: String
    public let categories: [String]
    public let values: [Double]

    public init(name: String, categories: [String] = [], values: [Double] = []) {
        self.name = name
        self.categories = categories
        self.values = values
    }
}

public struct ASKHWPChartXMLParser: Sendable {
    public init() {}

    public func parse(data: Data) -> ASKHWPChartDocument? {
        let delegate = ChartXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return delegate.makeDocument()
    }
}

private final class ChartXMLDelegate: NSObject, XMLParserDelegate {
    private static let unsupportedChartElements: Set<String> = [
        "trendline", "errbars", "datalabels", "updownbars", "surfacechart", "surface3dchart"
    ]
    private var stack: [String] = []
    private var kind: String?
    private var originalKind: String?
    private var title: String?
    private var sawChartSpace = false
    private var series: [ASKHWPChartSeries] = []
    private var currentSeriesName: String?
    private var currentCategories: [String] = []
    private var currentValues: [Double] = []
    private var text = ""
    private var textElement: String?
    private var unsupportedFeatures = Set<String>()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let localName = xmlLocalName(elementName).lowercased()
        stack.append(localName)
        if localName == "chartspace" { sawChartSpace = true }
        if let chartKind = Self.chartKind(for: localName) {
            originalKind = originalKind ?? chartKind.original
            kind = kind ?? chartKind.normalized
        }
        if localName == "ser" {
            currentSeriesName = nil
            currentCategories = []
            currentValues = []
        }
        if localName == "v" || localName == "t" {
            textElement = localName
            text = ""
        }
        if Self.unsupportedChartElements.contains(localName) {
            unsupportedFeatures.insert(localName)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textElement != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localName = xmlLocalName(elementName).lowercased()
        if localName == textElement {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { capture(value: value) }
            text = ""
            textElement = nil
        }
        if localName == "ser" {
            let name = currentSeriesName?.nonEmptyValue ?? "Series \(series.count + 1)"
            series.append(ASKHWPChartSeries(name: name, categories: currentCategories, values: currentValues))
            currentSeriesName = nil
            currentCategories = []
            currentValues = []
        }
        if !stack.isEmpty { stack.removeLast() }
    }

    func makeDocument() -> ASKHWPChartDocument? {
        guard sawChartSpace || kind != nil else { return nil }
        return ASKHWPChartDocument(
            kind: kind ?? "unknown",
            originalKind: originalKind ?? "unknown",
            title: title,
            series: series,
            unsupportedFeatures: Array(unsupportedFeatures).sorted()
        )
    }

    private func capture(value: String) {
        if stack.contains("title"), !stack.contains("ser") {
            title = title ?? value
            return
        }
        guard stack.contains("ser") else { return }
        if stack.contains("tx") {
            currentSeriesName = currentSeriesName ?? value
        } else if stack.contains("cat") {
            currentCategories.append(value)
        } else if stack.contains("val") || stack.contains("yval") || stack.contains("xval") || stack.contains("bubblesize") {
            if let number = Double(value) {
                currentValues.append(number)
            }
        }
    }

    private static func chartKind(for localName: String) -> (normalized: String, original: String)? {
        switch localName {
        case "barchart": return ("bar", "bar")
        case "bar3dchart": return ("bar", "bar3D")
        case "linechart": return ("line", "line")
        case "line3dchart": return ("line", "line3D")
        case "piechart": return ("pie", "pie")
        case "pie3dchart": return ("pie", "pie3D")
        case "doughnutchart": return ("doughnut", "doughnut")
        case "ofpiechart": return ("pie", "ofPie")
        case "scatterchart": return ("scatter", "scatter")
        case "areachart": return ("area", "area")
        case "area3dchart": return ("area", "area3D")
        case "radarchart": return ("radar", "radar")
        case "bubblechart": return ("bubble", "bubble")
        case "stockchart": return ("stock", "stock")
        default: return nil
        }
    }
}

public struct ASKHWPChartSVGRenderer: Sendable {
    private let escaper = ASKMarkupEscaper()

    public init() {}

    public func render(chart: ASKHWPChartDocument, object: ASKHWPDrawObject, frame: ASKCanvasRect) -> String {
        let plot = plotFrame(in: frame)
        var svg = "<g data-kind=\"native-chart\" data-chart-primitive=\"true\" data-chart-kind=\"\(escaper.escape(chart.kind))\" data-chart-original-kind=\"\(escaper.escape(chart.originalKind))\""
        if let referenceID = object.referenceID { svg += " data-reference-id=\"\(escaper.escape(referenceID))\"" }
        if !chart.unsupportedFeatures.isEmpty { svg += " data-unsupported-chart-feature=\"\(escaper.escape(chart.unsupportedFeatures.joined(separator: ",")))\"" }
        svg += ">"
        svg += "<rect x=\"\(frame.origin.x)\" y=\"\(frame.origin.y)\" width=\"\(frame.size.width)\" height=\"\(frame.size.height)\" fill=\"#ffffff\" stroke=\"#4d4d4d\" stroke-width=\"0.8\"/>"
        if let title = chart.title?.nonEmptyValue {
            svg += "<text data-kind=\"chart-title\" x=\"\(frame.origin.x + 8)\" y=\"\(frame.origin.y + 15)\" font-size=\"10\" fill=\"#202020\">\(escaper.escape(title))</text>"
        }
        switch chart.kind {
        case "pie", "doughnut":
            svg += renderPie(chart: chart, plot: plot, doughnut: chart.kind == "doughnut")
        case "line", "scatter", "bubble", "radar", "stock", "area":
            svg += renderPointChart(chart: chart, plot: plot, mode: chart.kind)
        default:
            svg += renderBar(chart: chart, plot: plot)
        }
        svg += renderLegend(chart: chart, frame: frame)
        svg += "</g>"
        return svg
    }

    private func plotFrame(in frame: ASKCanvasRect) -> ASKCanvasRect {
        ASKCanvasRect(x: frame.origin.x + 24, y: frame.origin.y + 24, width: max(frame.size.width - 44, 1), height: max(frame.size.height - 48, 1))
    }

    private func renderBar(chart: ASKHWPChartDocument, plot: ASKCanvasRect) -> String {
        let maxValue = max(chart.series.lazy.flatMap(\.values).max() ?? 1, 1)
        let categoryCount = max(chart.series.map { max($0.values.count, $0.categories.count) }.max() ?? 1, 1)
        let slotWidth = plot.size.width / Double(categoryCount)
        let barWidth = max(slotWidth / Double(max(chart.series.count, 1)) * 0.7, 1)
        var svg = axis(plot)
        for (seriesIndex, series) in chart.series.enumerated() {
            for (index, value) in series.values.enumerated() {
                let height = plot.size.height * max(value, 0) / maxValue
                let x = plot.origin.x + Double(index) * slotWidth + Double(seriesIndex) * barWidth + slotWidth * 0.12
                let y = plot.origin.y + plot.size.height - height
                svg += "<rect data-kind=\"chart-bar\" x=\"\(x)\" y=\"\(y)\" width=\"\(barWidth)\" height=\"\(height)\" fill=\"\(palette(seriesIndex))\"/>"
            }
        }
        return svg
    }

    private func renderPointChart(chart: ASKHWPChartDocument, plot: ASKCanvasRect, mode: String) -> String {
        let maxValue = max(chart.series.lazy.flatMap(\.values).max() ?? 1, 1)
        var svg = axis(plot)
        for (seriesIndex, series) in chart.series.enumerated() {
            let count = max(series.values.count, 1)
            let points = series.values.enumerated().map { index, value in
                let x = plot.origin.x + (count <= 1 ? plot.size.width / 2 : Double(index) * plot.size.width / Double(count - 1))
                let y = plot.origin.y + plot.size.height - plot.size.height * max(value, 0) / maxValue
                return ASKCanvasPoint(x: x, y: y)
            }
            if mode == "area", let first = points.first, let last = points.last {
                let d = "M \(first.x) \(plot.origin.y + plot.size.height) L " + points.map { "\($0.x) \($0.y)" }.joined(separator: " L ") + " L \(last.x) \(plot.origin.y + plot.size.height) Z"
                svg += "<path data-kind=\"chart-area\" d=\"\(d)\" fill=\"\(palette(seriesIndex))\" opacity=\"0.25\"/>"
            }
            if mode != "scatter" && mode != "bubble" {
                svg += "<polyline data-kind=\"chart-line\" points=\"\(points.map { "\($0.x),\($0.y)" }.joined(separator: " "))\" fill=\"none\" stroke=\"\(palette(seriesIndex))\" stroke-width=\"1.5\"/>"
            }
            for point in points {
                let radius = mode == "bubble" ? 4.5 : 2.5
                svg += "<circle data-kind=\"chart-point\" cx=\"\(point.x)\" cy=\"\(point.y)\" r=\"\(radius)\" fill=\"\(palette(seriesIndex))\"/>"
            }
        }
        return svg
    }

    private func renderPie(chart: ASKHWPChartDocument, plot: ASKCanvasRect, doughnut: Bool) -> String {
        let values = chart.series.first?.values ?? []
        let total = max(values.reduce(0, +), 1)
        let center = ASKCanvasPoint(x: plot.origin.x + plot.size.width / 2, y: plot.origin.y + plot.size.height / 2)
        let radius = max(min(plot.size.width, plot.size.height) / 2 - 4, 1)
        var startAngle = -Double.pi / 2
        var svg = ""
        for (index, value) in values.enumerated() {
            let angle = Double.pi * 2 * max(value, 0) / total
            let endAngle = startAngle + angle
            let largeArc = angle > Double.pi ? 1 : 0
            let start = ASKCanvasPoint(x: center.x + cos(startAngle) * radius, y: center.y + sin(startAngle) * radius)
            let end = ASKCanvasPoint(x: center.x + cos(endAngle) * radius, y: center.y + sin(endAngle) * radius)
            svg += "<path data-kind=\"chart-slice\" d=\"M \(center.x) \(center.y) L \(start.x) \(start.y) A \(radius) \(radius) 0 \(largeArc) 1 \(end.x) \(end.y) Z\" fill=\"\(palette(index))\"/>"
            startAngle = endAngle
        }
        if doughnut {
            svg += "<circle data-kind=\"chart-doughnut-hole\" cx=\"\(center.x)\" cy=\"\(center.y)\" r=\"\(radius * 0.45)\" fill=\"#ffffff\"/>"
        }
        return svg
    }

    private func renderLegend(chart: ASKHWPChartDocument, frame: ASKCanvasRect) -> String {
        var svg = ""
        for (index, series) in chart.series.prefix(4).enumerated() {
            let y = frame.origin.y + frame.size.height - 10 - Double(index) * 11
            svg += "<rect x=\"\(frame.origin.x + frame.size.width - 58)\" y=\"\(y - 7)\" width=\"7\" height=\"7\" fill=\"\(palette(index))\"/>"
            svg += "<text data-kind=\"chart-legend\" x=\"\(frame.origin.x + frame.size.width - 48)\" y=\"\(y)\" font-size=\"8\" fill=\"#303030\">\(escaper.escape(series.name))</text>"
        }
        return svg
    }

    private func axis(_ plot: ASKCanvasRect) -> String {
        "<line data-kind=\"chart-axis\" x1=\"\(plot.origin.x)\" y1=\"\(plot.origin.y + plot.size.height)\" x2=\"\(plot.origin.x + plot.size.width)\" y2=\"\(plot.origin.y + plot.size.height)\" stroke=\"#808080\" stroke-width=\"0.6\"/><line data-kind=\"chart-axis\" x1=\"\(plot.origin.x)\" y1=\"\(plot.origin.y)\" x2=\"\(plot.origin.x)\" y2=\"\(plot.origin.y + plot.size.height)\" stroke=\"#808080\" stroke-width=\"0.6\"/>"
    }

    private func palette(_ index: Int) -> String { hwpChartPalette(index) }
}

func hwpChartPalette(_ index: Int) -> String {
    ["#3b6fb6", "#d95f59", "#61a35b", "#8c6bb1", "#d89b37", "#4aa3a2"][index % 6]
}

