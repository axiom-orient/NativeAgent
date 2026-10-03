import Foundation
import HTMLDocument

package struct ASKHTMLDocument: Sendable, Hashable {
    fileprivate let base: Document

    fileprivate init(_ base: Document) {
        self.base = base
    }

    package var title: String? {
        base.title
    }

    package var normalizedText: String {
        base.normalizedText
    }

    package var documentElement: ASKHTMLElement? {
        base.documentElement.map(ASKHTMLElement.init)
    }

    package var body: ASKHTMLElement? {
        base.body.map(ASKHTMLElement.init)
    }

    package func select(_ query: String) throws -> [ASKHTMLElement] {
        try base.select(query).map(ASKHTMLElement.init)
    }
}

package struct ASKHTMLElement: Sendable, Hashable {
    fileprivate let base: Element

    fileprivate init(_ base: Element) {
        self.base = base
    }

    package var name: String {
        base.name
    }

    package var normalizedText: String {
        base.normalizedText
    }

    package var children: [ASKHTMLNode] {
        base.children.map(ASKHTMLNode.init)
    }

    package func attribute(named name: String) -> String? {
        base.attribute(named: name)
    }

    package func select(_ query: String) throws -> [ASKHTMLElement] {
        try base.select(query).map(ASKHTMLElement.init)
    }
}

package enum ASKHTMLNode: Sendable, Hashable {
    case element(ASKHTMLElement)
    case text(String)
    case data(String)
    case comment(String)
    case doctype(String)

    fileprivate init(_ base: Node) {
        switch base {
        case .element(let element):
            self = .element(ASKHTMLElement(element))
        case .text(let textNode):
            self = .text(textNode.text)
        case .data(let dataNode):
            self = .data(dataNode.text)
        case .comment(let commentNode):
            self = .comment(commentNode.text)
        case .doctype(let doctypeNode):
            self = .doctype(doctypeNode.name)
        }
    }

    package var element: ASKHTMLElement? {
        if case .element(let element) = self {
            return element
        }
        return nil
    }
}

package enum ASKHTMLParser {
    package static func parse(_ html: String) throws -> ASKHTMLDocument {
        try ASKHTMLDocument(MDSwift.parseHTML(html))
    }
}
