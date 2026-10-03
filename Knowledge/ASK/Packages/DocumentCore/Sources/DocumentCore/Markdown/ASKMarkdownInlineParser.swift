import Foundation

struct ASKMarkdownInlineParser {
    let text: String
    let baseOffset: Int
    let sourceID: ASKPageSourceID

    func parse() -> [ASKPageInlineRun] {
        let characters = Array(text)
        var runs: [ASKPageInlineRun] = []
        var plainBuffer = ""
        var plainStartOffset = 0
        var index = 0

        func flushPlain(upTo currentIndex: Int) {
            guard !plainBuffer.isEmpty else {
                plainStartOffset = currentIndex
                return
            }
            runs.append(
                .init(
                    text: plainBuffer,
                    sourceAnchor: .init(
                        sourceID: sourceID,
                        range: .init(
                            start: baseOffset + plainStartOffset,
                            end: baseOffset + currentIndex
                        )
                    )
                )
            )
            plainBuffer.removeAll(keepingCapacity: true)
            plainStartOffset = currentIndex
        }

        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                flushPlain(upTo: index)
                let escapedOffset = index + 1
                runs.append(
                    .init(
                        text: String(characters[escapedOffset]),
                        sourceAnchor: .init(
                            sourceID: sourceID,
                            range: .init(
                                start: baseOffset + escapedOffset,
                                end: baseOffset + escapedOffset + 1
                            )
                        )
                    )
                )
                index += 2
                plainStartOffset = index
                continue
            }

            if let bold = parseDelimited(characters: characters, index: index, delimiter: "**") {
                flushPlain(upTo: index)
                runs.append(makeStyledRun(content: bold.content, emphasis: [.bold], delimiterLength: 2, at: index))
                index = bold.nextIndex
                plainStartOffset = index
                continue
            }

            if let italic = parseDelimited(characters: characters, index: index, delimiter: "*") {
                flushPlain(upTo: index)
                runs.append(makeStyledRun(content: italic.content, emphasis: [.italic], delimiterLength: 1, at: index))
                index = italic.nextIndex
                plainStartOffset = index
                continue
            }

            if let code = parseDelimited(characters: characters, index: index, delimiter: "`") {
                flushPlain(upTo: index)
                runs.append(makeStyledRun(content: code.content, emphasis: [.code], delimiterLength: 1, at: index))
                index = code.nextIndex
                plainStartOffset = index
                continue
            }

            if let link = parseLink(characters: characters, index: index) {
                flushPlain(upTo: index)
                runs.append(link.run)
                index = link.nextIndex
                plainStartOffset = index
                continue
            }

            plainBuffer.append(characters[index])
            index += 1
        }

        flushPlain(upTo: characters.count)
        return runs
    }

    private func parseDelimited(
        characters: [Character],
        index: Int,
        delimiter: String
    ) -> (content: String, nextIndex: Int)? {
        let delimiterCharacters = Array(delimiter)
        guard matches(characters: characters, index: index, token: delimiterCharacters) else {
            return nil
        }
        let contentStart = index + delimiterCharacters.count
        guard let closeIndex = findToken(
            characters: characters,
            token: delimiterCharacters,
            from: contentStart
        ) else {
            return nil
        }
        let content = String(characters[contentStart..<closeIndex])
        return (content: content, nextIndex: closeIndex + delimiterCharacters.count)
    }

    private func makeStyledRun(
        content: String,
        emphasis: ASKPageInlineEmphasis,
        delimiterLength: Int,
        at startIndex: Int
    ) -> ASKPageInlineRun {
        let contentStart = startIndex + delimiterLength
        return .init(
            text: content,
            emphasis: emphasis,
            sourceAnchor: .init(
                sourceID: sourceID,
                range: .init(
                    start: baseOffset + contentStart,
                    end: baseOffset + contentStart + content.count
                )
            )
        )
    }

    private func parseLink(characters: [Character], index: Int) -> (run: ASKPageInlineRun, nextIndex: Int)? {
        guard characters[index] == "[",
              let labelClose = findCharacter(characters: characters, character: "]", from: index + 1),
              labelClose + 1 < characters.count,
              characters[labelClose + 1] == "(",
              let destinationClose = findCharacter(characters: characters, character: ")", from: labelClose + 2)
        else {
            return nil
        }

        let labelStart = index + 1
        let destinationStart = labelClose + 2
        let label = String(characters[labelStart..<labelClose])
        let destination = String(characters[destinationStart..<destinationClose])
        let url = URL(string: destination)
        let semanticRole: ASKPageInlineSemanticRole?
        let emphasis: ASKPageInlineEmphasis

        if destination.hasPrefix("ask-cite://") {
            semanticRole = .citation(identifier: String(destination.dropFirst("ask-cite://".count)))
            emphasis = [.citation]
        } else if destination.hasPrefix("ask-entity://") {
            semanticRole = .entity(identifier: String(destination.dropFirst("ask-entity://".count)))
            emphasis = []
        } else {
            semanticRole = url == nil ? nil : .link
            emphasis = []
        }

        let run = ASKPageInlineRun(
            text: label,
            emphasis: emphasis,
            destination: url,
            semanticRole: semanticRole,
            sourceAnchor: .init(
                sourceID: sourceID,
                range: .init(
                    start: baseOffset + labelStart,
                    end: baseOffset + labelClose
                )
            )
        )
        return (run: run, nextIndex: destinationClose + 1)
    }

    private func matches(characters: [Character], index: Int, token: [Character]) -> Bool {
        guard index + token.count <= characters.count else {
            return false
        }
        return Array(characters[index..<(index + token.count)]) == token
    }

    private func findToken(characters: [Character], token: [Character], from start: Int) -> Int? {
        guard !token.isEmpty, start < characters.count else {
            return nil
        }
        var index = start
        while index + token.count <= characters.count {
            if matches(characters: characters, index: index, token: token) {
                return index
            }
            index += 1
        }
        return nil
    }

    private func findCharacter(characters: [Character], character: Character, from start: Int) -> Int? {
        guard start < characters.count else {
            return nil
        }
        var index = start
        while index < characters.count {
            if characters[index] == character {
                return index
            }
            index += 1
        }
        return nil
    }
}
