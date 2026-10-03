    public enum HTMLEntities {
        private static let namedDecodeMap: [String: Character] = [
            "amp": "&",
            "lt": "<",
            "gt": ">",
            "quot": "\"",
            "apos": "'",
            "nbsp": "\u{00A0}"
        ]

        public static func decode(_ value: String) -> String {
            var result = String()
            let characters = Array(value)
            var index = 0

            while index < characters.count {
                let character = characters[index]
                if character == "&",
                   let semicolonIndex = characters[index...].firstIndex(of: ";"),
                   semicolonIndex > index + 1 {
                    let entity = String(characters[(index + 1)..<semicolonIndex])
                    if let decoded = decodeEntity(entity) {
                        result.append(decoded)
                        index = semicolonIndex + 1
                        continue
                    }
                }

                result.append(character)
                index += 1
            }

            return result
        }

        public static func escapeText(_ value: String, options: HTMLSerializationOptions = .standard) -> String {
            escape(value, forAttribute: false, options: options)
        }

        public static func escapeAttribute(_ value: String, options: HTMLSerializationOptions = .standard) -> String {
            escape(value, forAttribute: true, options: options)
        }

        private static func escape(_ value: String, forAttribute: Bool, options: HTMLSerializationOptions) -> String {
            var result = String()

            for character in value {
                switch character {
                case "&":
                    result += "&amp;"
                case "<":
                    result += "&lt;"
                case ">":
                    result += "&gt;"
                case "\"":
                    result += forAttribute ? "&quot;" : "\""
                case "'":
                    result += forAttribute ? "&#39;" : "'"
                case "\u{00A0}":
                    result += options.escapeNBSPAsEntity ? "&nbsp;" : "\u{00A0}"
                default:
                    result.append(character)
                }
            }

            return result
        }

        private static func decodeEntity(_ entity: String) -> Character? {
            if let named = namedDecodeMap[entity.lowercased()] {
                return named
            }

            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                let hex = entity.dropFirst(2)
                if let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) {
                    return Character(scalar)
                }
            }

            if entity.hasPrefix("#") {
                let decimal = entity.dropFirst()
                if let value = UInt32(decimal), let scalar = UnicodeScalar(value) {
                    return Character(scalar)
                }
            }

            return nil
        }
    }
