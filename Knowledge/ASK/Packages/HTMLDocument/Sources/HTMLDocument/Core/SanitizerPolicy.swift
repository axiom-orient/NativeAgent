    public struct Safelist: Sendable, Hashable {
        public enum URLWhitespaceMode: Sendable, Hashable {
            case trim
            case strict
        }

        private struct AttributeKey: Sendable, Hashable {
            let tagName: String
            let attributeName: String
        }

        public private(set) var allowedTags: Set<String>
        public private(set) var allowedAttributesByTag: [String: Set<String>]
        public private(set) var enforcedAttributesByTag: [String: [String: String]]
        private var allowedProtocolsByAttribute: [AttributeKey: Set<String>]
        public private(set) var preserveRelativeLinksEnabled: Bool
        public private(set) var urlWhitespacePolicy: URLWhitespaceMode

        public init(
            allowedTags: Set<String> = [],
            allowedAttributesByTag: [String: Set<String>] = [:],
            enforcedAttributesByTag: [String: [String: String]] = [:],
            preserveRelativeLinksEnabled: Bool = false,
            urlWhitespacePolicy: URLWhitespaceMode = .trim
        ) {
            self.allowedTags = allowedTags
            self.allowedAttributesByTag = allowedAttributesByTag
            self.enforcedAttributesByTag = enforcedAttributesByTag
            self.allowedProtocolsByAttribute = [:]
            self.preserveRelativeLinksEnabled = preserveRelativeLinksEnabled
            self.urlWhitespacePolicy = urlWhitespacePolicy
        }

        public static func none() -> Safelist {
            Safelist()
        }

        public static func simpleText() -> Safelist {
            Safelist()
                .addTags("b", "em", "i", "strong", "u")
        }

        public static func basic() -> Safelist {
            Safelist()
                .addTags("a", "b", "blockquote", "br", "cite", "code", "dd", "dl", "dt", "em", "i", "li", "ol", "p", "pre", "q", "small", "span", "strike", "strong", "sub", "sup", "u", "ul")
                .addAttributes("a", "href")
                .addAttributes("blockquote", "cite")
                .addAttributes("q", "cite")
                .addProtocols("a", "href", "http", "https", "mailto")
                .addProtocols("blockquote", "cite", "http", "https")
                .addProtocols("q", "cite", "http", "https")
                .addEnforcedAttribute("a", "rel", "nofollow")
        }

        public static func basicWithImages() -> Safelist {
            basic()
                .addTags("img")
                .addAttributes("img", "src", "alt")
                .addProtocols("img", "src", "http", "https")
        }

        public static func relaxed() -> Safelist {
            basicWithImages()
                .addTags("div", "h1", "h2", "h3", "h4", "h5", "h6", "table", "thead", "tbody", "tfoot", "tr", "td", "th")
        }

        public func addTags(_ tags: String...) -> Safelist {
            var copy = self
            for tag in tags {
                copy.allowedTags.insert(normalizeTag(tag))
            }
            return copy
        }

        public func removeTags(_ tags: String...) -> Safelist {
            var copy = self
            for tag in tags {
                let normalizedTag = normalizeTag(tag)
                copy.allowedTags.remove(normalizedTag)
                copy.allowedAttributesByTag.removeValue(forKey: normalizedTag)
                copy.enforcedAttributesByTag.removeValue(forKey: normalizedTag)
                copy.allowedProtocolsByAttribute = copy.allowedProtocolsByAttribute.filter { $0.key.tagName != normalizedTag }
            }
            return copy
        }

        public func addAttributes(_ tag: String, _ keys: String...) -> Safelist {
            var copy = self
            let normalizedTag = normalizeTag(tag)
            if normalizedTag != ":all" {
                copy.allowedTags.insert(normalizedTag)
            }
            var set = copy.allowedAttributesByTag[normalizedTag, default: []]
            for key in keys {
                set.insert(normalizeAttribute(key))
            }
            copy.allowedAttributesByTag[normalizedTag] = set
            return copy
        }

        public func removeAttributes(_ tag: String, _ keys: String...) -> Safelist {
            var copy = self
            let normalizedTag = normalizeTag(tag)
            guard var set = copy.allowedAttributesByTag[normalizedTag] else {
                return copy
            }
            for key in keys {
                set.remove(normalizeAttribute(key))
            }
            if set.isEmpty {
                copy.allowedAttributesByTag.removeValue(forKey: normalizedTag)
            } else {
                copy.allowedAttributesByTag[normalizedTag] = set
            }
            return copy
        }

        public func addEnforcedAttribute(_ tag: String, _ key: String, _ value: String) -> Safelist {
            var copy = self
            let normalizedTag = normalizeTag(tag)
            copy.allowedTags.insert(normalizedTag)
            var values = copy.enforcedAttributesByTag[normalizedTag, default: [:]]
            values[normalizeAttribute(key)] = value
            copy.enforcedAttributesByTag[normalizedTag] = values
            return copy
        }

        public func removeEnforcedAttribute(_ tag: String, _ key: String) -> Safelist {
            var copy = self
            let normalizedTag = normalizeTag(tag)
            guard var values = copy.enforcedAttributesByTag[normalizedTag] else {
                return copy
            }
            values.removeValue(forKey: normalizeAttribute(key))
            if values.isEmpty {
                copy.enforcedAttributesByTag.removeValue(forKey: normalizedTag)
            } else {
                copy.enforcedAttributesByTag[normalizedTag] = values
            }
            return copy
        }

        public func addProtocols(_ tag: String, _ key: String, _ protocols: String...) -> Safelist {
            var copy = self
            let normalizedTag = normalizeTag(tag)
            let normalizedKey = normalizeAttribute(key)
            copy.allowedTags.insert(normalizedTag)
            var values = copy.allowedProtocolsByAttribute[AttributeKey(tagName: normalizedTag, attributeName: normalizedKey), default: []]
            for protocolName in protocols {
                values.insert(protocolName.lowercased())
            }
            copy.allowedProtocolsByAttribute[AttributeKey(tagName: normalizedTag, attributeName: normalizedKey)] = values
            return copy
        }

        public func removeProtocols(_ tag: String, _ key: String, _ protocols: String...) -> Safelist {
            var copy = self
            let normalizedTag = normalizeTag(tag)
            let normalizedKey = normalizeAttribute(key)
            let lookupKey = AttributeKey(tagName: normalizedTag, attributeName: normalizedKey)
            guard var values = copy.allowedProtocolsByAttribute[lookupKey] else {
                return copy
            }
            for protocolName in protocols {
                values.remove(protocolName.lowercased())
            }
            if values.isEmpty {
                copy.allowedProtocolsByAttribute.removeValue(forKey: lookupKey)
            } else {
                copy.allowedProtocolsByAttribute[lookupKey] = values
            }
            return copy
        }

        public func preserveRelativeLinks(_ preserve: Bool) -> Safelist {
            var copy = self
            copy.preserveRelativeLinksEnabled = preserve
            return copy
        }

        public func urlWhitespace(_ mode: URLWhitespaceMode) -> Safelist {
            var copy = self
            copy.urlWhitespacePolicy = mode
            return copy
        }

        public func allowsTag(_ tagName: String) -> Bool {
            allowedTags.contains(normalizeTag(tagName))
        }

        public func allowsAttribute(tagName: String, attributeName: String) -> Bool {
            let normalizedTag = normalizeTag(tagName)
            let normalizedAttribute = normalizeAttribute(attributeName)
            return allowedAttributesByTag[normalizedTag]?.contains(normalizedAttribute) == true
                || allowedAttributesByTag[":all"]?.contains(normalizedAttribute) == true
        }

        public func enforcedAttributes(for tagName: String) -> [String: String] {
            enforcedAttributesByTag[normalizeTag(tagName)] ?? [:]
        }

        public func allowedProtocols(for tagName: String, attributeName: String) -> Set<String>? {
            let normalizedTag = normalizeTag(tagName)
            let normalizedAttribute = normalizeAttribute(attributeName)
            return allowedProtocolsByAttribute[AttributeKey(tagName: normalizedTag, attributeName: normalizedAttribute)]
        }

        public var preserveRelativeLinks: Bool {
            preserveRelativeLinksEnabled
        }

        public var urlWhitespaceMode: URLWhitespaceMode {
            urlWhitespacePolicy
        }

        private func normalizeTag(_ value: String) -> String {
            value == ":all" ? ":all" : ParsingSupport.lowercase(value)
        }

        private func normalizeAttribute(_ value: String) -> String {
            ParsingSupport.lowercase(value)
        }
    }
