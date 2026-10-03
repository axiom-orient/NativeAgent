    public enum HTMLTagRules {
        private static let voidTags: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input",
            "link", "meta", "param", "source", "track", "wbr"
        ]

        private static let rawTextTags: Set<String> = [
            "script", "style"
        ]

        private static let rcDataTags: Set<String> = [
            "textarea", "title"
        ]

        private static let paragraphBreakers: Set<String> = [
            "address", "article", "aside", "blockquote", "div", "dl", "fieldset",
            "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr",
            "main", "nav", "ol", "p", "pre", "section", "table", "ul"
        ]

        public static func isVoid(_ tagName: String) -> Bool {
            voidTags.contains(tagName)
        }

        public static func isRawText(_ tagName: String) -> Bool {
            rawTextTags.contains(tagName)
        }

        public static func isRCData(_ tagName: String) -> Bool {
            rcDataTags.contains(tagName)
        }

        public static func shouldAutoClose(openElement: String, whenStarting newElement: String) -> Bool {
            switch openElement {
            case "p":
                return paragraphBreakers.contains(newElement)
            case "li":
                return newElement == "li"
            case "dt":
                return newElement == "dt" || newElement == "dd"
            case "dd":
                return newElement == "dt" || newElement == "dd"
            case "option":
                return newElement == "option"
            case "optgroup":
                return newElement == "optgroup"
            case "thead", "tbody", "tfoot":
                return newElement == "thead" || newElement == "tbody" || newElement == "tfoot"
            case "tr":
                return newElement == "tr"
            case "td", "th":
                return newElement == "td" || newElement == "th" || newElement == "tr"
            default:
                return false
            }
        }

        public static func isHeadTag(_ tagName: String) -> Bool {
            [
                "base", "link", "meta", "noscript", "script", "style", "template", "title"
            ].contains(tagName)
        }

        public static func isURLAttribute(tagName: String, attributeName: String) -> Bool {
            switch (tagName, attributeName) {
            case ("a", "href"),
                 ("area", "href"),
                 ("blockquote", "cite"),
                 ("img", "src"),
                 ("q", "cite"):
                return true
            default:
                return false
            }
        }
    }
