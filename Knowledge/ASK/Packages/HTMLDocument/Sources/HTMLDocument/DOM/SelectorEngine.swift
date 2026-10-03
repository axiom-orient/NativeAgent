
enum SelectorEngine {
    private struct TraversalFrame: Sendable {
        let element: Element
        let path: [Int]
        let precedingSiblings: [Element]
        let followingSiblings: [Element]
    }

    private struct ElementContext: Sendable {
        let element: Element
        let path: [Int]
        let ancestry: [TraversalFrame]
        let precedingSiblings: [Element]
        let followingSiblings: [Element]
    }

    static func select(_ selectorGroup: CSSSelectorGroup, in document: Document) -> [Element] {
        let roots = document.children.compactMap(\ .element)
        let rootContexts = roots.enumerated().map { index, root in
            ElementContext(
                element: root,
                path: [index],
                ancestry: [],
                precedingSiblings: Array(roots.prefix(index)),
                followingSiblings: Array(roots.dropFirst(index + 1))
            )
        }
        return collectMatches(selectorGroup, startingFrom: rootContexts)
    }

    static func select(_ selectorGroup: CSSSelectorGroup, in element: Element) -> [Element] {
        let rootContext = ElementContext(
            element: element,
            path: [],
            ancestry: [],
            precedingSiblings: [],
            followingSiblings: []
        )
        return collectMatches(selectorGroup, startingFrom: [rootContext])
    }

    private static func collectMatches(
        _ selectorGroup: CSSSelectorGroup,
        startingFrom contexts: [ElementContext]
    ) -> [Element] {
        var results: [Element] = []
        var seenPaths: Set<[Int]> = []

        for context in contexts {
            traverse(
                context: context,
                selectorGroup: selectorGroup,
                results: &results,
                seenPaths: &seenPaths
            )
        }

        return results
    }

    private static func traverse(
        context: ElementContext,
        selectorGroup: CSSSelectorGroup,
        results: inout [Element],
        seenPaths: inout Set<[Int]>
    ) {
        if selectorGroup.selectors.contains(where: { matches($0, context: context, relativeAnchor: nil) }) {
            if seenPaths.insert(context.path).inserted {
                results.append(context.element)
            }
        }

        for childContext in childContexts(of: context) {
            traverse(
                context: childContext,
                selectorGroup: selectorGroup,
                results: &results,
                seenPaths: &seenPaths
            )
        }
    }

    private static func childContexts(of context: ElementContext) -> [ElementContext] {
        let children = context.element.childElements
        let nextAncestry = context.ancestry + [
            TraversalFrame(
                element: context.element,
                path: context.path,
                precedingSiblings: context.precedingSiblings,
                followingSiblings: context.followingSiblings
            )
        ]

        return children.enumerated().map { index, child in
            ElementContext(
                element: child,
                path: context.path + [index],
                ancestry: nextAncestry,
                precedingSiblings: Array(children.prefix(index)),
                followingSiblings: Array(children.dropFirst(index + 1))
            )
        }
    }

    private static func followingSiblingContexts(of context: ElementContext) -> [ElementContext] {
        guard let currentIndex = context.path.last else {
            return []
        }

        let parentPath = Array(context.path.dropLast())
        return context.followingSiblings.enumerated().map { offset, sibling in
            let preceding = context.precedingSiblings + [context.element] + Array(context.followingSiblings.prefix(offset))
            return ElementContext(
                element: sibling,
                path: parentPath + [currentIndex + offset + 1],
                ancestry: context.ancestry,
                precedingSiblings: preceding,
                followingSiblings: Array(context.followingSiblings.dropFirst(offset + 1))
            )
        }
    }

    private static func matches(
        _ selector: CSSComplexSelector,
        context: ElementContext,
        relativeAnchor: ElementContext?
    ) -> Bool {
        guard let lastStep = selector.steps.last,
              compoundMatches(lastStep.compound, context: context) else {
            return false
        }

        return matches(
            selector,
            stepIndex: selector.steps.count - 1,
            context: context,
            relativeAnchor: relativeAnchor
        )
    }

    private static func matches(
        _ selector: CSSComplexSelector,
        stepIndex: Int,
        context: ElementContext,
        relativeAnchor: ElementContext?
    ) -> Bool {
        if stepIndex == 0 {
            guard let initialCombinator = selector.steps[0].combinator else {
                return true
            }
            guard let relativeAnchor else {
                return false
            }
            return matchesRelativeAnchor(initialCombinator, candidate: context, anchor: relativeAnchor)
        }

        let previousStep = selector.steps[stepIndex - 1]

        switch selector.steps[stepIndex].combinator {
        case .child:
            guard let frame = context.ancestry.last else {
                return false
            }
            let parent = parentContext(from: frame, ancestry: Array(context.ancestry.dropLast()))
            guard compoundMatches(previousStep.compound, context: parent) else {
                return false
            }
            return matches(selector, stepIndex: stepIndex - 1, context: parent, relativeAnchor: relativeAnchor)

        case .descendant:
            for ancestorIndex in stride(from: context.ancestry.count - 1, through: 0, by: -1) {
                let frame = context.ancestry[ancestorIndex]
                let ancestorContext = parentContext(
                    from: frame,
                    ancestry: Array(context.ancestry.prefix(ancestorIndex))
                )
                guard compoundMatches(previousStep.compound, context: ancestorContext) else {
                    continue
                }
                if matches(selector, stepIndex: stepIndex - 1, context: ancestorContext, relativeAnchor: relativeAnchor) {
                    return true
                }
            }
            return false

        case .adjacentSibling:
            guard let sibling = context.precedingSiblings.last else {
                return false
            }
            let siblingContext = siblingContext(
                sibling,
                path: previousSiblingPath(for: context.path),
                ancestry: context.ancestry,
                precedingSiblings: Array(context.precedingSiblings.dropLast()),
                followingSiblings: [context.element] + context.followingSiblings
            )
            guard compoundMatches(previousStep.compound, context: siblingContext) else {
                return false
            }
            return matches(selector, stepIndex: stepIndex - 1, context: siblingContext, relativeAnchor: relativeAnchor)

        case .generalSibling:
            for siblingIndex in stride(from: context.precedingSiblings.count - 1, through: 0, by: -1) {
                let sibling = context.precedingSiblings[siblingIndex]
                let siblingContext = siblingContext(
                    sibling,
                    path: siblingPath(for: context.path, siblingOffset: -(context.precedingSiblings.count - siblingIndex)),
                    ancestry: context.ancestry,
                    precedingSiblings: Array(context.precedingSiblings.prefix(siblingIndex)),
                    followingSiblings: Array(context.precedingSiblings.dropFirst(siblingIndex + 1)) + [context.element] + context.followingSiblings
                )
                guard compoundMatches(previousStep.compound, context: siblingContext) else {
                    continue
                }
                if matches(selector, stepIndex: stepIndex - 1, context: siblingContext, relativeAnchor: relativeAnchor) {
                    return true
                }
            }
            return false

        case nil:
            return false
        }
    }

    private static func parentContext(from frame: TraversalFrame, ancestry: [TraversalFrame]) -> ElementContext {
        ElementContext(
            element: frame.element,
            path: frame.path,
            ancestry: ancestry,
            precedingSiblings: frame.precedingSiblings,
            followingSiblings: frame.followingSiblings
        )
    }

    private static func siblingContext(
        _ sibling: Element,
        path: [Int],
        ancestry: [TraversalFrame],
        precedingSiblings: [Element],
        followingSiblings: [Element]
    ) -> ElementContext {
        ElementContext(
            element: sibling,
            path: path,
            ancestry: ancestry,
            precedingSiblings: precedingSiblings,
            followingSiblings: followingSiblings
        )
    }

    private static func compoundMatches(_ compound: CSSCompoundSelector, context: ElementContext) -> Bool {
        compound.components.allSatisfy { simpleSelectorMatches($0, context: context) }
    }

    private static func simpleSelectorMatches(_ selector: CSSSimpleSelector, context: ElementContext) -> Bool {
        switch selector {
        case .universal:
            return true
        case .tag(let tag):
            return context.element.name == tag
        case .id(let id):
            return context.element.id == id
        case .className(let className):
            return context.element.hasClass(className)
        case .attributeExists(let name):
            return context.element.hasAttribute(name)
        case .attributeEquals(let name, let value):
            return context.element.attribute(named: name) == value
        case .attributeStartsWith(let name, let value):
            return context.element.attribute(named: name)?.hasPrefix(value) == true
        case .attributeEndsWith(let name, let value):
            return context.element.attribute(named: name)?.hasSuffix(value) == true
        case .attributeContains(let name, let value):
            return context.element.attribute(named: name)?.contains(value) == true
        case .containsText(let value):
            return normalizedSearchText(context.element.normalizedText).contains(value)
        case .containsOwnText(let value):
            return normalizedOwnSearchText(of: context.element).contains(value)
        case .firstChild:
            return context.precedingSiblings.isEmpty
        case .lastChild:
            return context.followingSiblings.isEmpty
        case .firstOfType:
            return !context.precedingSiblings.contains(where: { $0.name == context.element.name })
        case .lastOfType:
            return !context.followingSiblings.contains(where: { $0.name == context.element.name })
        case .nthChild(let expression):
            return expression.matches(index: context.precedingSiblings.count + 1)
        case .nthOfType(let expression):
            let index = context.precedingSiblings.filter { $0.name == context.element.name }.count + 1
            return expression.matches(index: index)
        case .not(let selectorGroup):
            return !selectorGroup.selectors.contains(where: { matches($0, context: context, relativeAnchor: nil) })
        case .has(let selectorGroup):
            return relativeMatchExists(selectorGroup, from: context)
        }
    }

    private static func relativeMatchExists(_ selectorGroup: CSSSelectorGroup, from anchor: ElementContext) -> Bool {
        for selector in selectorGroup.selectors {
            for root in relativeSearchRoots(for: selector, from: anchor) {
                if subtreeContainsRelativeMatch(selector, from: root, anchor: anchor) {
                    return true
                }
            }
        }
        return false
    }

    private static func relativeSearchRoots(for selector: CSSComplexSelector, from anchor: ElementContext) -> [ElementContext] {
        switch selector.steps.first?.combinator {
        case .adjacentSibling, .generalSibling:
            return followingSiblingContexts(of: anchor)
        case .child, .descendant, nil:
            return childContexts(of: anchor)
        }
    }

    private static func subtreeContainsRelativeMatch(
        _ selector: CSSComplexSelector,
        from context: ElementContext,
        anchor: ElementContext
    ) -> Bool {
        if matches(selector, context: context, relativeAnchor: anchor) {
            return true
        }

        for childContext in childContexts(of: context) {
            if subtreeContainsRelativeMatch(selector, from: childContext, anchor: anchor) {
                return true
            }
        }

        return false
    }

    private static func matchesRelativeAnchor(
        _ combinator: CSSCombinator,
        candidate: ElementContext,
        anchor: ElementContext
    ) -> Bool {
        switch combinator {
        case .child:
            return candidate.ancestry.last?.path == anchor.path
        case .descendant:
            return isStrictPrefix(anchor.path, of: candidate.path)
        case .adjacentSibling:
            return isAdjacentSibling(candidate.path, of: anchor.path)
        case .generalSibling:
            return isFollowingSibling(candidate.path, of: anchor.path)
        }
    }

    private static func isStrictPrefix(_ prefix: [Int], of value: [Int]) -> Bool {
        value.count > prefix.count && value.starts(with: prefix)
    }

    private static func isAdjacentSibling(_ candidatePath: [Int], of anchorPath: [Int]) -> Bool {
        guard sameParent(candidatePath, anchorPath),
              let candidateIndex = candidatePath.last,
              let anchorIndex = anchorPath.last else {
            return false
        }
        return candidateIndex == anchorIndex + 1
    }

    private static func isFollowingSibling(_ candidatePath: [Int], of anchorPath: [Int]) -> Bool {
        guard sameParent(candidatePath, anchorPath),
              let candidateIndex = candidatePath.last,
              let anchorIndex = anchorPath.last else {
            return false
        }
        return candidateIndex > anchorIndex
    }

    private static func sameParent(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return false
        }
        return lhs.dropLast() == rhs.dropLast()
    }

    private static func previousSiblingPath(for path: [Int]) -> [Int] {
        siblingPath(for: path, siblingOffset: -1)
    }

    private static func siblingPath(for path: [Int], siblingOffset: Int) -> [Int] {
        guard let last = path.last else {
            return []
        }
        return Array(path.dropLast()) + [last + siblingOffset]
    }

    private static func normalizedSearchText(_ value: String) -> String {
        var result = String()
        var lastWasWhitespace = false

        for character in value.lowercased() {
            if character.isWhitespace {
                if !lastWasWhitespace {
                    result.append(" ")
                    lastWasWhitespace = true
                }
            } else {
                result.append(character)
                lastWasWhitespace = false
            }
        }

        var start = result.startIndex
        var end = result.endIndex

        while start < end, result[start].isWhitespace {
            start = result.index(after: start)
        }

        while start < end {
            let previous = result.index(before: end)
            if result[previous].isWhitespace {
                end = previous
            } else {
                break
            }
        }

        return String(result[start..<end])
    }

    private static func normalizedOwnSearchText(of element: Element) -> String {
        let ownText = element.children.compactMap { node -> String? in
            guard case .text(let textNode) = node else {
                return nil
            }
            return textNode.text
        }.joined(separator: " ")

        return normalizedSearchText(ownText)
    }
}
