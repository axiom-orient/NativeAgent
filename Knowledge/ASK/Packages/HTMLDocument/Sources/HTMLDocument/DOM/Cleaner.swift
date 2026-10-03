import Foundation

public struct HTMLCleaner: Sendable {
    public let headSafelist: Safelist?
    public let bodySafelist: Safelist

    public init(headSafelist: Safelist?, bodySafelist: Safelist) {
        self.headSafelist = headSafelist
        self.bodySafelist = bodySafelist
    }

    public init(_ safelist: Safelist) {
        self.init(headSafelist: nil, bodySafelist: safelist)
    }

    public func clean(_ dirtyDocument: Document, baseURI: String? = nil) -> Document {
        let (cleanChildren, _) = cleanTopLevelChildren(dirtyDocument.children, baseURI: baseURI)
        return Document(children: cleanChildren, serializationOptions: dirtyDocument.serializationOptions)
    }

    public func isValid(_ dirtyDocument: Document, baseURI: String? = nil) -> Bool {
        let (_, report) = cleanTopLevelChildren(dirtyDocument.children, baseURI: baseURI)
        return report.isClean
    }

    private func cleanTopLevelChildren(_ nodes: [Node], baseURI: String?) -> ([Node], CleanReport) {
        var result: [Node] = []
        var report = CleanReport()

        for node in nodes {
            switch node {
            case .element(let element) where element.name == "html":
                let (cleanedHTML, htmlReport) = cleanHTMLContainer(element, baseURI: baseURI)
                result.append(.element(cleanedHTML))
                report.merge(htmlReport)
            default:
                let (cleaned, nodeReport) = cleanNode(node, using: bodySafelist, baseURI: baseURI)
                result.append(contentsOf: cleaned)
                report.merge(nodeReport)
            }
        }

        return (result, report)
    }

    private func cleanHTMLContainer(_ element: Element, baseURI: String?) -> (Element, CleanReport) {
        var cleanedChildren: [Node] = []
        var report = CleanReport()

        for child in element.children {
            guard case .element(let childElement) = child else {
                report.discardedNodes += 1
                continue
            }

            if childElement.name == "head" {
                if let headSafelist {
                    let (cleanedNodes, childReport) = cleanNodes(childElement.children, using: headSafelist, baseURI: baseURI)
                    cleanedChildren.append(.element(Element(name: "head", attributes: [], children: cleanedNodes)))
                    report.merge(childReport)
                } else {
                    report.discardedNodes += 1
                }
            } else if childElement.name == "body" {
                let (cleanedNodes, childReport) = cleanNodes(childElement.children, using: bodySafelist, baseURI: baseURI)
                cleanedChildren.append(.element(Element(name: "body", attributes: [], children: cleanedNodes)))
                report.merge(childReport)
            } else {
                let (cleanedNodes, childReport) = cleanNodes([.element(childElement)], using: bodySafelist, baseURI: baseURI)
                cleanedChildren.append(contentsOf: cleanedNodes)
                report.merge(childReport)
            }
        }

        return (Element(name: "html", attributes: [], children: cleanedChildren), report)
    }

    private func cleanNodes(_ nodes: [Node], using safelist: Safelist, baseURI: String?) -> ([Node], CleanReport) {
        var cleaned: [Node] = []
        var report = CleanReport()

        for node in nodes {
            let (result, nodeReport) = cleanNode(node, using: safelist, baseURI: baseURI)
            cleaned.append(contentsOf: result)
            report.merge(nodeReport)
        }

        return (cleaned, report)
    }

    private func cleanNode(_ node: Node, using safelist: Safelist, baseURI: String?) -> ([Node], CleanReport) {
        switch node {
        case .text(let textNode):
            let text = safelist.allowedTags.isEmpty ? textNode.text.replacingOccurrences(of: "\u{00A0}", with: " ") : textNode.text
            return ([.text(TextNode(text))], .clean)

        case .element(let element):
            return cleanElement(element, using: safelist, baseURI: baseURI)

        case .data, .comment, .doctype:
            return ([], .discarded())
        }
    }

    private func cleanElement(_ element: Element, using safelist: Safelist, baseURI: String?) -> ([Node], CleanReport) {
        let (cleanedChildren, childReport) = cleanNodes(element.children, using: safelist, baseURI: baseURI)

        guard safelist.allowsTag(element.name) else {
            var report = childReport
            report.discardedNodes += 1
            return (cleanedChildren, report)
        }

        let sanitizedAttributes = sanitizeAttributes(element, using: safelist, baseURI: baseURI)
        var report = childReport
        report.discardedAttributes += sanitizedAttributes.discardedCount
        report.changedAttributes += sanitizedAttributes.changedCount

        let cleanedElement = Element(
            name: element.name,
            attributes: sanitizedAttributes.attributes,
            children: cleanedChildren,
            isSelfClosing: element.isSelfClosing
        )

        return ([.element(cleanedElement)], report)
    }

    private func sanitizeAttributes(
        _ element: Element,
        using safelist: Safelist,
        baseURI: String?
    ) -> SanitizedAttributes {
        var attributes: [HTMLAttribute] = []
        var discardedCount = 0
        var changedCount = 0

        for attribute in element.attributes {
            let normalizedName = attribute.name.lowercased()
            guard safelist.allowsAttribute(tagName: element.name, attributeName: normalizedName) else {
                discardedCount += 1
                continue
            }

            guard let value = attribute.value else {
                attributes.append(HTMLAttribute(name: normalizedName, value: nil))
                continue
            }

            if let protocols = safelist.allowedProtocols(for: element.name, attributeName: normalizedName) {
                guard let sanitizedValue = sanitizeURLAttribute(
                    value,
                    tagName: element.name,
                    attributeName: normalizedName,
                    allowedProtocols: protocols,
                    safelist: safelist,
                    baseURI: baseURI
                ) else {
                    discardedCount += 1
                    continue
                }

                if sanitizedValue != value {
                    changedCount += 1
                }

                attributes.append(HTMLAttribute(name: normalizedName, value: sanitizedValue))
            } else {
                attributes.append(HTMLAttribute(name: normalizedName, value: value))
            }
        }

        let enforced = safelist.enforcedAttributes(for: element.name)
        for (key, value) in enforced.sorted(by: { $0.key < $1.key }) {
            if let index = attributes.firstIndex(where: { $0.name == key }) {
                if attributes[index].value != value {
                    changedCount += 1
                }
                attributes[index] = HTMLAttribute(name: key, value: value)
            } else {
                attributes.append(HTMLAttribute(name: key, value: value))
            }
        }

        return SanitizedAttributes(attributes: attributes, discardedCount: discardedCount, changedCount: changedCount)
    }

    private func sanitizeURLAttribute(
        _ originalValue: String,
        tagName: String,
        attributeName: String,
        allowedProtocols: Set<String>,
        safelist: Safelist,
        baseURI: String?
    ) -> String? {
        let adjusted: String
        switch safelist.urlWhitespaceMode {
        case .trim:
            adjusted = originalValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .strict:
            let trimmed = originalValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == originalValue, !originalValue.contains(where: { $0.isWhitespace }) else {
                return nil
            }
            adjusted = originalValue
        }

        guard !adjusted.isEmpty else {
            return nil
        }

        // Browsers remove C0 control characters — notably TAB, LF and CR — before
        // they resolve a URL's scheme. A value this cleaner would otherwise read as
        // a relative path can therefore still resolve to `javascript:` in a browser.
        // Reject those characters outright instead of trying to reproduce that
        // normalization here.
        guard !adjusted.unicodeScalars.contains(where: isForbiddenURLScalar) else {
            return nil
        }

        if let fragment = normalizedFragmentLink(adjusted) {
            return allowedProtocols.contains("#") ? fragment : nil
        }

        if let explicitProtocol = extractScheme(adjusted) {
            return allowedProtocols.contains(explicitProtocol.lowercased()) ? adjusted : nil
        }

        // A scheme delimiter precedes the first path/query/fragment separator, but the
        // scheme itself is malformed. Treating it as a relative URL is what lets an
        // unknown scheme survive, so refuse it.
        if hasSchemeDelimiter(adjusted) {
            return nil
        }

        if adjusted.hasPrefix("/") {
            if safelist.preserveRelativeLinks {
                return adjusted
            }
            if let baseURI {
                let resolved = resolveSlashPrefixedURL(adjusted, against: baseURI)
                // A syntactically valid base can still use a scheme that this
                // attribute does not allow. Re-check the final URL after
                // resolution instead of letting the base bypass the safelist.
                if resolved != adjusted {
                    guard let resolvedScheme = extractScheme(resolved),
                          allowedProtocols.contains(resolvedScheme.lowercased()) else {
                        return nil
                    }
                }
                return resolved
            }
            return nil
        }

        return adjusted
    }

    private func isForbiddenURLScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// Position of the scheme delimiter, or `nil` when the value carries no scheme.
    ///
    /// A colon only introduces a scheme while it precedes the first `/`, `?` or `#`;
    /// after any of those it belongs to the path, query or fragment.
    private func schemeDelimiterIndex(_ value: String) -> String.Index? {
        for index in value.indices {
            switch value[index] {
            case ":": return index
            case "/", "?", "#": return nil
            default: continue
            }
        }
        return nil
    }

    private func hasSchemeDelimiter(_ value: String) -> Bool {
        schemeDelimiterIndex(value) != nil
    }

    private func extractScheme(_ value: String) -> String? {
        guard let delimiter = schemeDelimiterIndex(value), delimiter != value.startIndex else {
            return nil
        }
        let scheme = value[value.startIndex ..< delimiter]
        // RFC 3986: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ), ASCII only.
        guard let first = scheme.first, first.isASCII, first.isLetter else {
            return nil
        }
        guard scheme.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
        }) else {
            return nil
        }
        return String(scheme)
    }

    private func normalizedFragmentLink(_ value: String) -> String? {
        guard value.hasPrefix("#") else {
            return nil
        }
        return value.contains(where: { $0.isWhitespace }) ? nil : value
    }

    private func resolveSlashPrefixedURL(_ relative: String, against baseURI: String) -> String {
        let trimmedBase = baseURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = extractScheme(trimmedBase),
              let schemeRange = trimmedBase.range(of: "\(scheme)://") else {
            return relative
        }

        let afterScheme = trimmedBase[schemeRange.upperBound...]
        let host = afterScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? String(afterScheme)
        return "\(scheme)://\(host)\(relative)"
    }
}

private struct SanitizedAttributes: Sendable {
    let attributes: [HTMLAttribute]
    let discardedCount: Int
    let changedCount: Int
}

private struct CleanReport: Sendable {
    var discardedNodes: Int = 0
    var discardedAttributes: Int = 0
    var changedAttributes: Int = 0

    static let clean = CleanReport()

    static func discarded() -> CleanReport {
        CleanReport(discardedNodes: 1, discardedAttributes: 0, changedAttributes: 0)
    }

    var isClean: Bool {
        discardedNodes == 0 && discardedAttributes == 0 && changedAttributes == 0
    }

    mutating func merge(_ other: CleanReport) {
        discardedNodes += other.discardedNodes
        discardedAttributes += other.discardedAttributes
        changedAttributes += other.changedAttributes
    }
}
