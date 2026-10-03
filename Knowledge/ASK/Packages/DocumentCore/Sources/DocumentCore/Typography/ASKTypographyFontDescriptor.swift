public struct ASKTypographyFontDescriptor: Sendable, Hashable, Codable {
    public let postScriptName: String
    public let pointSize: Double
    public let localeIdentifier: String?

    public init(
        postScriptName: String,
        pointSize: Double,
        localeIdentifier: String? = nil
    ) {
        self.postScriptName = postScriptName
        self.pointSize = pointSize
        self.localeIdentifier = localeIdentifier
    }
}
