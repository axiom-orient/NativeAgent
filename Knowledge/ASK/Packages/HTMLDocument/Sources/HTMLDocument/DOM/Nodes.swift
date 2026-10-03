
    public struct Document: Sendable, Hashable {
        public let children: [Node]
        public let serializationOptions: HTMLSerializationOptions

        public init(children: [Node], serializationOptions: HTMLSerializationOptions = .standard) {
            self.children = children
            self.serializationOptions = serializationOptions
        }

        public var html: String {
            HTMLSerializer.serialize(document: self)
        }

        public var textContent: String {
            children.map(\.textContent).joined()
        }

        public var normalizedText: String {
            TextCollector.normalizedText(from: children)
        }

        public var documentElement: Element? {
            if let html = children.compactMap(\.element).first(where: { $0.name == "html" }) {
                return html
            }
            return children.compactMap(\.element).first
        }

        public var head: Element? {
            documentElement?.childElements.first(where: { $0.name == "head" }) ??
            children.compactMap(\.element).first(where: { $0.name == "head" })
        }

        public var body: Element? {
            documentElement?.childElements.first(where: { $0.name == "body" }) ??
            children.compactMap(\.element).first(where: { $0.name == "body" })
        }

        public var title: String? {
            head?.firstDescendant(named: "title")?.normalizedText
        }

        public func select(_ query: String) throws -> [Element] {
            let selector = try CSSSelectorParser.parse(query)
            return SelectorEngine.select(selector, in: self)
        }

        public func serialized(with options: HTMLSerializationOptions) -> String {
            HTMLSerializer.serialize(document: Document(children: children, serializationOptions: options))
        }

        public func cleaned(with safelist: Safelist, baseURI: String? = nil) -> Document {
            HTMLCleaner(safelist).clean(self, baseURI: baseURI)
        }
    }

    public indirect enum Node: Sendable, Hashable {
        case element(Element)
        case text(TextNode)
        case data(DataNode)
        case comment(CommentNode)
        case doctype(DoctypeNode)

        public var element: Element? {
            if case .element(let element) = self {
                return element
            }
            return nil
        }

        public var outerHTML: String {
            HTMLSerializer.serialize(node: self, options: .standard)
        }

        public var textContent: String {
            switch self {
            case .element(let element):
                return element.textContent
            case .text(let textNode):
                return textNode.text
            case .data, .comment, .doctype:
                return String()
            }
        }
    }

    public struct Element: Sendable, Hashable {
        public let name: String
        public let attributes: [HTMLAttribute]
        public let children: [Node]
        public let isSelfClosing: Bool

        public init(
            name: String,
            attributes: [HTMLAttribute] = [],
            children: [Node] = [],
            isSelfClosing: Bool = false
        ) {
            self.name = name
            self.attributes = attributes
            self.children = children
            self.isSelfClosing = isSelfClosing
        }

        public var id: String? {
            attribute(named: "id")
        }

        public var classes: [String] {
            guard let classValue = attribute(named: "class") else {
                return []
            }

            return classValue
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        }

        public var childElements: [Element] {
            children.compactMap(\.element)
        }

        public var innerHTML: String {
            children.map(\.outerHTML).joined()
        }

        public var outerHTML: String {
            HTMLSerializer.serialize(element: self, options: .standard)
        }

        public var textContent: String {
            children.map(\.textContent).joined()
        }

        public var normalizedText: String {
            TextCollector.normalizedText(from: children)
        }

        public func attribute(named name: String) -> String? {
            let normalized = name.lowercased()
            return attributes.last(where: { $0.name.lowercased() == normalized })?.value
        }

        public func hasAttribute(_ name: String) -> Bool {
            let normalizedName = name.lowercased()
            return attributes.contains(where: { $0.name.lowercased() == normalizedName })
        }

        public func hasClass(_ value: String) -> Bool {
            classes.contains(value)
        }

        public func select(_ query: String) throws -> [Element] {
            let selector = try CSSSelectorParser.parse(query)
            return SelectorEngine.select(selector, in: self)
        }

        fileprivate func firstDescendant(named targetName: String) -> Element? {
            let normalizedTarget = targetName.lowercased()
            for child in childElements {
                if child.name.lowercased() == normalizedTarget {
                    return child
                }
                if let match = child.firstDescendant(named: normalizedTarget) {
                    return match
                }
            }
            return nil
        }
    }

    public struct TextNode: Sendable, Hashable {
        public let text: String

        public init(_ text: String) {
            self.text = text
        }
    }

    public struct DataNode: Sendable, Hashable {
        public let text: String

        public init(_ text: String) {
            self.text = text
        }
    }

    public struct CommentNode: Sendable, Hashable {
        public let text: String

        public init(_ text: String) {
            self.text = text
        }
    }

    public struct DoctypeNode: Sendable, Hashable {
        public let name: String

        public init(_ name: String) {
            self.name = name
        }
    }

    enum TextCollector {
        static func normalizedText(from nodes: [Node]) -> String {
            var parts: [String] = []
            collect(nodes, into: &parts)
            return parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        private static func collect(_ nodes: [Node], into parts: inout [String]) {
            for node in nodes {
                switch node {
                case .text(let textNode):
                    let value = textNode.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if !value.isEmpty {
                        parts.append(value)
                    }
                case .element(let element):
                    collect(element.children, into: &parts)
                case .data, .comment, .doctype:
                    continue
                }
            }
        }
    }
