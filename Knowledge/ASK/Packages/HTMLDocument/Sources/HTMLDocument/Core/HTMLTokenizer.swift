    public struct HTMLTokenizer: Sendable {
        private let characters: [Character]
        private var position: Int

        public init(_ input: some StringProtocol) {
            self.characters = Array(String(input))
            self.position = 0
        }


        public init<Bytes: Collection>(utf8 bytes: Bytes) where Bytes.Element == UInt8 {
            self.characters = Array(String(decoding: bytes, as: UTF8.self))
            self.position = 0
        }

        public mutating func nextToken() -> HTMLToken? {
            guard !isAtEnd else {
                return nil
            }

            if currentCharacter == "<" {
                let mark = position
                advance()

                if match("!--") {
                    advance(by: 3)
                    return .comment(consumeUntil(sequence: "-->"))
                }

                if currentCharacter == "?" {
                    advance()
                    _ = consumeUntil(sequence: ">")
                    return nextToken()
                }

                if matchCaseInsensitive("!doctype") {
                    advance(by: 8)
                    return .doctype(ParsingSupport.trimWhitespace(consumeUntil(sequence: ">")))
                }

                if currentCharacter == "!" {
                    _ = consumeUntil(sequence: ">")
                    return nextToken()
                }

                if currentCharacter == "/" {
                    advance()
                    guard let name = consumeName(), !name.isEmpty else {
                        position = mark + 1
                        return .text("<")
                    }
                    skipUntil(">")
                    consume(">")
                    return .endTag(name)
                }

                guard let tag = consumeStartTag() else {
                    position = mark + 1
                    return .text("<")
                }

                return .startTag(tag)
            }

            return .text(consumeText())
        }

        public mutating func consumeRawText(untilClosingTagNamed tagName: String) -> String {
            let start = position
            let lowercasedName = ParsingSupport.lowercase(tagName)
            var search = position

            while search < characters.count {
                if characters[search] == "<",
                   search + 1 < characters.count,
                   characters[search + 1] == "/",
                   matchesTagName(lowercasedName, at: search + 2) {
                    let afterName = search + 2 + lowercasedName.count
                    if afterName >= characters.count || ParsingSupport.isWhitespace(characters[afterName]) || characters[afterName] == ">" {
                        let content = String(characters[start..<search])
                        position = afterName
                        skipUntil(">")
                        consume(">")
                        return content
                    }
                }

                search += 1
            }

            let content = String(characters[start..<characters.count])
            position = characters.count
            return content
        }

        private mutating func consumeStartTag() -> HTMLStartTag? {
            guard let name = consumeName(), !name.isEmpty else {
                return nil
            }

            var attributes: [HTMLAttribute] = []
            var isSelfClosing = false

            while !isAtEnd {
                skipWhitespace()

                guard !isAtEnd else { break }

                if currentCharacter == ">" {
                    advance()
                    break
                }

                if currentCharacter == "/" {
                    advance()
                    skipWhitespace()
                    if currentCharacter == ">" {
                        isSelfClosing = true
                        advance()
                    }
                    break
                }

                guard let attributeName = consumeName(), !attributeName.isEmpty else {
                    skipUntil(">")
                    consume(">")
                    break
                }

                skipWhitespace()

                var value: String?

                if currentCharacter == "=" {
                    advance()
                    skipWhitespace()
                    value = consumeAttributeValue()
                }

                attributes.append(HTMLAttribute(name: attributeName, value: value))
            }

            return HTMLStartTag(name: name, attributes: attributes, isSelfClosing: isSelfClosing)
        }

        private mutating func consumeAttributeValue() -> String {
            guard !isAtEnd else {
                return String()
            }

            if currentCharacter == "\"" || currentCharacter == "'" {
                let quote = currentCharacter
                advance()
                let start = position
                while !isAtEnd, currentCharacter != quote {
                    advance()
                }
                let value = String(characters[start..<position])
                consume(quote)
                return value
            }

            let start = position
            while !isAtEnd,
                  !ParsingSupport.isWhitespace(currentCharacter),
                  currentCharacter != ">" {
                advance()
            }

            return String(characters[start..<position])
        }

        private mutating func consumeText() -> String {
            let start = position
            while !isAtEnd, currentCharacter != "<" {
                advance()
            }
            return String(characters[start..<position])
        }

        private mutating func consumeUntil(sequence: String) -> String {
            let target = Array(sequence)
            let start = position

            while position < characters.count {
                if matches(target, at: position) {
                    let text = String(characters[start..<position])
                    advance(by: target.count)
                    return text
                }
                position += 1
            }

            return String(characters[start..<characters.count])
        }

        private mutating func skipWhitespace() {
            while !isAtEnd, ParsingSupport.isWhitespace(currentCharacter) {
                advance()
            }
        }

        private mutating func skipUntil(_ character: Character) {
            while !isAtEnd, currentCharacter != character {
                advance()
            }
        }

        private mutating func consume(_ character: Character) {
            if !isAtEnd, currentCharacter == character {
                advance()
            }
        }

        private mutating func consumeName() -> String? {
            guard !isAtEnd, ParsingSupport.isNameCharacter(currentCharacter) else {
                return nil
            }

            let start = position
            while !isAtEnd, ParsingSupport.isNameCharacter(currentCharacter) {
                advance()
            }

            return String(characters[start..<position])
        }

        private func matchesTagName(_ tagName: String, at position: Int) -> Bool {
            let target = Array(tagName)
            guard position + target.count <= characters.count else {
                return false
            }

            for offset in 0..<target.count {
                let lhs = String(characters[position + offset]).lowercased()
                let rhs = String(target[offset]).lowercased()
                if lhs != rhs {
                    return false
                }
            }

            return true
        }

        private func match(_ prefix: String) -> Bool {
            matches(Array(prefix), at: position)
        }

        private func matchCaseInsensitive(_ prefix: String) -> Bool {
            let target = Array(prefix)
            guard position + target.count <= characters.count else {
                return false
            }

            for offset in 0..<target.count {
                let lhs = String(characters[position + offset]).lowercased()
                let rhs = String(target[offset]).lowercased()
                if lhs != rhs {
                    return false
                }
            }

            return true
        }

        private func matches(_ target: [Character], at position: Int) -> Bool {
            guard position + target.count <= characters.count else {
                return false
            }

            for offset in 0..<target.count where characters[position + offset] != target[offset] {
                return false
            }

            return true
        }

        private mutating func advance(by count: Int = 1) {
            position = min(position + count, characters.count)
        }

        private var isAtEnd: Bool {
            position >= characters.count
        }

        private var currentCharacter: Character {
            guard position < characters.count else { return "\0" }
            return characters[position]
        }
    }
