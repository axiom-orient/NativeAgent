
    enum HTMLSerializer {
        static func serialize(document: Document) -> String {
            document.children.map { serialize(node: $0, options: document.serializationOptions) }.joined()
        }

        static func serialize(node: Node, options: HTMLSerializationOptions) -> String {
            switch node {
            case .element(let element):
                return serialize(element: element, options: options)
            case .text(let textNode):
                return HTMLEntities.escapeText(textNode.text, options: options)
            case .data(let dataNode):
                return dataNode.text
            case .comment(let comment):
                return "<!--\(comment.text)-->"
            case .doctype(let doctype):
                return "<!DOCTYPE \(doctype.name)>"
            }
        }

        static func serialize(element: Element, options: HTMLSerializationOptions) -> String {
            var result = "<\(element.name)"
            for attribute in element.attributes {
                result += " \(attribute.name)"
                if let value = attribute.value {
                    result += "=\"\(HTMLEntities.escapeAttribute(value, options: options))\""
                }
            }

            let isVoid = HTMLTagRules.isVoid(element.name)
            if isVoid || (element.isSelfClosing && element.children.isEmpty) {
                result += " />"
                return result
            }

            result += ">"
            result += element.children.map { serialize(node: $0, options: options) }.joined()
            result += "</\(element.name)>"
            return result
        }
    }
