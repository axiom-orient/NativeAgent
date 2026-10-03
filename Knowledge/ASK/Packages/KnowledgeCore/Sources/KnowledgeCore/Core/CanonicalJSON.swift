import CoreFoundation

import Foundation

public enum CanonicalJSON {
    private static let acronymSegments: [String: String] = [
        "id": "ID", "ids": "IDs", "uri": "URI", "uris": "URIs",
        "md": "MD", "url": "URL", "urls": "URLs", "html": "HTML",
        "sql": "SQL", "uuid": "UUID",
    ]

    private static func decodeKey(_ rawKey: String) -> String {
        guard rawKey.contains("_") else { return rawKey }
        let pieces = rawKey.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        guard let first = pieces.first else { return rawKey }
        var result = first.lowercased()
        for piece in pieces.dropFirst() {
            let lower = piece.lowercased()
            if let acronym = acronymSegments[lower] {
                result += acronym
            } else {
                result += lower.prefix(1).uppercased() + lower.dropFirst()
            }
        }
        return result
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { codingPath in
            let raw = codingPath.last?.stringValue ?? ""
            return AnyCodingKey(stringValue: decodeKey(raw))
        }
        return decoder
    }

    public static func data<T: Encodable>(for value: T) throws -> Data {
        try encoder().encode(value)
    }

    public static func string<T: Encodable>(for value: T) throws -> String {
        String(decoding: try data(for: value), as: UTF8.self)
    }

    public static func object<T: Encodable>(for value: T) throws -> Any {
        let data = try CanonicalJSON.data(for: value)
        return try JSONSerialization.jsonObject(with: data)
    }

    public static func object(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(T.self, from: data)
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Encodes a string as a YAML double-quoted scalar.
///
/// Escaping only the quote character is not compositional: a backslash already in
/// the value changes the meaning of the inserted escape, which lets a value close
/// its own scalar and inject sibling keys or a frontmatter delimiter. Every escape
/// character, and every C0 control, therefore has to be encoded here.
public func yamlDoubleQuotedScalar(_ value: String) -> String {
    var encoded = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\\":
            encoded += "\\\\"
        case "\"":
            encoded += "\\\""
        case "\n":
            encoded += "\\n"
        case "\r":
            encoded += "\\r"
        case "\t":
            encoded += "\\t"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7F {
                encoded += String(format: "\\x%02X", scalar.value)
            } else {
                encoded.unicodeScalars.append(scalar)
            }
        }
    }
    return encoded + "\""
}

/// A key is emitted bare only while it cannot alter the structure of the block.
private func yamlKey(_ key: String) -> String {
    let isPlain = !key.isEmpty && key.unicodeScalars.allSatisfy { scalar in
        let character = Character(scalar)
        return scalar.isASCII
            && (character.isLetter || character.isNumber || character == "_" || character == "-" || character == ".")
    }
    return isPlain ? key : yamlDoubleQuotedScalar(key)
}

public func renderFrontmatter(_ metadata: [String: Any], body: String) -> String {
    func scalar(_ value: Any) -> String {
        switch value {
        case let value as String:
            return yamlDoubleQuotedScalar(value)
        case let value as [String]:
            if value.isEmpty { return "[]" }
            return "[" + value.map(yamlDoubleQuotedScalar).joined(separator: ", ") + "]"
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue ? "true" : "false"
            }
            return value.stringValue
        case let value as Bool:
            return value ? "true" : "false"
        case Optional<Any>.none:
            return "null"
        default:
            return yamlDoubleQuotedScalar(String(describing: value))
        }
    }

    let lines = metadata.keys.sorted().map { key in
        "\(yamlKey(key)): \(scalar(metadata[key] as Any))"
    }
    return "---\n" + lines.joined(separator: "\n") + "\n---\n\n" + body
}
