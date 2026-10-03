import Foundation

public enum HTMLDataDecoder {
    public static func parseHTML(
        _ data: Data,
        options: HTMLParseOptions = .standard,
        encoding: String.Encoding = .utf8
    ) throws -> Document {
        guard let html = String(data: data, encoding: encoding) else {
            throw MDSwiftCoreError.invalidInput("unable to decode data using \(encoding)")
        }

        let builder = DOMTreeBuilder()
        return try HTMLParser.parse(html, options: options, into: builder)
    }

    public static func parseHTML(
        fileAt url: URL,
        options: HTMLParseOptions = .standard,
        encoding: String.Encoding = .utf8
    ) throws -> Document {
        guard url.isFileURL else {
            throw MDSwiftCoreError.invalidInput("HTMLDataDecoder.parseHTML(fileAt:) accepts file URLs only")
        }

        let data = try Data(contentsOf: url)
        return try parseHTML(data, options: options, encoding: encoding)
    }
}
