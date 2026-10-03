
    public struct DOMTreeBuilder: HTMLTreeSink {
        public typealias Output = Document

        private struct PartialElement: Sendable {
            var name: String
            var attributes: [HTMLAttribute]
            var children: [Node]
            var isSelfClosing: Bool
        }

        private var rootChildren: [Node] = []
        private var openElements: [PartialElement] = []
        private let serializationOptions: HTMLSerializationOptions

        public init(serializationOptions: HTMLSerializationOptions = .standard) {
            self.serializationOptions = serializationOptions
        }

        public mutating func beginDocument() throws {
            rootChildren = []
            openElements = []
        }

        public mutating func insertDoctype(_ name: String) throws {
            append(.doctype(DoctypeNode(name)))
        }

        public mutating func insertComment(_ text: String) throws {
            append(.comment(CommentNode(text)))
        }

        public mutating func insertText(_ text: String) throws {
            guard !text.isEmpty else { return }
            append(.text(TextNode(text)))
        }

        public mutating func insertData(_ text: String) throws {
            guard !text.isEmpty else { return }
            append(.data(DataNode(text)))
        }

        public mutating func insertStartTag(_ tag: HTMLStartTag) throws {
            if tag.isSelfClosing {
                append(
                    .element(
                        Element(
                            name: tag.name,
                            attributes: tag.attributes,
                            children: [],
                            isSelfClosing: true
                        )
                    )
                )
                return
            }

            openElements.append(
                PartialElement(
                    name: tag.name,
                    attributes: tag.attributes,
                    children: [],
                    isSelfClosing: false
                )
            )
        }

        public mutating func insertEndTag(named name: String) throws {
            guard let partial = openElements.popLast() else {
                return
            }

            let element = Element(
                name: partial.name,
                attributes: partial.attributes,
                children: partial.children,
                isSelfClosing: partial.isSelfClosing
            )

            append(.element(element))
        }

        public mutating func finishDocument() throws -> Document {
            while !openElements.isEmpty {
                try insertEndTag(named: openElements.last?.name ?? "")
            }

            return Document(children: rootChildren, serializationOptions: serializationOptions)
        }

        private mutating func append(_ node: Node) {
            if openElements.isEmpty {
                rootChildren.append(node)
            } else {
                openElements[openElements.index(before: openElements.endIndex)].children.append(node)
            }
        }
    }
