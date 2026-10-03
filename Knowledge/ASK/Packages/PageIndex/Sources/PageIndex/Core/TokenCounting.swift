import Foundation

public protocol TokenCounting: Sendable {
    func countTokens(in text: String, model: String?) -> Int
}

public struct WhitespaceTokenCounter: TokenCounting, Sendable {
    public init() {}

    public func countTokens(in text: String, model: String?) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
