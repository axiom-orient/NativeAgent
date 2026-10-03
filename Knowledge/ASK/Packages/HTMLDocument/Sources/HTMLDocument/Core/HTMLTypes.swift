    public struct HTMLAttribute: Sendable, Hashable {
        public let name: String
        public let value: String?

        public init(name: String, value: String?) {
            self.name = name
            self.value = value
        }
    }

    public struct HTMLStartTag: Sendable, Hashable {
        public let name: String
        public let attributes: [HTMLAttribute]
        public let isSelfClosing: Bool

        public init(name: String, attributes: [HTMLAttribute] = [], isSelfClosing: Bool = false) {
            self.name = name
            self.attributes = attributes
            self.isSelfClosing = isSelfClosing
        }
    }

    public enum HTMLToken: Sendable, Hashable {
        case doctype(String)
        case comment(String)
        case text(String)
        case startTag(HTMLStartTag)
        case endTag(String)
    }

    public struct HTMLParseOptions: Sendable, Hashable {
        public var normalizeTagNames: Bool
        public var normalizeAttributeNames: Bool
        public var decodeEntities: Bool

        public init(
            normalizeTagNames: Bool = true,
            normalizeAttributeNames: Bool = true,
            decodeEntities: Bool = true
        ) {
            self.normalizeTagNames = normalizeTagNames
            self.normalizeAttributeNames = normalizeAttributeNames
            self.decodeEntities = decodeEntities
        }

        public static let standard = HTMLParseOptions()
    }

    public struct HTMLSerializationOptions: Sendable, Hashable {
        public var escapeNBSPAsEntity: Bool

        public init(escapeNBSPAsEntity: Bool = true) {
            self.escapeNBSPAsEntity = escapeNBSPAsEntity
        }

        public static let standard = HTMLSerializationOptions()
    }

    public protocol HTMLTreeSink<Output>: Sendable {
        associatedtype Output

        mutating func beginDocument() throws
        mutating func insertDoctype(_ name: String) throws
        mutating func insertComment(_ text: String) throws
        mutating func insertText(_ text: String) throws
        mutating func insertData(_ text: String) throws
        mutating func insertStartTag(_ tag: HTMLStartTag) throws
        mutating func insertEndTag(named name: String) throws
        mutating func finishDocument() throws -> Output
    }
