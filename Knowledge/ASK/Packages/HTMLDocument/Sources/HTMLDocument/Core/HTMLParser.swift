    public enum HTMLParser {

        public static func parse<Sink: HTMLTreeSink, Bytes: Collection>(
            utf8 bytes: Bytes,
            options: HTMLParseOptions = .standard,
            into sink: Sink
        ) throws -> Sink.Output where Bytes.Element == UInt8 {
            try parse(String(decoding: bytes, as: UTF8.self), options: options, into: sink)
        }

        public static func parse<Sink: HTMLTreeSink>(
            _ input: some StringProtocol,
            options: HTMLParseOptions = .standard,
            into sink: Sink
        ) throws -> Sink.Output {
            var tokenizer = HTMLTokenizer(input)
            var sink = sink
            var openElements: [String] = []

            try sink.beginDocument()

            while let token = tokenizer.nextToken() {
                switch token {
                case .doctype(let name):
                    try sink.insertDoctype(name)

                case .comment(let text):
                    try sink.insertComment(text)

                case .text(let text):
                    guard !text.isEmpty else { continue }
                    let finalText = options.decodeEntities ? HTMLEntities.decode(text) : text
                    if !finalText.isEmpty {
                        try sink.insertText(finalText)
                    }

                case .startTag(let rawTag):
                    let tag = normalize(rawTag, options: options)
                    let name = tag.name

                    try insertImplicitContainersIfNeeded(for: name, openElements: &openElements, sink: &sink)
                    try autoCloseIfNeeded(for: name, openElements: &openElements, sink: &sink)

                    let isVoid = HTMLTagRules.isVoid(name)
                    let finalTag = HTMLStartTag(
                        name: name,
                        attributes: tag.attributes,
                        isSelfClosing: tag.isSelfClosing || isVoid
                    )

                    try sink.insertStartTag(finalTag)

                    if HTMLTagRules.isRawText(name), !finalTag.isSelfClosing {
                        let data = tokenizer.consumeRawText(untilClosingTagNamed: name)
                        if !data.isEmpty {
                            try sink.insertData(data)
                        }
                        try sink.insertEndTag(named: name)
                        continue
                    }

                    if HTMLTagRules.isRCData(name), !finalTag.isSelfClosing {
                        let text = tokenizer.consumeRawText(untilClosingTagNamed: name)
                        let decoded = options.decodeEntities ? HTMLEntities.decode(text) : text
                        if !decoded.isEmpty {
                            try sink.insertText(decoded)
                        }
                        try sink.insertEndTag(named: name)
                        continue
                    }

                    if !finalTag.isSelfClosing {
                        openElements.append(name)
                    }

                case .endTag(let rawName):
                    let name = options.normalizeTagNames ? ParsingSupport.lowercase(rawName) : rawName
                    try closeElements(named: name, openElements: &openElements, sink: &sink)
                }
            }

            while let last = openElements.popLast() {
                try sink.insertEndTag(named: last)
            }

            return try sink.finishDocument()
        }

        private static func normalize(_ tag: HTMLStartTag, options: HTMLParseOptions) -> HTMLStartTag {
            let name = options.normalizeTagNames ? ParsingSupport.lowercase(tag.name) : tag.name
            let attributes = canonicalizeAttributes(
                tag.attributes,
                normalizeNames: options.normalizeAttributeNames,
                decodeEntities: options.decodeEntities
            )

            return HTMLStartTag(
                name: name,
                attributes: attributes,
                isSelfClosing: tag.isSelfClosing
            )
        }

        private static func canonicalizeAttributes(
            _ attributes: [HTMLAttribute],
            normalizeNames: Bool,
            decodeEntities: Bool
        ) -> [HTMLAttribute] {
            var ordered: [HTMLAttribute] = []
            var indexByName: [String: Int] = [:]

            for attribute in attributes {
                let name = normalizeNames ? ParsingSupport.lowercase(attribute.name) : attribute.name
                let value = attribute.value.map { decodeEntities ? HTMLEntities.decode($0) : $0 }
                let normalized = HTMLAttribute(name: name, value: value)

                if let index = indexByName[name] {
                    ordered[index] = normalized
                } else {
                    indexByName[name] = ordered.count
                    ordered.append(normalized)
                }
            }

            return ordered
        }

        private static func insertImplicitContainersIfNeeded<Sink: HTMLTreeSink>(
            for newElement: String,
            openElements: inout [String],
            sink: inout Sink
        ) throws {
            switch newElement {
            case "tr":
                if openElements.last == "table" {
                    try sink.insertStartTag(.init(name: "tbody"))
                    openElements.append("tbody")
                }
            case "td", "th":
                if openElements.last == "table" {
                    try sink.insertStartTag(.init(name: "tbody"))
                    openElements.append("tbody")
                    try sink.insertStartTag(.init(name: "tr"))
                    openElements.append("tr")
                } else if openElements.last == "tbody" || openElements.last == "thead" || openElements.last == "tfoot" {
                    try sink.insertStartTag(.init(name: "tr"))
                    openElements.append("tr")
                }
            default:
                break
            }
        }

        private static func autoCloseIfNeeded<Sink: HTMLTreeSink>(
            for newElement: String,
            openElements: inout [String],
            sink: inout Sink
        ) throws {
            while let last = openElements.last, HTMLTagRules.shouldAutoClose(openElement: last, whenStarting: newElement) {
                openElements.removeLast()
                try sink.insertEndTag(named: last)
            }
        }

        private static func closeElements<Sink: HTMLTreeSink>(
            named name: String,
            openElements: inout [String],
            sink: inout Sink
        ) throws {
            guard openElements.contains(name) else {
                return
            }

            while let last = openElements.popLast() {
                try sink.insertEndTag(named: last)
                if last == name {
                    break
                }
            }
        }
    }
