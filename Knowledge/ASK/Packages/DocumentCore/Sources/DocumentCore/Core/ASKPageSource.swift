public struct ASKPageSource: Sendable, Hashable, Codable {
    public let kind: ASKPageSourceKind
    public let revision: String?
    public let authoritativeMarkdownPath: String?

    public init(
        kind: ASKPageSourceKind,
        revision: String? = nil,
        authoritativeMarkdownPath: String? = nil
    ) {
        self.kind = kind
        self.revision = revision
        self.authoritativeMarkdownPath = authoritativeMarkdownPath
    }
}

public enum ASKPageSourceKind: String, Sendable, Hashable, Codable {
    case markdown
    case package
    case notebook
    case hwp
    case hwpx
}

public struct ASKPageSourceRange: Sendable, Hashable, Codable {
    public enum ValidationError: Error, Equatable, Sendable {
        case negativeStart(Int)
        case endBeforeStart(start: Int, end: Int)
    }

    public let start: Int
    public let end: Int

    /// Creates a range from trusted program-generated offsets.
    ///
    /// Use ``init(validatingStart:end:)`` at decoding or external-input boundaries.
    public init(start: Int, end: Int) {
        precondition(start >= 0, "Source range start must be non-negative")
        precondition(end >= start, "Source range end must be greater than or equal to start")
        self.start = start
        self.end = end
    }

    /// Validates untrusted offsets without terminating the process.
    public init(validatingStart start: Int, end: Int) throws {
        guard start >= 0 else {
            throw ValidationError.negativeStart(start)
        }
        guard end >= start else {
            throw ValidationError.endBeforeStart(start: start, end: end)
        }
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Int.self, forKey: .start)
        let end = try container.decode(Int.self, forKey: .end)
        do {
            try self.init(validatingStart: start, end: end)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .end,
                in: container,
                debugDescription: "Invalid source range [\(start), \(end))"
            )
        }
    }

    public var length: Int {
        end - start
    }

    public func intersects(_ other: ASKPageSourceRange) -> Bool {
        overlapBounds(with: other) != nil
    }

    public func intersection(_ other: ASKPageSourceRange) -> ASKPageSourceRange? {
        guard let bounds = overlapBounds(with: other) else { return nil }
        return ASKPageSourceRange(start: bounds.start, end: bounds.end)
    }

    public func offset(by delta: Int) -> ASKPageSourceRange? {
        let (newStart, startOverflowed) = start.addingReportingOverflow(delta)
        let (newEnd, endOverflowed) = end.addingReportingOverflow(delta)
        guard !startOverflowed, !endOverflowed, newStart >= 0, newEnd >= newStart else {
            return nil
        }
        return ASKPageSourceRange(start: newStart, end: newEnd)
    }

    private func overlapBounds(with other: ASKPageSourceRange) -> (start: Int, end: Int)? {
        let lower = max(start, other.start)
        let upper = min(end, other.end)
        return lower < upper ? (lower, upper) : nil
    }
}

public struct ASKPageSourceAnchor: Sendable, Hashable, Codable {
    public let sourceID: ASKPageSourceID
    public let fragment: String?
    public let range: ASKPageSourceRange?

    public init(
        sourceID: ASKPageSourceID,
        fragment: String? = nil,
        range: ASKPageSourceRange? = nil
    ) {
        self.sourceID = sourceID
        self.fragment = fragment
        self.range = range
    }
}
