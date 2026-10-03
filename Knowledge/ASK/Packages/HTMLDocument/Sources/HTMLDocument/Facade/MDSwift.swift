import Foundation

public enum MDSwift {
    public static func parseHTML(
        _ html: some StringProtocol,
        options: HTMLParseOptions = .standard,
        serializationOptions: HTMLSerializationOptions = .standard
    ) throws -> Document {
        try Soup.parseHTML(html, options: options, serializationOptions: serializationOptions)
    }

    public static func parseHTML(
        _ data: Data,
        options: HTMLParseOptions = .standard,
        encoding: String.Encoding = .utf8
    ) throws -> Document {
        try HTMLDataDecoder.parseHTML(data, options: options, encoding: encoding)
    }

    public static func parseHTML(
        fileAt url: URL,
        options: HTMLParseOptions = .standard,
        encoding: String.Encoding = .utf8
    ) throws -> Document {
        try HTMLDataDecoder.parseHTML(fileAt: url, options: options, encoding: encoding)
    }

    public static func clean(
        _ html: some StringProtocol,
        baseURI: String? = nil,
        safelist: Safelist
    ) throws -> String {
        let document = try parseHTML(html)
        let cleaned = HTMLCleaner(safelist).clean(document, baseURI: baseURI)
        return cleaned.html
    }

    public static func isValid(
        _ html: some StringProtocol,
        baseURI: String? = nil,
        safelist: Safelist
    ) throws -> Bool {
        let document = try parseHTML(html)
        return HTMLCleaner(safelist).isValid(document, baseURI: baseURI)
    }
}

public enum Soup {
    public static func parseHTML(
        _ html: some StringProtocol,
        options: HTMLParseOptions = .standard,
        serializationOptions: HTMLSerializationOptions = .standard
    ) throws -> Document {
        let builder = DOMTreeBuilder(serializationOptions: serializationOptions)
        return try HTMLParser.parse(html, options: options, into: builder)
    }

    public static func clean(
        _ html: some StringProtocol,
        baseURI: String? = nil,
        safelist: Safelist
    ) throws -> String {
        try MDSwift.clean(html, baseURI: baseURI, safelist: safelist)
    }

    public static func isValid(
        _ html: some StringProtocol,
        baseURI: String? = nil,
        safelist: Safelist
    ) throws -> Bool {
        try MDSwift.isValid(html, baseURI: baseURI, safelist: safelist)
    }
}
