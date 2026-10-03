import Foundation

extension JSONValue {
    public func canonicalCharacterCount() throws -> Int {
        switch self {
        case .null:
            return 4
        case .bool(let value):
            return value ? 4 : 5
        case .integer(let value):
            return String(value).count
        case .number(let value):
            guard let text = canonicalJSONNumberText(value) else {
                throw JSONValueStructureError.nonFiniteNumber
            }
            return text.count
        case .string(let value):
            return escapedJSONStringCharacterCount(value)
        case .array(let values):
            var count = 2
            for index in values.indices {
                if index > values.startIndex {
                    count += 1
                }
                count += try values[index].canonicalCharacterCount()
            }
            return count
        case .object(let values):
            var count = 2
            for (index, entry) in values.enumerated() {
                if index > 0 {
                    count += 1
                }
                count += escapedJSONStringCharacterCount(entry.key)
                count += 1
                count += try entry.value.canonicalCharacterCount()
            }
            return count
        }
    }

    public func canonicalUTF8ByteCount() throws -> Int {
        switch self {
        case .null:
            return 4
        case .bool(let value):
            return value ? 4 : 5
        case .integer(let value):
            return String(value).utf8.count
        case .number(let value):
            guard let text = canonicalJSONNumberText(value) else {
                throw JSONValueStructureError.nonFiniteNumber
            }
            return text.utf8.count
        case .string(let value):
            return escapedJSONStringUTF8ByteCount(value)
        case .array(let values):
            var count = 2
            for index in values.indices {
                if index > values.startIndex {
                    count += 1
                }
                count += try values[index].canonicalUTF8ByteCount()
            }
            return count
        case .object(let values):
            var count = 2
            for (index, entry) in values.enumerated() {
                if index > 0 {
                    count += 1
                }
                count += escapedJSONStringUTF8ByteCount(entry.key)
                count += 1
                count += try entry.value.canonicalUTF8ByteCount()
            }
            return count
        }
    }
}

private func escapedJSONStringCharacterCount(_ value: String) -> Int {
    var count = 2
    for character in value {
        switch character {
        case "\"", "\\", "/":
            count += 2
        case "\u{08}", "\u{0C}", "\n", "\r", "\t":
            count += 2
        default:
            if character.unicodeScalars.count == 1,
               let scalar = character.unicodeScalars.first,
               scalar.value < 0x20 {
                count += 6
            } else {
                count += 1
            }
        }
    }
    return count
}

private func escapedJSONStringUTF8ByteCount(_ value: String) -> Int {
    var count = 2
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22, 0x2F, 0x5C:
            count += 2
        case 0x08, 0x09, 0x0A, 0x0C, 0x0D:
            count += 2
        case 0x00..<0x20:
            count += 6
        case 0x20...0x7F:
            count += 1
        case 0x80...0x7FF:
            count += 2
        case 0x800...0xFFFF:
            count += 3
        default:
            count += 4
        }
    }
    return count
}

private func canonicalJSONNumberText(_ value: Double) -> String? {
    guard value.isFinite else {
        return nil
    }
    let description = value.description
    if description.hasSuffix(".0") {
        return String(description.dropLast(2))
    }
    return description
}
