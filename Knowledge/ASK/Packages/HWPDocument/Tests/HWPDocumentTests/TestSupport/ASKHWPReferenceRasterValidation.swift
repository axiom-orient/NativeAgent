import Foundation
import DocumentCore
@testable import HWPDocument
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

public struct ASKHWPReferenceRasterPNGCodec: Sendable {
    public init() {}

    public func read(fileURL: URL) throws -> ASKHWPReferenceRasterImage {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ASKHWPError.malformedDocument("Unable to read raster PNG: \(fileURL.path)")
        }
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = Data(count: height * bytesPerRow)
        try rgba.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw ASKHWPError.malformedDocument("Unable to allocate raster buffer.")
            }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                throw ASKHWPError.malformedDocument("Unable to create raster decode context.")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try ASKHWPReferenceRasterImage(width: width, height: height, rgba8: rgba)
        #else
        throw ASKHWPError.unsupportedFormat("PNG raster loading requires CoreGraphics and ImageIO.")
        #endif
    }
}

public struct ASKHWPReferenceRasterPageDiff: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let documentName: String
    public let pageIndex: Int
    public let referencePath: String
    public let candidatePath: String
    public let diff: ASKHWPReferenceImageDiffResult

    public init(documentName: String, pageIndex: Int, referencePath: String, candidatePath: String, diff: ASKHWPReferenceImageDiffResult) {
        self.id = "\(documentName):\(pageIndex)"
        self.documentName = documentName
        self.pageIndex = pageIndex
        self.referencePath = referencePath
        self.candidatePath = candidatePath
        self.diff = diff
    }
}

public struct ASKHWPReferenceRasterValidationIssue: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let documentName: String
    public let pageIndex: Int?
    public let field: String
    public let message: String

    public init(documentName: String, pageIndex: Int? = nil, field: String, message: String) {
        self.id = "\(documentName):\(pageIndex.map(String.init) ?? "document"):\(field):\(message)"
        self.documentName = documentName
        self.pageIndex = pageIndex
        self.field = field
        self.message = message
    }
}

public struct ASKHWPReferenceRasterValidationReport: Sendable, Hashable, Codable {
    public let pageDiffs: [ASKHWPReferenceRasterPageDiff]
    public let issues: [ASKHWPReferenceRasterValidationIssue]

    public init(pageDiffs: [ASKHWPReferenceRasterPageDiff], issues: [ASKHWPReferenceRasterValidationIssue]) {
        self.pageDiffs = pageDiffs
        self.issues = issues
    }

    public var passed: Bool {
        issues.isEmpty && pageDiffs.allSatisfy { $0.diff.passed }
    }
}

public struct ASKHWPReferenceRasterValidator: Sendable {
    public let codec: ASKHWPReferenceRasterPNGCodec
    public let differ: ASKHWPReferenceImageDiffer
    public let threshold: ASKHWPReferenceImageDiffThreshold

    public init(
        codec: ASKHWPReferenceRasterPNGCodec = .init(),
        differ: ASKHWPReferenceImageDiffer = .init(),
        threshold: ASKHWPReferenceImageDiffThreshold = .exact
    ) {
        self.codec = codec
        self.differ = differ
        self.threshold = threshold
    }

    public func validate(
        documentNames: [String],
        referenceDirectoryURL: URL,
        candidateDirectoryURL: URL
    ) throws -> ASKHWPReferenceRasterValidationReport {
        var pageDiffs: [ASKHWPReferenceRasterPageDiff] = []
        var issues: [ASKHWPReferenceRasterValidationIssue] = []
        let referenceListing = try FileManager.default.contentsOfDirectory(at: referenceDirectoryURL, includingPropertiesForKeys: nil)
        let candidateListing = try FileManager.default.contentsOfDirectory(at: candidateDirectoryURL, includingPropertiesForKeys: nil)
        for documentName in documentNames {
            let referencePages = pageFiles(documentName: documentName, urls: referenceListing)
            let candidatePages = pageFiles(documentName: documentName, urls: candidateListing)
            if referencePages.isEmpty {
                issues.append(.init(documentName: documentName, field: "referencePages", message: "No Hancom reference PNG pages found. Expected \(baseName(documentName))-page-1.png style files."))
                continue
            }
            let referenceIndexes = Set(referencePages.keys)
            let candidateIndexes = Set(candidatePages.keys)
            for missing in referenceIndexes.subtracting(candidateIndexes).sorted() {
                issues.append(.init(documentName: documentName, pageIndex: missing, field: "candidatePage", message: "Missing native candidate PNG page."))
            }
            for extra in candidateIndexes.subtracting(referenceIndexes).sorted() {
                issues.append(.init(documentName: documentName, pageIndex: extra, field: "candidatePage", message: "Candidate page has no Hancom reference PNG."))
            }
            for index in referenceIndexes.intersection(candidateIndexes).sorted() {
                guard let referenceURL = referencePages[index],
                      let candidateURL = candidatePages[index] else { continue }
                let reference = try codec.read(fileURL: referenceURL)
                let candidate = try codec.read(fileURL: candidateURL)
                let diff = try differ.diff(reference: reference, candidate: candidate, threshold: threshold)
                if !diff.passed {
                    issues.append(.init(
                        documentName: documentName,
                        pageIndex: index,
                        field: "pixelDiff",
                        message: "changedPixelRatio=\(diff.changedPixelRatio), meanAbsoluteChannelError=\(diff.meanAbsoluteChannelError), maxObservedChannelDelta=\(diff.maxObservedChannelDelta)"
                    ))
                }
                pageDiffs.append(.init(
                    documentName: documentName,
                    pageIndex: index,
                    referencePath: referenceURL.path,
                    candidatePath: candidateURL.path,
                    diff: diff
                ))
            }
        }
        return ASKHWPReferenceRasterValidationReport(pageDiffs: pageDiffs, issues: issues)
    }

    private func pageFiles(documentName: String, urls: [URL]) -> [Int: URL] {
        let prefix = baseName(documentName)
        var result: [Int: URL] = [:]
        for url in urls where url.pathExtension.lowercased() == "png" {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            let suffix = String(name.dropFirst(prefix.count))
            guard let pageIndex = pageIndex(from: suffix) else { continue }
            result[pageIndex] = url
        }
        return result
    }

    private func pageIndex(from suffix: String) -> Int? {
        let normalized = suffix
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .lowercased()
        let parts = normalized.split(separator: "-").map(String.init)
        guard let pageMarker = parts.lastIndex(of: "page"),
              parts.indices.contains(pageMarker + 1),
              let value = Int(parts[pageMarker + 1]) else {
            return nil
        }
        return value
    }

    private func baseName(_ documentName: String) -> String {
        URL(fileURLWithPath: documentName).deletingPathExtension().lastPathComponent
    }
}
