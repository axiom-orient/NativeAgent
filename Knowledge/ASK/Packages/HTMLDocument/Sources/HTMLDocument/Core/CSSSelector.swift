public struct CSSSelectorGroup: Sendable, Hashable {
    public let selectors: [CSSComplexSelector]

    public init(selectors: [CSSComplexSelector]) {
        self.selectors = selectors
    }
}

public struct CSSComplexSelector: Sendable, Hashable {
    public let steps: [CSSSelectorStep]

    public init(steps: [CSSSelectorStep]) {
        self.steps = steps
    }
}

public struct CSSSelectorStep: Sendable, Hashable {
    public let combinator: CSSCombinator?
    public let compound: CSSCompoundSelector

    public init(combinator: CSSCombinator?, compound: CSSCompoundSelector) {
        self.combinator = combinator
        self.compound = compound
    }
}

public enum CSSCombinator: Sendable, Hashable {
    case descendant
    case child
    case adjacentSibling
    case generalSibling
}

public struct CSSNthExpression: Sendable, Hashable {
    public let a: Int
    public let b: Int

    public init(a: Int, b: Int) {
        self.a = a
        self.b = b
    }

    public func matches(index: Int) -> Bool {
        guard index > 0 else {
            return false
        }

        if a == 0 {
            return index == b
        }

        let delta = index - b
        if a > 0 {
            return delta >= 0 && delta % a == 0
        }

        return delta <= 0 && delta % a == 0
    }
}

public struct CSSCompoundSelector: Sendable, Hashable {
    public let components: [CSSSimpleSelector]

    public init(components: [CSSSimpleSelector]) {
        self.components = components
    }
}

public indirect enum CSSSimpleSelector: Sendable, Hashable {
    case universal
    case tag(String)
    case id(String)
    case className(String)
    case attributeExists(String)
    case attributeEquals(String, String)
    case attributeStartsWith(String, String)
    case attributeEndsWith(String, String)
    case attributeContains(String, String)
    case containsText(String)
    case containsOwnText(String)
    case firstChild
    case lastChild
    case firstOfType
    case lastOfType
    case nthChild(CSSNthExpression)
    case nthOfType(CSSNthExpression)
    case not(CSSSelectorGroup)
    case has(CSSSelectorGroup)
}

public enum CSSSelectorParser {
    public static func parse(_ query: String) throws -> CSSSelectorGroup {
        let characters = Array(query)
        var parser = Parser(characters: characters)
        return try parser.parse()
    }

    private struct Parser {
        let characters: [Character]
        var position: Int = 0

        mutating func parse(relativeToScope: Bool = false) throws -> CSSSelectorGroup {
            var selectors: [CSSComplexSelector] = []

            while true {
                skipWhitespace()
                guard !isAtEnd else {
                    break
                }

                let selector = try parseComplexSelector(relativeToScope: relativeToScope)
                selectors.append(selector)

                skipWhitespace()
                if currentCharacter == "," {
                    advance()
                    continue
                }

                break
            }

            guard !selectors.isEmpty else {
                throw MDSwiftCoreError.selectorSyntax("query is empty")
            }

            skipWhitespace()
            if !isAtEnd {
                throw MDSwiftCoreError.selectorSyntax("unexpected trailing input")
            }

            return CSSSelectorGroup(selectors: selectors)
        }

        mutating func parseComplexSelector(relativeToScope: Bool) throws -> CSSComplexSelector {
            let firstCombinator = try initialCombinator(relativeToScope: relativeToScope)
            let first = try parseCompoundSelector()
            var steps: [CSSSelectorStep] = [.init(combinator: firstCombinator, compound: first)]

            while true {
                let hadWhitespace = skipWhitespace()
                guard !isAtEnd, currentCharacter != ",", currentCharacter != ")" else {
                    break
                }

                let combinator = try parseFollowingCombinator(hadWhitespace: hadWhitespace)
                let next = try parseCompoundSelector()
                steps.append(.init(combinator: combinator, compound: next))
            }

            return CSSComplexSelector(steps: steps)
        }

        mutating func parseCompoundSelector() throws -> CSSCompoundSelector {
            var components: [CSSSimpleSelector] = []

            while !isAtEnd {
                let character = currentCharacter

                if ParsingSupport.isWhitespace(character)
                    || character == ">"
                    || character == "+"
                    || character == "~"
                    || character == ","
                    || character == ")" {
                    break
                }

                switch character {
                case "*":
                    components.append(.universal)
                    advance()

                case "#":
                    advance()
                    let identifier = try consumeSelectorIdentifier(after: "#")
                    components.append(.id(identifier))

                case ".":
                    advance()
                    let identifier = try consumeSelectorIdentifier(after: ".")
                    components.append(.className(identifier))

                case "[":
                    components.append(try parseAttributeSelector())

                case ":":
                    components.append(try parsePseudoSelector())

                default:
                    let identifier = try consumeSelectorIdentifier(after: "tag")
                    components.append(.tag(ParsingSupport.lowercase(identifier)))
                }
            }

            guard !components.isEmpty else {
                throw MDSwiftCoreError.selectorSyntax("expected selector component")
            }

            return CSSCompoundSelector(components: components)
        }

        mutating func parseAttributeSelector() throws -> CSSSimpleSelector {
            consume("[")
            skipWhitespace()

            let name = ParsingSupport.lowercase(try consumeAttributeIdentifier(after: "["))

            skipWhitespace()
            if currentCharacter == "]" {
                consume("]")
                return .attributeExists(name)
            }

            let operation = try parseAttributeOperation()
            skipWhitespace()
            let value = try consumeAttributeValue()

            skipWhitespace()
            guard currentCharacter == "]" else {
                throw MDSwiftCoreError.selectorSyntax("unterminated attribute selector")
            }
            consume("]")

            switch operation {
            case .equals:
                return .attributeEquals(name, value)
            case .startsWith:
                return .attributeStartsWith(name, value)
            case .endsWith:
                return .attributeEndsWith(name, value)
            case .contains:
                return .attributeContains(name, value)
            }
        }

        mutating func parsePseudoSelector() throws -> CSSSimpleSelector {
            consume(":")
            let name = ParsingSupport.lowercase(try consumePseudoIdentifier(after: ":"))

            switch name {
            case "contains":
                let value = try normalizedPseudoTextArgument(for: ":contains")
                return .containsText(value)

            case "containsown":
                let value = try normalizedPseudoTextArgument(for: ":containsOwn")
                return .containsOwnText(value)

            case "first-child":
                return .firstChild

            case "last-child":
                return .lastChild

            case "first-of-type":
                return .firstOfType

            case "last-of-type":
                return .lastOfType

            case "nth-child":
                let expression = try parseNthExpression(from: consumePseudoFunctionArgument(for: ":nth-child"), pseudoName: ":nth-child")
                return .nthChild(expression)

            case "nth-of-type":
                let expression = try parseNthExpression(from: consumePseudoFunctionArgument(for: ":nth-of-type"), pseudoName: ":nth-of-type")
                return .nthOfType(expression)

            case "not":
                let rawArgument = try consumePseudoFunctionArgument(for: ":not")
                return .not(try parseNestedSelectorGroup(rawArgument, pseudoName: ":not"))

            case "has":
                let rawArgument = try consumePseudoFunctionArgument(for: ":has")
                return .has(try parseRelativeSelectorGroup(rawArgument, pseudoName: ":has"))

            default:
                throw MDSwiftCoreError.selectorSyntax("unsupported pseudo selector :\(name)")
            }
        }

        mutating func parseAttributeOperation() throws -> AttributeOperation {
            switch currentCharacter {
            case "=":
                advance()
                return .equals
            case "^":
                advance()
                guard currentCharacter == "=" else {
                    throw MDSwiftCoreError.selectorSyntax("expected '=' after '^' in attribute selector")
                }
                advance()
                return .startsWith
            case "$":
                advance()
                guard currentCharacter == "=" else {
                    throw MDSwiftCoreError.selectorSyntax("expected '=' after '$' in attribute selector")
                }
                advance()
                return .endsWith
            case "*":
                advance()
                guard currentCharacter == "=" else {
                    throw MDSwiftCoreError.selectorSyntax("expected '=' after '*' in attribute selector")
                }
                advance()
                return .contains
            default:
                throw MDSwiftCoreError.selectorSyntax("unsupported attribute selector operator")
            }
        }

        mutating func consumeAttributeValue() throws -> String {
            if currentCharacter == "\"" || currentCharacter == "'" {
                let quote = currentCharacter
                advance()
                let start = position
                while !isAtEnd, currentCharacter != quote {
                    advance()
                }
                if isAtEnd {
                    throw MDSwiftCoreError.selectorSyntax("unterminated quoted attribute value")
                }
                let value = String(characters[start..<position])
                consume(quote)
                return value
            }

            let start = position
            while !isAtEnd, !ParsingSupport.isWhitespace(currentCharacter), currentCharacter != "]" {
                advance()
            }
            guard start != position else {
                throw MDSwiftCoreError.selectorSyntax("expected attribute value")
            }
            return String(characters[start..<position])
        }

        mutating func consumePseudoFunctionArgument(for pseudo: String) throws -> String {
            guard currentCharacter == "(" else {
                throw MDSwiftCoreError.selectorSyntax("expected '(' after \(pseudo)")
            }
            advance()

            var result = String()
            var depth = 0
            var quote: Character? = nil

            while !isAtEnd {
                let character = currentCharacter
                advance()

                if let activeQuote = quote {
                    if character == "\\" {
                        guard !isAtEnd else {
                            throw MDSwiftCoreError.selectorSyntax("unterminated escape sequence in \(pseudo) argument")
                        }
                        result.append(character)
                        result.append(currentCharacter)
                        advance()
                        continue
                    }

                    result.append(character)
                    if character == activeQuote {
                        quote = nil
                    }
                    continue
                }

                switch character {
                case "\\":
                    guard !isAtEnd else {
                        throw MDSwiftCoreError.selectorSyntax("unterminated escape sequence in \(pseudo) argument")
                    }
                    result.append(character)
                    result.append(currentCharacter)
                    advance()
                case "\"", "'":
                    quote = character
                    result.append(character)
                case "(":
                    depth += 1
                    result.append(character)
                case ")":
                    if depth == 0 {
                        return result
                    }
                    depth -= 1
                    result.append(character)
                default:
                    result.append(character)
                }
            }

            throw MDSwiftCoreError.selectorSyntax("unterminated \(pseudo)(...) selector")
        }

        func parseNestedSelectorGroup(_ rawArgument: String, pseudoName: String) throws -> CSSSelectorGroup {
            let trimmed = ParsingSupport.trimWhitespace(rawArgument)
            guard !trimmed.isEmpty else {
                throw MDSwiftCoreError.selectorSyntax("\(pseudoName) argument must not be empty")
            }
            return try CSSSelectorParser.parse(trimmed)
        }

        func parseRelativeSelectorGroup(_ rawArgument: String, pseudoName: String) throws -> CSSSelectorGroup {
            let trimmed = ParsingSupport.trimWhitespace(rawArgument)
            guard !trimmed.isEmpty else {
                throw MDSwiftCoreError.selectorSyntax("\(pseudoName) argument must not be empty")
            }
            var parser = Parser(characters: Array(trimmed))
            return try parser.parse(relativeToScope: true)
        }

        mutating func normalizedPseudoTextArgument(for pseudo: String) throws -> String {
            let raw = try consumePseudoFunctionArgument(for: pseudo)
            let trimmed = ParsingSupport.trimWhitespace(raw)
            let unquoted = stripWrappingQuotes(trimmed)
            let normalized = ParsingSupport.collapseWhitespace(unquoted).lowercased()
            guard !normalized.isEmpty else {
                throw MDSwiftCoreError.selectorSyntax("\(pseudo)(text) requires non-empty text")
            }
            return normalized
        }

        func parseNthExpression(from rawArgument: String, pseudoName: String) throws -> CSSNthExpression {
            let trimmed = ParsingSupport.trimWhitespace(rawArgument).lowercased()
            guard !trimmed.isEmpty else {
                throw MDSwiftCoreError.selectorSyntax("\(pseudoName) argument must not be empty")
            }

            let compact = trimmed.filter { !$0.isWhitespace }
            if compact == "odd" {
                return CSSNthExpression(a: 2, b: 1)
            }
            if compact == "even" {
                return CSSNthExpression(a: 2, b: 0)
            }

            if let nIndex = compact.firstIndex(of: "n") {
                let coefficientText = String(compact[..<nIndex])
                let remainderText = String(compact[compact.index(after: nIndex)...])
                let a = try parseNthCoefficient(coefficientText, pseudoName: pseudoName)
                let b = try parseSignedInteger(remainderText, pseudoName: pseudoName, allowEmpty: true)
                return CSSNthExpression(a: a, b: b)
            }

            guard let exact = Int(compact) else {
                throw MDSwiftCoreError.selectorSyntax("unsupported \(pseudoName) expression")
            }
            return CSSNthExpression(a: 0, b: exact)
        }

        func parseNthCoefficient(_ text: String, pseudoName: String) throws -> Int {
            if text.isEmpty || text == "+" {
                return 1
            }
            if text == "-" {
                return -1
            }
            guard let value = Int(text) else {
                throw MDSwiftCoreError.selectorSyntax("unsupported \(pseudoName) coefficient")
            }
            return value
        }

        func parseSignedInteger(_ text: String, pseudoName: String, allowEmpty: Bool) throws -> Int {
            if text.isEmpty {
                if allowEmpty {
                    return 0
                }
                throw MDSwiftCoreError.selectorSyntax("expected integer in \(pseudoName)")
            }

            let normalized = text.first == "+" ? String(text.dropFirst()) : text
            guard let value = Int(normalized) else {
                throw MDSwiftCoreError.selectorSyntax("unsupported \(pseudoName) offset")
            }
            return value
        }

        func stripWrappingQuotes(_ value: String) -> String {
            guard value.count >= 2, let first = value.first, let last = value.last else {
                return value
            }

            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                return String(value.dropFirst().dropLast())
            }

            return value
        }

        mutating func consumeSelectorIdentifier(after context: String) throws -> String {
            let start = position
            while !isAtEnd, isSelectorIdentifierCharacter(currentCharacter) {
                advance()
            }
            guard start != position else {
                throw MDSwiftCoreError.selectorSyntax("expected identifier after \(context)")
            }
            return String(characters[start..<position])
        }

        mutating func consumeAttributeIdentifier(after context: String) throws -> String {
            let start = position
            while !isAtEnd, isAttributeIdentifierCharacter(currentCharacter) {
                advance()
            }
            guard start != position else {
                throw MDSwiftCoreError.selectorSyntax("expected identifier after \(context)")
            }
            return String(characters[start..<position])
        }

        mutating func consumePseudoIdentifier(after context: String) throws -> String {
            let start = position
            while !isAtEnd, isPseudoIdentifierCharacter(currentCharacter) {
                advance()
            }
            guard start != position else {
                throw MDSwiftCoreError.selectorSyntax("expected identifier after \(context)")
            }
            return String(characters[start..<position])
        }

        func isSelectorIdentifierCharacter(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || $0.properties.numericType != nil }
                || character == "-"
                || character == "_"
        }

        func isAttributeIdentifierCharacter(_ character: Character) -> Bool {
            isSelectorIdentifierCharacter(character) || character == ":"
        }

        func isPseudoIdentifierCharacter(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || $0.properties.numericType != nil }
                || character == "-"
        }

        @discardableResult
        mutating func skipWhitespace() -> Bool {
            let start = position
            while !isAtEnd, ParsingSupport.isWhitespace(currentCharacter) {
                advance()
            }
            return position > start
        }

        mutating func consume(_ character: Character) {
            guard !isAtEnd, currentCharacter == character else { return }
            advance()
        }

        mutating func advance() {
            position += 1
        }

        mutating func initialCombinator(relativeToScope: Bool) throws -> CSSCombinator? {
            guard relativeToScope else {
                return nil
            }

            switch currentCharacter {
            case ">":
                advance()
                skipWhitespace()
                return .child
            case "+":
                advance()
                skipWhitespace()
                return .adjacentSibling
            case "~":
                advance()
                skipWhitespace()
                return .generalSibling
            default:
                return .descendant
            }
        }

        mutating func parseFollowingCombinator(hadWhitespace: Bool) throws -> CSSCombinator {
            switch currentCharacter {
            case ">":
                advance()
                skipWhitespace()
                return .child
            case "+":
                advance()
                skipWhitespace()
                return .adjacentSibling
            case "~":
                advance()
                skipWhitespace()
                return .generalSibling
            default:
                guard hadWhitespace else {
                    throw MDSwiftCoreError.selectorSyntax("expected combinator or end of selector")
                }
                return .descendant
            }
        }

        var isAtEnd: Bool {
            position >= characters.count
        }

        var currentCharacter: Character {
            guard position < characters.count else {
                return "\0"
            }
            return characters[position]
        }
    }

    private enum AttributeOperation {
        case equals
        case startsWith
        case endsWith
        case contains
    }
}
