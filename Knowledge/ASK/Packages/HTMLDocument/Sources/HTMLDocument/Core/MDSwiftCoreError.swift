    public enum MDSwiftCoreError: Error, Sendable, Equatable {
        case invalidInput(String)
        case parse(String)
        case selectorSyntax(String)
        case sanitizePolicy(String)
    }
