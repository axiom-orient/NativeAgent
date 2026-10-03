import Foundation
import DocumentCore

public struct ASKHWPBinaryParser: Sendable {
    public let limits: ASKHWPParserLimits

    public init(limits: ASKHWPParserLimits = .default) {
        self.limits = limits
    }

    public func parse(data: Data) throws -> ASKHWPDocument {
        try limits.validateInputSize(data.count)
        let container = try ASKCFBReader(
            data: data,
            maximumStreamByteCount: limits.maximumDecodedStreamByteCount,
            maximumMiniStreamByteCount: limits.maximumDecodedTotalByteCount
        )
        let headerData = try container.stream(named: "FileHeader")
        let header = try ASKHWPFileHeader(data: headerData)

        guard !header.flags.isPasswordProtected else {
            throw ASKHWPError.unsupportedFeature("Password-protected HWP files cannot be parsed by the native engine yet.")
        }
        guard !header.flags.isDistributionDocument else {
            throw ASKHWPError.unsupportedFeature("Distribution/protected HWP files cannot be parsed by the native engine yet.")
        }
        guard !header.flags.hasDRM else {
            throw ASKHWPError.unsupportedFeature("DRM-protected HWP files cannot be parsed by the native engine yet.")
        }

        let styleCatalog = try Self.readStyleCatalog(from: container, header: header, limits: limits)
        let binaryObjects = try Self.readBinaryObjects(from: container, limits: limits)
        let binaryPathsByStorageID = Self.binaryPathsByStorageID(
            paths: binaryObjects.values.map(\.path),
            references: styleCatalog.binaryReferences
        )

        let sectionPaths = container.streamPaths(prefix: "BodyText/Section")
            .sorted { ASKHWPParserSupport.sectionIndex(from: $0) < ASKHWPParserSupport.sectionIndex(from: $1) }
        guard !sectionPaths.isEmpty else {
            throw ASKHWPError.malformedDocument("HWP BodyText/Section* streams were not found.")
        }
        guard sectionPaths.count <= limits.maximumEntryOrSectionCount else {
            throw ASKHWPError.unsupportedFeature(
                "HWP declares \(sectionPaths.count) sections, above the configured \(limits.maximumEntryOrSectionCount) section limit."
            )
        }

        var sections: [ASKHWPSection] = []
        var decodedPayloadByteCount = binaryObjects.values.reduce(0) { $0 + ($1.data?.count ?? 0) }
        try limits.validateDecodedTotal(decodedPayloadByteCount)
        for (sectionIndex, path) in sectionPaths.enumerated() {
            var sectionData = try container.stream(named: path)
            if header.flags.isCompressed {
                sectionData = try ASKDeflateDecoder.inflateHWPStream(
                    sectionData,
                    maxOutputSize: limits.maximumDecodedStreamByteCount
                )
            }
            try limits.validateDecodedStreamSize(sectionData.count, path: path)
            let (total, overflowed) = decodedPayloadByteCount.addingReportingOverflow(sectionData.count)
            guard !overflowed else {
                throw ASKHWPError.unsupportedFeature("HWP decoded payload size overflowed.")
            }
            decodedPayloadByteCount = total
            try limits.validateDecodedTotal(decodedPayloadByteCount)
            let parsedSection = try ASKHWP5BodyTextParser(
                sourcePath: path,
                styles: styleCatalog,
                binaryPathsByStorageID: binaryPathsByStorageID
            ).parse(data: sectionData)
            sections.append(
                .init(
                    index: sectionIndex,
                    title: nil,
                    sourcePath: path,
                    pageMetrics: parsedSection.pageMetrics,
                    paragraphs: parsedSection.paragraphs,
                    contentBlocks: parsedSection.contentBlocks
                )
            )
        }

        let title = ASKHWPParserSupport.fallbackTitle(from: sections) ?? "Untitled HWP"
        let metadata: [String: String] = [
            "signature": header.signature,
            "version": header.versionString,
            "compressed": String(header.flags.isCompressed),
            "container": "cfb",
            "sectionCount": String(sections.count),
            "docInfoCharShapeCount": String(styleCatalog.charShapes.count),
            "docInfoParaShapeCount": String(styleCatalog.paraShapes.count),
            "binaryObjectCount": String(binaryObjects.count)
        ]
        return ASKHWPDocument(
            format: .hwp,
            title: title,
            sections: sections,
            metadata: metadata,
            binaryObjects: binaryObjects
        )
    }

    private static func readStyleCatalog(
        from container: ASKCFBReader,
        header: ASKHWPFileHeader,
        limits: ASKHWPParserLimits
    ) throws -> ASKHWP5StyleCatalog {
        guard container.containsStream(named: "DocInfo") else { return .empty }
        var data = try container.stream(named: "DocInfo")
        if header.flags.isCompressed {
            data = try ASKDeflateDecoder.inflateHWPStream(
                data,
                maxOutputSize: limits.maximumDecodedStreamByteCount
            )
        }
        try limits.validateDecodedStreamSize(data.count, path: "DocInfo")
        return try ASKHWP5StyleCatalog(data: data)
    }

    private static func readBinaryObjects(
        from container: ASKCFBReader,
        limits: ASKHWPParserLimits
    ) throws -> [String: ASKHWPBinaryObject] {
        var objects: [String: ASKHWPBinaryObject] = [:]
        var totalByteCount = 0
        for path in container.streamPaths(prefix: "BinData/") {
            let data = try container.stream(named: path)
            let (nextTotal, overflowed) = totalByteCount.addingReportingOverflow(data.count)
            guard !overflowed else {
                throw ASKHWPError.unsupportedFeature("HWP binary object payload size overflowed.")
            }
            totalByteCount = nextTotal
            try limits.validateDecodedTotal(totalByteCount)
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            objects[path] = ASKHWPBinaryObject(
                id: fileName,
                path: path,
                mediaType: mediaType(for: path),
                data: data
            )
        }
        return objects
    }

    private static func binaryPathsByStorageID(
        paths: [String],
        references: [ASKHWP5BinaryReference]
    ) -> [Int: String] {
        var result: [Int: String] = [:]
        for path in paths {
            let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
            guard fileName.hasPrefix("bin"), fileName.count >= 7 else { continue }
            let hex = String(fileName.dropFirst(3).prefix(4))
            if let storageID = Int(hex, radix: 16) {
                result[storageID] = path
            }
        }
        for reference in references where result[reference.storageID] == nil {
            let stem = String(format: "bin%04x", reference.storageID)
            if let path = paths.first(where: {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() == stem
            }) {
                result[reference.storageID] = path
            }
        }
        return result
    }

    private static func mediaType(for path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "wmf": return "image/wmf"
        case "emf": return "image/emf"
        case "ole": return "application/ole"
        default: return nil
        }
    }

}

struct ASKHWPFileHeader: Sendable, Hashable {
    let signature: String
    let version: UInt32
    let flags: Flags

    var versionString: String {
        let major = (version >> 24) & 0xFF
        let minor = (version >> 16) & 0xFF
        let micro = (version >> 8) & 0xFF
        let build = version & 0xFF
        return "\(major).\(minor).\(micro).\(build)"
    }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 40 else {
            throw ASKHWPError.malformedDocument("HWP FileHeader stream is shorter than 40 bytes.")
        }
        let signatureBytes = Array(bytes[0..<32]).prefix { $0 != 0 }
        self.signature = String(bytes: signatureBytes, encoding: .ascii) ?? ""
        guard signature.contains("HWP Document File") else {
            throw ASKHWPError.unsupportedFormat("HWP FileHeader signature is invalid: \(signature)")
        }
        self.version = try ASKByteCursor.uint32LE(bytes, at: 32)
        self.flags = Flags(rawValue: try ASKByteCursor.uint32LE(bytes, at: 36))
    }

    struct Flags: Sendable, Hashable {
        let rawValue: UInt32

        var isCompressed: Bool { (rawValue & (1 << 0)) != 0 }
        var isPasswordProtected: Bool { (rawValue & (1 << 1)) != 0 }
        var isDistributionDocument: Bool { (rawValue & (1 << 2)) != 0 }
        var hasScript: Bool { (rawValue & (1 << 3)) != 0 }
        var hasDRM: Bool { (rawValue & (1 << 4)) != 0 }
        var hasXMLTemplateStorage: Bool { (rawValue & (1 << 5)) != 0 }
        var hasDocumentHistory: Bool { (rawValue & (1 << 6)) != 0 }
        var hasDigitalSignature: Bool { (rawValue & (1 << 8)) != 0 }
        var isEncryptedPackage: Bool { (rawValue & (1 << 9)) != 0 }
    }
}
