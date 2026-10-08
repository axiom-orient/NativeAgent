import Foundation

/// Resource limits applied before the native reader expands untrusted HWP/HWPX input.
///
/// The parser retains its decoded document and embedded binary objects in memory. These
/// limits therefore protect both the archive/container layer and the resulting document
/// model. Applications that genuinely need larger documents can opt in explicitly when
/// constructing `ASKPageHWPNativeParser`.
public struct ASKHWPParserLimits: Sendable, Hashable, Codable {
    public static let `default` = ASKHWPParserLimits()

    /// Maximum source file or in-memory input accepted by the native parser.
    public let maximumInputByteCount: Int
    /// Maximum decoded size of one HWP5 CFB stream or one HWPX ZIP entry.
    public let maximumDecodedStreamByteCount: Int
    /// Maximum declared/decoded aggregate payload retained while parsing one document.
    public let maximumDecodedTotalByteCount: Int
    /// Maximum number of ZIP archive entries or parsed document sections.
    public let maximumEntryOrSectionCount: Int

    public init(
        maximumInputByteCount: Int = 128 * 1024 * 1024,
        maximumDecodedStreamByteCount: Int = 128 * 1024 * 1024,
        maximumDecodedTotalByteCount: Int = 384 * 1024 * 1024,
        maximumEntryOrSectionCount: Int = 8_192
    ) {
        precondition(maximumInputByteCount > 0, "maximumInputByteCount must be positive.")
        precondition(maximumDecodedStreamByteCount > 0, "maximumDecodedStreamByteCount must be positive.")
        precondition(
            maximumDecodedTotalByteCount >= maximumDecodedStreamByteCount,
            "maximumDecodedTotalByteCount must cover one decoded stream."
        )
        precondition(maximumEntryOrSectionCount > 0, "maximumEntryOrSectionCount must be positive.")

        self.maximumInputByteCount = maximumInputByteCount
        self.maximumDecodedStreamByteCount = maximumDecodedStreamByteCount
        self.maximumDecodedTotalByteCount = maximumDecodedTotalByteCount
        self.maximumEntryOrSectionCount = maximumEntryOrSectionCount
    }

    private enum CodingKeys: String, CodingKey {
        case maximumInputByteCount
        case maximumDecodedStreamByteCount
        case maximumDecodedTotalByteCount
        case maximumEntryOrSectionCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let maximumInputByteCount = try container.decode(Int.self, forKey: .maximumInputByteCount)
        let maximumDecodedStreamByteCount = try container.decode(Int.self, forKey: .maximumDecodedStreamByteCount)
        let maximumDecodedTotalByteCount = try container.decode(Int.self, forKey: .maximumDecodedTotalByteCount)
        let maximumEntryOrSectionCount = try container.decode(Int.self, forKey: .maximumEntryOrSectionCount)

        guard maximumInputByteCount > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumInputByteCount,
                in: container,
                debugDescription: "maximumInputByteCount must be positive"
            )
        }
        guard maximumDecodedStreamByteCount > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumDecodedStreamByteCount,
                in: container,
                debugDescription: "maximumDecodedStreamByteCount must be positive"
            )
        }
        guard maximumDecodedTotalByteCount >= maximumDecodedStreamByteCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumDecodedTotalByteCount,
                in: container,
                debugDescription: "maximumDecodedTotalByteCount must cover one decoded stream"
            )
        }
        guard maximumEntryOrSectionCount > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumEntryOrSectionCount,
                in: container,
                debugDescription: "maximumEntryOrSectionCount must be positive"
            )
        }

        self.init(
            maximumInputByteCount: maximumInputByteCount,
            maximumDecodedStreamByteCount: maximumDecodedStreamByteCount,
            maximumDecodedTotalByteCount: maximumDecodedTotalByteCount,
            maximumEntryOrSectionCount: maximumEntryOrSectionCount
        )
    }

    func validateInputSize(_ byteCount: Int) throws {
        guard byteCount <= maximumInputByteCount else {
            throw ASKHWPError.unsupportedFeature(
                "Input exceeds the configured \(maximumInputByteCount)-byte limit."
            )
        }
    }

    func validateDecodedStreamSize(_ byteCount: Int, path: String) throws {
        guard byteCount <= maximumDecodedStreamByteCount else {
            throw ASKHWPError.unsupportedFeature(
                "Decoded stream exceeds the configured \(maximumDecodedStreamByteCount)-byte limit: \(path)."
            )
        }
    }

    func validateDecodedTotal(_ byteCount: Int) throws {
        guard byteCount <= maximumDecodedTotalByteCount else {
            throw ASKHWPError.unsupportedFeature(
                "Document decoded payload exceeds the configured \(maximumDecodedTotalByteCount)-byte limit."
            )
        }
    }
}
