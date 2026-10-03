enum ParsingSupport {
    static func lowercase(_ value: String) -> String {
        value.lowercased()
    }

    static func isWhitespace(_ character: Character) -> Bool {
        character.isWhitespace
    }

    static func isNameCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || $0.properties.numericType != nil }
            || character == "-" || character == "_" || character == ":"
    }

    static func collapseWhitespace(_ value: String) -> String {
        var result = String()
        var lastWasWhitespace = false

        for character in value {
            if character.isWhitespace {
                if !lastWasWhitespace {
                    result.append(" ")
                    lastWasWhitespace = true
                }
            } else {
                result.append(character)
                lastWasWhitespace = false
            }
        }

        return trimWhitespace(result)
    }

    static func trimWhitespace(_ value: String) -> String {
        var start = value.startIndex
        var end = value.endIndex

        while start < end, value[start].isWhitespace {
            start = value.index(after: start)
        }

        while start < end {
            let previous = value.index(before: end)
            if value[previous].isWhitespace {
                end = previous
            } else {
                break
            }
        }

        return String(value[start..<end])
    }
}
