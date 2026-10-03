import Foundation
import DocumentCore
@testable import HWPDocument

public struct ASKHWPFixtureExpectation: Sendable, Hashable, Codable {
    public let fileName: String
    public let minimumTableCount: Int
    public let minimumImageCount: Int
    public let minimumObjectCount: Int
    public let requiredObjectKinds: [ASKHWPDrawObjectKind]
    public let minimumColumnSpanCellCount: Int
    public let minimumBorderSegmentCount: Int
    public let minimumMarkerReferenceCount: Int
    public let minimumChartPayloadCount: Int
    public let minimumGradientDefinitionCount: Int
    public let minimumPatternDefinitionCount: Int
    public let minimumNonzeroRotationCount: Int
    public let minimumFlipTransformCount: Int
    public let minimumPathCommandCount: Int
    public let minimumObjectCaptionTextCount: Int
    public let minimumTextMarginObjectCount: Int
    public let minimumNativeChartPrimitiveCount: Int
    public let minimumNativeEquationPrimitiveCount: Int
    public let maximumUnknownNativeChartKindCount: Int?
    public let maximumUnsupportedEquationTokenCount: Int?
    public let requiresChartReferences: Bool
    public let requiresEquationText: Bool

    public init(
        fileName: String,
        minimumTableCount: Int = 0,
        minimumImageCount: Int = 0,
        minimumObjectCount: Int = 0,
        requiredObjectKinds: [ASKHWPDrawObjectKind] = [],
        minimumColumnSpanCellCount: Int = 0,
        minimumBorderSegmentCount: Int = 0,
        minimumMarkerReferenceCount: Int = 0,
        minimumChartPayloadCount: Int = 0,
        minimumGradientDefinitionCount: Int = 0,
        minimumPatternDefinitionCount: Int = 0,
        minimumNonzeroRotationCount: Int = 0,
        minimumFlipTransformCount: Int = 0,
        minimumPathCommandCount: Int = 0,
        minimumObjectCaptionTextCount: Int = 0,
        minimumTextMarginObjectCount: Int = 0,
        minimumNativeChartPrimitiveCount: Int = 0,
        minimumNativeEquationPrimitiveCount: Int = 0,
        maximumUnknownNativeChartKindCount: Int? = nil,
        maximumUnsupportedEquationTokenCount: Int? = nil,
        requiresChartReferences: Bool = false,
        requiresEquationText: Bool = false
    ) {
        self.fileName = fileName
        self.minimumTableCount = minimumTableCount
        self.minimumImageCount = minimumImageCount
        self.minimumObjectCount = minimumObjectCount
        self.requiredObjectKinds = requiredObjectKinds
        self.minimumColumnSpanCellCount = minimumColumnSpanCellCount
        self.minimumBorderSegmentCount = minimumBorderSegmentCount
        self.minimumMarkerReferenceCount = minimumMarkerReferenceCount
        self.minimumChartPayloadCount = minimumChartPayloadCount
        self.minimumGradientDefinitionCount = minimumGradientDefinitionCount
        self.minimumPatternDefinitionCount = minimumPatternDefinitionCount
        self.minimumNonzeroRotationCount = minimumNonzeroRotationCount
        self.minimumFlipTransformCount = minimumFlipTransformCount
        self.minimumPathCommandCount = minimumPathCommandCount
        self.minimumObjectCaptionTextCount = minimumObjectCaptionTextCount
        self.minimumTextMarginObjectCount = minimumTextMarginObjectCount
        self.minimumNativeChartPrimitiveCount = minimumNativeChartPrimitiveCount
        self.minimumNativeEquationPrimitiveCount = minimumNativeEquationPrimitiveCount
        self.maximumUnknownNativeChartKindCount = maximumUnknownNativeChartKindCount
        self.maximumUnsupportedEquationTokenCount = maximumUnsupportedEquationTokenCount
        self.requiresChartReferences = requiresChartReferences
        self.requiresEquationText = requiresEquationText
    }

    public static let hwpForgeIssue29: [ASKHWPFixtureExpectation] = [
        ASKHWPFixtureExpectation(
            fileName: "13_equation.hwpx",
            minimumImageCount: 1,
            minimumObjectCount: 36,
            requiredObjectKinds: [.equation],
            minimumNativeEquationPrimitiveCount: 36,
            maximumUnsupportedEquationTokenCount: 0,
            requiresEquationText: true
        ),
        ASKHWPFixtureExpectation(
            fileName: "14_chart.hwpx",
            minimumTableCount: 4,
            minimumImageCount: 1,
            minimumObjectCount: 24,
            requiredObjectKinds: [.chart],
            minimumBorderSegmentCount: 1,
            minimumChartPayloadCount: 24,
            minimumNativeChartPrimitiveCount: 24,
            maximumUnknownNativeChartKindCount: 0,
            requiresChartReferences: true
        ),
        ASKHWPFixtureExpectation(
            fileName: "15_shapes_advanced.hwpx",
            minimumImageCount: 1,
            minimumObjectCount: 52,
            requiredObjectKinds: [.line, .ellipse, .polygon, .curve, .connectLine],
            minimumMarkerReferenceCount: 1,
            minimumGradientDefinitionCount: 8,
            minimumPatternDefinitionCount: 7,
            minimumNonzeroRotationCount: 4,
            minimumFlipTransformCount: 4,
            minimumPathCommandCount: 11
        ),
        ASKHWPFixtureExpectation(
            fileName: "full_report.hwpx",
            minimumTableCount: 4,
            minimumImageCount: 1,
            minimumObjectCount: 12,
            requiredObjectKinds: [.line, .ellipse, .polygon, .rectangle, .chart, .equation],
            minimumBorderSegmentCount: 1,
            minimumChartPayloadCount: 4,
            minimumObjectCaptionTextCount: 2,
            minimumTextMarginObjectCount: 1,
            minimumNativeChartPrimitiveCount: 4,
            minimumNativeEquationPrimitiveCount: 1,
            maximumUnknownNativeChartKindCount: 0,
            maximumUnsupportedEquationTokenCount: 0,
            requiresChartReferences: true,
            requiresEquationText: true
        ),
        ASKHWPFixtureExpectation(
            fileName: "hwpx_complete_guide.hwpx",
            minimumTableCount: 2,
            minimumImageCount: 1,
            minimumObjectCount: 22,
            requiredObjectKinds: [.line, .ellipse, .polygon, .rectangle, .curve, .connectLine, .chart, .equation],
            minimumColumnSpanCellCount: 2,
            minimumBorderSegmentCount: 1,
            minimumMarkerReferenceCount: 1,
            minimumChartPayloadCount: 4,
            minimumGradientDefinitionCount: 1,
            minimumPatternDefinitionCount: 1,
            minimumNonzeroRotationCount: 1,
            minimumFlipTransformCount: 1,
            minimumPathCommandCount: 3,
            minimumObjectCaptionTextCount: 3,
            minimumTextMarginObjectCount: 1,
            minimumNativeChartPrimitiveCount: 4,
            minimumNativeEquationPrimitiveCount: 4,
            maximumUnknownNativeChartKindCount: 0,
            maximumUnsupportedEquationTokenCount: 0,
            requiresChartReferences: true,
            requiresEquationText: true
        )
    ]
}

public struct ASKHWPFixtureValidationIssue: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let fileName: String
    public let field: String
    public let expected: String
    public let actual: String

    public init(fileName: String, field: String, expected: String, actual: String) {
        self.id = "\(fileName):\(field):\(expected):\(actual)"
        self.fileName = fileName
        self.field = field
        self.expected = expected
        self.actual = actual
    }
}

public struct ASKHWPFixtureValidationEntry: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let fileName: String
    public let pageCount: Int
    public let parsedTableCount: Int
    public let parsedImageCount: Int
    public let parsedObjectCount: Int
    public let renderedTableCount: Int
    public let renderedImageCount: Int
    public let renderedObjectCount: Int
    public let objectKindCounts: [String: Int]
    public let columnSpanCellCount: Int
    public let borderSegmentCount: Int
    public let markerReferenceCount: Int
    public let chartPayloadCount: Int
    public let gradientDefinitionCount: Int
    public let patternDefinitionCount: Int
    public let nonzeroRotationCount: Int
    public let flipTransformCount: Int
    public let pathCommandCount: Int
    public let objectCaptionTextCount: Int
    public let textMarginObjectCount: Int
    public let nativeChartPrimitiveCount: Int
    public let nativeEquationPrimitiveCount: Int
    public let unknownNativeChartKindCount: Int
    public let unsupportedEquationTokenCount: Int
    public let chartReferenceCount: Int
    public let equationTextCount: Int
    public let svgFNV1A64: String
    public let issues: [ASKHWPFixtureValidationIssue]

    public var passed: Bool { issues.isEmpty }
}

public struct ASKHWPFixtureValidationReport: Sendable, Hashable, Codable {
    public let entries: [ASKHWPFixtureValidationEntry]

    public init(entries: [ASKHWPFixtureValidationEntry]) {
        self.entries = entries
    }

    public var passed: Bool {
        entries.allSatisfy(\.passed)
    }

    public var issues: [ASKHWPFixtureValidationIssue] {
        entries.flatMap(\.issues)
    }
}

private func svgOccurrences(_ svg: String, of substring: String) -> Int {
    var count = 0
    var searchRange = svg.startIndex..<svg.endIndex
    while let range = svg.range(of: substring, range: searchRange) {
        count += 1
        searchRange = range.upperBound..<svg.endIndex
    }
    return count
}

public struct ASKHWPFixtureValidator: Sendable {
    public let parser: ASKPageHWPNativeParser
    public let renderer: ASKHWPPageLayoutRenderer
    public let svgExporter: ASKHWPSVGSnapshotExporter

    public init(
        parser: ASKPageHWPNativeParser = .init(),
        renderer: ASKHWPPageLayoutRenderer = .init(),
        svgExporter: ASKHWPSVGSnapshotExporter = .init(embedImages: false)
    ) {
        self.parser = parser
        self.renderer = renderer
        self.svgExporter = svgExporter
    }

    public func validate(directoryURL: URL, expectations: [ASKHWPFixtureExpectation]) throws -> ASKHWPFixtureValidationReport {
        let entries = try expectations.map { expectation in
            try validate(fileURL: directoryURL.appendingPathComponent(expectation.fileName), expectation: expectation)
        }
        return ASKHWPFixtureValidationReport(entries: entries)
    }

    public func validate(fileURL: URL, expectation: ASKHWPFixtureExpectation) throws -> ASKHWPFixtureValidationEntry {
        let document = try parser.parse(fileURL: fileURL)
        let rendered = try renderer.render(document)
        let svg = svgExporter.export(document: rendered)
        let objectKindCounts = Dictionary(grouping: document.drawObjects, by: { $0.kind.rawValue }).mapValues(\.count)
        let columnSpanCellCount = rendered.tableFragments.flatMap(\.cells).filter { $0.columnSpan > 1 }.count
        let borderSegmentCount = rendered.tableFragments.reduce(0) { $0 + $1.borderSegments.count }
        let markerReferenceCount = svgOccurrences(svg, of: "marker-start=") + svgOccurrences(svg, of: "marker-end=")
        let gradientDefinitionCount = svgOccurrences(svg, of: "<linearGradient")
        let patternDefinitionCount = svgOccurrences(svg, of: "<pattern")
        let nonzeroRotationCount = document.drawObjects.filter { abs($0.transform.rotationDegrees) > 0.0001 }.count
        let flipTransformCount = document.drawObjects.filter { $0.transform.flipHorizontal || $0.transform.flipVertical }.count
        let pathCommandCount = document.drawObjects.reduce(0) { $0 + $1.pathCommands.count }
        let objectCaptionTextCount = document.drawObjects.filter { $0.captionText?.nonEmptyValue != nil }.count
        let textMarginObjectCount = document.drawObjects.filter { $0.textMargin != .zero }.count
        let nativeChartPrimitiveCount = svgOccurrences(svg, of: "data-kind=\"native-chart\"")
        let nativeEquationPrimitiveCount = svgOccurrences(svg, of: "data-kind=\"native-equation\"")
        let unknownNativeChartKindCount = svgOccurrences(svg, of: "data-chart-kind=\"unknown\"")
        let unsupportedEquationTokenCount = svgOccurrences(svg, of: "data-unsupported-eqn-token=")
        let chartPayloadCount = document.binaryObjects.values.filter { object in
            object.path.hasPrefix("Chart/") && object.mediaType == "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"
        }.count
        let chartObjects = document.drawObjects.filter { $0.kind == .chart }
        let chartReferenceCount = chartObjects.filter { object in
            guard let referenceID = object.referenceID else { return false }
            return svg.contains(referenceID)
        }.count
        let equationObjects = document.drawObjects.filter { $0.kind == .equation }
        let equationTextCount = equationObjects.filter { object in
            guard let text = object.text else { return false }
            return text.contains("over") || text.contains("root") || text.contains("int") || text.contains("matrix")
        }.count
        var issues: [ASKHWPFixtureValidationIssue] = []

        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "parsedTableCount", expected: expectation.minimumTableCount, actual: document.tables.count)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "parsedImageCount", expected: expectation.minimumImageCount, actual: document.images.count)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "parsedObjectCount", expected: expectation.minimumObjectCount, actual: document.drawObjects.count)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "columnSpanCellCount", expected: expectation.minimumColumnSpanCellCount, actual: columnSpanCellCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "borderSegmentCount", expected: expectation.minimumBorderSegmentCount, actual: borderSegmentCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "markerReferenceCount", expected: expectation.minimumMarkerReferenceCount, actual: markerReferenceCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "chartPayloadCount", expected: expectation.minimumChartPayloadCount, actual: chartPayloadCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "gradientDefinitionCount", expected: expectation.minimumGradientDefinitionCount, actual: gradientDefinitionCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "patternDefinitionCount", expected: expectation.minimumPatternDefinitionCount, actual: patternDefinitionCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "nonzeroRotationCount", expected: expectation.minimumNonzeroRotationCount, actual: nonzeroRotationCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "flipTransformCount", expected: expectation.minimumFlipTransformCount, actual: flipTransformCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "pathCommandCount", expected: expectation.minimumPathCommandCount, actual: pathCommandCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "objectCaptionTextCount", expected: expectation.minimumObjectCaptionTextCount, actual: objectCaptionTextCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "textMarginObjectCount", expected: expectation.minimumTextMarginObjectCount, actual: textMarginObjectCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "nativeChartPrimitiveCount", expected: expectation.minimumNativeChartPrimitiveCount, actual: nativeChartPrimitiveCount)
        appendMinimumIssue(&issues, fileName: expectation.fileName, field: "nativeEquationPrimitiveCount", expected: expectation.minimumNativeEquationPrimitiveCount, actual: nativeEquationPrimitiveCount)
        if let maximum = expectation.maximumUnknownNativeChartKindCount, unknownNativeChartKindCount > maximum {
            issues.append(ASKHWPFixtureValidationIssue(fileName: expectation.fileName, field: "unknownNativeChartKindCount", expected: "<=\(maximum)", actual: "\(unknownNativeChartKindCount)"))
        }
        if let maximum = expectation.maximumUnsupportedEquationTokenCount, unsupportedEquationTokenCount > maximum {
            issues.append(ASKHWPFixtureValidationIssue(fileName: expectation.fileName, field: "unsupportedEquationTokenCount", expected: "<=\(maximum)", actual: "\(unsupportedEquationTokenCount)"))
        }

        for kind in expectation.requiredObjectKinds {
            let count = objectKindCounts[kind.rawValue] ?? 0
            if count == 0 {
                issues.append(ASKHWPFixtureValidationIssue(fileName: expectation.fileName, field: "objectKind.\(kind.rawValue)", expected: ">0", actual: "0"))
            }
            if !svg.contains("data-shape-kind=\"\(kind.rawValue)\"") && !svg.contains("data-object-kind=\"\(kind.rawValue)\"") {
                issues.append(ASKHWPFixtureValidationIssue(fileName: expectation.fileName, field: "svgObjectKind.\(kind.rawValue)", expected: "present", actual: "missing"))
            }
        }

        if expectation.requiresChartReferences, chartReferenceCount < chartObjects.count {
            issues.append(ASKHWPFixtureValidationIssue(fileName: expectation.fileName, field: "chartReferenceCount", expected: "\(chartObjects.count)", actual: "\(chartReferenceCount)"))
        }
        if expectation.requiresEquationText, equationTextCount == 0 {
            issues.append(ASKHWPFixtureValidationIssue(fileName: expectation.fileName, field: "equationTextCount", expected: ">0", actual: "0"))
        }

        return ASKHWPFixtureValidationEntry(
            id: expectation.fileName,
            fileName: expectation.fileName,
            pageCount: rendered.pages.count,
            parsedTableCount: document.tables.count,
            parsedImageCount: document.images.count,
            parsedObjectCount: document.drawObjects.count,
            renderedTableCount: rendered.tableFragments.count,
            renderedImageCount: rendered.imageFragments.count,
            renderedObjectCount: rendered.objectFragments.count,
            objectKindCounts: objectKindCounts,
            columnSpanCellCount: columnSpanCellCount,
            borderSegmentCount: borderSegmentCount,
            markerReferenceCount: markerReferenceCount,
            chartPayloadCount: chartPayloadCount,
            gradientDefinitionCount: gradientDefinitionCount,
            patternDefinitionCount: patternDefinitionCount,
            nonzeroRotationCount: nonzeroRotationCount,
            flipTransformCount: flipTransformCount,
            pathCommandCount: pathCommandCount,
            objectCaptionTextCount: objectCaptionTextCount,
            textMarginObjectCount: textMarginObjectCount,
            nativeChartPrimitiveCount: nativeChartPrimitiveCount,
            nativeEquationPrimitiveCount: nativeEquationPrimitiveCount,
            unknownNativeChartKindCount: unknownNativeChartKindCount,
            unsupportedEquationTokenCount: unsupportedEquationTokenCount,
            chartReferenceCount: chartReferenceCount,
            equationTextCount: equationTextCount,
            svgFNV1A64: ASKHWPStableHasher.fnv1a64Hex(svg),
            issues: issues
        )
    }

    private func appendMinimumIssue(
        _ issues: inout [ASKHWPFixtureValidationIssue],
        fileName: String,
        field: String,
        expected: Int,
        actual: Int
    ) {
        if actual < expected {
            issues.append(ASKHWPFixtureValidationIssue(fileName: fileName, field: field, expected: ">=\(expected)", actual: "\(actual)"))
        }
    }
}
