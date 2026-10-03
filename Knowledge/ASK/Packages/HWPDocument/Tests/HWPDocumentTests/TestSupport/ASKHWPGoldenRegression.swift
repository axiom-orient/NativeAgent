import Foundation
import DocumentCore
@testable import HWPDocument

public struct ASKHWPRegressionSnapshot: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let title: String
    public let format: ASKHWPDocumentFormat
    public let plainText: String
    public let pageCount: Int
    public let pageMetrics: [ASKHWPRegressionPageMetrics]
    public let textFragmentCount: Int
    public let tableFragmentCount: Int
    public let imageFragmentCount: Int
    public let objectFragmentCount: Int
    public let parsedTableCount: Int
    public let parsedImageCount: Int
    public let parsedObjectCount: Int
    public let binaryObjectCount: Int
    public let svgSnapshot: String
    public let svgFNV1A64: String
    public let metadata: [String: String]

    public init(
        schemaVersion: Int = 1,
        title: String,
        format: ASKHWPDocumentFormat,
        plainText: String,
        pageCount: Int,
        pageMetrics: [ASKHWPRegressionPageMetrics],
        textFragmentCount: Int,
        tableFragmentCount: Int,
        imageFragmentCount: Int,
        objectFragmentCount: Int,
        parsedTableCount: Int,
        parsedImageCount: Int,
        parsedObjectCount: Int,
        binaryObjectCount: Int,
        svgSnapshot: String,
        svgFNV1A64: String,
        metadata: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.format = format
        self.plainText = plainText
        self.pageCount = pageCount
        self.pageMetrics = pageMetrics
        self.textFragmentCount = textFragmentCount
        self.tableFragmentCount = tableFragmentCount
        self.imageFragmentCount = imageFragmentCount
        self.objectFragmentCount = objectFragmentCount
        self.parsedTableCount = parsedTableCount
        self.parsedImageCount = parsedImageCount
        self.parsedObjectCount = parsedObjectCount
        self.binaryObjectCount = binaryObjectCount
        self.svgSnapshot = svgSnapshot
        self.svgFNV1A64 = svgFNV1A64
        self.metadata = metadata
    }
}

public struct ASKHWPRegressionPageMetrics: Sendable, Hashable, Codable {
    public let index: Int
    public let width: Double
    public let height: Double
    public let contentWidth: Double
    public let contentHeight: Double

    public init(index: Int, metrics: ASKHWPPageMetrics) {
        self.index = index
        self.width = metrics.width
        self.height = metrics.height
        self.contentWidth = metrics.contentWidth
        self.contentHeight = metrics.contentHeight
    }
}

public struct ASKHWPRegressionSnapshotter: Sendable {
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

    public func makeSnapshot(data: Data, fileURL: URL? = nil, format explicitFormat: ASKHWPDocumentFormat? = nil) throws -> ASKHWPRegressionSnapshot {
        let parsed = try parser.parse(data: data, fileURL: fileURL, format: explicitFormat)
        let rendered = try renderer.render(parsed)
        return makeSnapshot(parsedDocument: parsed, renderedDocument: rendered)
    }

    public func makeSnapshot(fileURL: URL, format explicitFormat: ASKHWPDocumentFormat? = nil) throws -> ASKHWPRegressionSnapshot {
        let parsed = try parser.parse(fileURL: fileURL, format: explicitFormat)
        let rendered = try renderer.render(parsed)
        return makeSnapshot(parsedDocument: parsed, renderedDocument: rendered)
    }

    public func makeSnapshot(parsedDocument: ASKHWPDocument, renderedDocument: ASKHWPRenderedDocument) -> ASKHWPRegressionSnapshot {
        let svg = svgExporter.export(document: renderedDocument)
        return ASKHWPRegressionSnapshot(
            title: parsedDocument.title,
            format: parsedDocument.format,
            plainText: parsedDocument.plainText,
            pageCount: renderedDocument.pages.count,
            pageMetrics: renderedDocument.pages.map { ASKHWPRegressionPageMetrics(index: $0.index, metrics: $0.metrics) },
            textFragmentCount: renderedDocument.textFragments.count,
            tableFragmentCount: renderedDocument.tableFragments.count,
            imageFragmentCount: renderedDocument.imageFragments.count,
            objectFragmentCount: renderedDocument.objectFragments.count,
            parsedTableCount: parsedDocument.tables.count,
            parsedImageCount: parsedDocument.images.count,
            parsedObjectCount: parsedDocument.drawObjects.count,
            binaryObjectCount: parsedDocument.binaryObjects.count,
            svgSnapshot: svg,
            svgFNV1A64: ASKHWPStableHasher.fnv1a64Hex(svg),
            metadata: parsedDocument.metadata
        )
    }
}

public struct ASKHWPRegressionComparisonPolicy: Sendable, Hashable, Codable {
    public let compareTitle: Bool
    public let comparePlainText: Bool
    public let comparePageCount: Bool
    public let compareFragmentCounts: Bool
    public let compareParsedObjectCounts: Bool
    public let comparePageMetrics: Bool
    public let compareSVGHash: Bool
    public let compareSVGSnapshot: Bool

    public init(
        compareTitle: Bool = true,
        comparePlainText: Bool = true,
        comparePageCount: Bool = true,
        compareFragmentCounts: Bool = true,
        compareParsedObjectCounts: Bool = true,
        comparePageMetrics: Bool = true,
        compareSVGHash: Bool = true,
        compareSVGSnapshot: Bool = true
    ) {
        self.compareTitle = compareTitle
        self.comparePlainText = comparePlainText
        self.comparePageCount = comparePageCount
        self.compareFragmentCounts = compareFragmentCounts
        self.compareParsedObjectCounts = compareParsedObjectCounts
        self.comparePageMetrics = comparePageMetrics
        self.compareSVGHash = compareSVGHash
        self.compareSVGSnapshot = compareSVGSnapshot
    }

    public static let strict = ASKHWPRegressionComparisonPolicy()
}

public struct ASKHWPRegressionDifference: Sendable, Hashable, Codable, Identifiable {
    public var id: String { field }
    public let field: String
    public let expected: String
    public let actual: String

    public init(field: String, expected: String, actual: String) {
        self.field = field
        self.expected = expected
        self.actual = actual
    }
}

public struct ASKHWPRegressionReport: Sendable, Hashable, Codable {
    public let passed: Bool
    public let differences: [ASKHWPRegressionDifference]

    public init(differences: [ASKHWPRegressionDifference]) {
        self.passed = differences.isEmpty
        self.differences = differences
    }
}

public struct ASKHWPRegressionVerifier: Sendable {
    public let policy: ASKHWPRegressionComparisonPolicy

    public init(policy: ASKHWPRegressionComparisonPolicy = .strict) {
        self.policy = policy
    }

    public func compare(actual: ASKHWPRegressionSnapshot, expected: ASKHWPRegressionSnapshot) -> ASKHWPRegressionReport {
        var differences: [ASKHWPRegressionDifference] = []

        append(&differences, field: "schemaVersion", expected: expected.schemaVersion, actual: actual.schemaVersion)
        append(&differences, field: "format", expected: expected.format.rawValue, actual: actual.format.rawValue)
        if policy.compareTitle { append(&differences, field: "title", expected: expected.title, actual: actual.title) }
        if policy.comparePlainText { append(&differences, field: "plainText", expected: expected.plainText, actual: actual.plainText) }
        if policy.comparePageCount { append(&differences, field: "pageCount", expected: expected.pageCount, actual: actual.pageCount) }
        if policy.compareFragmentCounts {
            append(&differences, field: "textFragmentCount", expected: expected.textFragmentCount, actual: actual.textFragmentCount)
            append(&differences, field: "tableFragmentCount", expected: expected.tableFragmentCount, actual: actual.tableFragmentCount)
            append(&differences, field: "imageFragmentCount", expected: expected.imageFragmentCount, actual: actual.imageFragmentCount)
            append(&differences, field: "objectFragmentCount", expected: expected.objectFragmentCount, actual: actual.objectFragmentCount)
        }
        if policy.compareParsedObjectCounts {
            append(&differences, field: "parsedTableCount", expected: expected.parsedTableCount, actual: actual.parsedTableCount)
            append(&differences, field: "parsedImageCount", expected: expected.parsedImageCount, actual: actual.parsedImageCount)
            append(&differences, field: "parsedObjectCount", expected: expected.parsedObjectCount, actual: actual.parsedObjectCount)
            append(&differences, field: "binaryObjectCount", expected: expected.binaryObjectCount, actual: actual.binaryObjectCount)
        }
        if policy.comparePageMetrics { append(&differences, field: "pageMetrics", expected: describe(expected.pageMetrics), actual: describe(actual.pageMetrics)) }
        if policy.compareSVGHash { append(&differences, field: "svgFNV1A64", expected: expected.svgFNV1A64, actual: actual.svgFNV1A64) }
        if policy.compareSVGSnapshot { append(&differences, field: "svgSnapshot", expected: expected.svgSnapshot, actual: actual.svgSnapshot) }

        return ASKHWPRegressionReport(differences: differences)
    }

    private func append<T: Equatable>(_ differences: inout [ASKHWPRegressionDifference], field: String, expected: T, actual: T) {
        guard expected != actual else { return }
        differences.append(ASKHWPRegressionDifference(field: field, expected: String(describing: expected), actual: String(describing: actual)))
    }

    private func describe(_ metrics: [ASKHWPRegressionPageMetrics]) -> String {
        metrics.map { metric in
            "\(metric.index):\(metric.width)x\(metric.height):\(metric.contentWidth)x\(metric.contentHeight)"
        }.joined(separator: "|")
    }
}

public struct ASKHWPRegressionSnapshotStore: Sendable {
    public init() {}

    public func encode(_ snapshot: ASKHWPRegressionSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    public func decode(_ data: Data) throws -> ASKHWPRegressionSnapshot {
        try JSONDecoder().decode(ASKHWPRegressionSnapshot.self, from: data)
    }

    public func write(_ snapshot: ASKHWPRegressionSnapshot, to fileURL: URL) throws {
        let data = try encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func read(from fileURL: URL) throws -> ASKHWPRegressionSnapshot {
        let data = try Data(contentsOf: fileURL)
        return try decode(data)
    }
}

public struct ASKHWPStableHasher: Sendable, Hashable, Codable {
    public init() {}

    public static func fnv1a64Hex(_ string: String) -> String {
        fnv1a64Hex(Data(string.utf8))
    }

    public static func fnv1a64Hex(_ data: Data) -> String {
        String(format: "%016llx", hash(data))
    }

    private static func hash<S: Sequence<UInt8>>(_ bytes: S) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return value
    }
}

public struct ASKHWPReferenceRasterImage: Sendable, Hashable, Codable {
    public let width: Int
    public let height: Int
    public let rgba8: Data

    public init(width: Int, height: Int, rgba8: Data) throws {
        guard width > 0, height > 0 else {
            throw ASKHWPError.malformedDocument("Raster image dimensions must be positive.")
        }
        let expectedByteCount = width * height * 4
        guard rgba8.count == expectedByteCount else {
            throw ASKHWPError.malformedDocument("RGBA buffer size mismatch. Expected \(expectedByteCount), got \(rgba8.count).")
        }
        self.width = width
        self.height = height
        self.rgba8 = rgba8
    }
}

public struct ASKHWPReferenceImageDiffThreshold: Sendable, Hashable, Codable {
    public let maxChangedPixelRatio: Double
    public let maxMeanAbsoluteChannelError: Double
    public let maxChannelDelta: UInt8

    public init(maxChangedPixelRatio: Double = 0, maxMeanAbsoluteChannelError: Double = 0, maxChannelDelta: UInt8 = 0) {
        self.maxChangedPixelRatio = max(maxChangedPixelRatio, 0)
        self.maxMeanAbsoluteChannelError = max(maxMeanAbsoluteChannelError, 0)
        self.maxChannelDelta = maxChannelDelta
    }

    public static let exact = ASKHWPReferenceImageDiffThreshold()
}

public struct ASKHWPReferenceImageDiffResult: Sendable, Hashable, Codable {
    public let passed: Bool
    public let width: Int
    public let height: Int
    public let changedPixelCount: Int
    public let changedPixelRatio: Double
    public let meanAbsoluteChannelError: Double
    public let maxObservedChannelDelta: UInt8

    public init(
        passed: Bool,
        width: Int,
        height: Int,
        changedPixelCount: Int,
        changedPixelRatio: Double,
        meanAbsoluteChannelError: Double,
        maxObservedChannelDelta: UInt8
    ) {
        self.passed = passed
        self.width = width
        self.height = height
        self.changedPixelCount = changedPixelCount
        self.changedPixelRatio = changedPixelRatio
        self.meanAbsoluteChannelError = meanAbsoluteChannelError
        self.maxObservedChannelDelta = maxObservedChannelDelta
    }
}

public struct ASKHWPReferenceImageDiffer: Sendable {
    public init() {}

    public func diff(
        reference: ASKHWPReferenceRasterImage,
        candidate: ASKHWPReferenceRasterImage,
        threshold: ASKHWPReferenceImageDiffThreshold = .exact
    ) throws -> ASKHWPReferenceImageDiffResult {
        guard reference.width == candidate.width, reference.height == candidate.height else {
            throw ASKHWPError.malformedDocument("Raster image dimensions differ. Reference \(reference.width)x\(reference.height), candidate \(candidate.width)x\(candidate.height).")
        }
        let referenceBytes = [UInt8](reference.rgba8)
        let candidateBytes = [UInt8](candidate.rgba8)
        guard referenceBytes.count == candidateBytes.count else {
            throw ASKHWPError.malformedDocument("Raster image byte counts differ.")
        }

        var changedPixels = 0
        var totalAbsoluteChannelError = 0
        var maxDelta: UInt8 = 0
        let pixelCount = reference.width * reference.height

        for pixelIndex in 0..<pixelCount {
            var pixelChanged = false
            for channel in 0..<4 {
                let byteIndex = pixelIndex * 4 + channel
                let delta = abs(Int(referenceBytes[byteIndex]) - Int(candidateBytes[byteIndex]))
                totalAbsoluteChannelError += delta
                if delta > 0 { pixelChanged = true }
                if delta > Int(maxDelta) { maxDelta = UInt8(delta) }
            }
            if pixelChanged { changedPixels += 1 }
        }

        let changedRatio = Double(changedPixels) / Double(max(pixelCount, 1))
        let meanError = Double(totalAbsoluteChannelError) / Double(max(referenceBytes.count, 1))
        let passed = changedRatio <= threshold.maxChangedPixelRatio
            && meanError <= threshold.maxMeanAbsoluteChannelError
            && maxDelta <= threshold.maxChannelDelta

        return ASKHWPReferenceImageDiffResult(
            passed: passed,
            width: reference.width,
            height: reference.height,
            changedPixelCount: changedPixels,
            changedPixelRatio: changedRatio,
            meanAbsoluteChannelError: meanError,
            maxObservedChannelDelta: maxDelta
        )
    }
}
