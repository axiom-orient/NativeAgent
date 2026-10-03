public enum ASKTypographyWhiteSpaceMode: String, Sendable, Hashable, Codable {
    case normal
    case preWrap = "pre-wrap"
}

public enum ASKTypographyWordBreakMode: String, Sendable, Hashable, Codable {
    case normal
    case keepAll = "keep-all"
}

public struct ASKTypographyPreparationOptions: Sendable, Hashable, Codable {
    public let whiteSpace: ASKTypographyWhiteSpaceMode
    public let wordBreak: ASKTypographyWordBreakMode
    public let localeIdentifier: String?

    public init(
        whiteSpace: ASKTypographyWhiteSpaceMode = .normal,
        wordBreak: ASKTypographyWordBreakMode = .normal,
        localeIdentifier: String? = nil
    ) {
        self.whiteSpace = whiteSpace
        self.wordBreak = wordBreak
        self.localeIdentifier = localeIdentifier
    }
}

public struct ASKTypographyLayoutMetrics: Sendable, Hashable, Codable {
    public let lineHeight: Double

    public init(lineHeight: Double) {
        self.lineHeight = lineHeight
    }
}
