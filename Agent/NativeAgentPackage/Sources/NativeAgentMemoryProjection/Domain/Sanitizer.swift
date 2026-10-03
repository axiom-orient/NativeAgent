import Foundation

func regexReplace(_ text: String, _ pattern: String, _ replacement: String = "") -> String {
    guard
        let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators, .anchorsMatchLines])
    else {
        return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(
        in: text, options: [], range: range, withTemplate: replacement)
}

func sanitizeText(_ text: String) -> String {
    var result = text
    let patterns = [
        "<relevant-memories>[\\s\\S]*?</relevant-memories>",
        "<user-persona>[\\s\\S]*?</user-persona>",
        "<relevant-scenes>[\\s\\S]*?</relevant-scenes>",
        "<scene-navigation>[\\s\\S]*?</scene-navigation>",
        "<current_task_context>[\\s\\S]*?</current_task_context>",
        "<history_task_context>[\\s\\S]*?</history_task_context>",
        "(?:Conversation info|Sender|Thread starter|Replied message|Forwarded message context|Chat history since last reply)\\s*\\(untrusted[\\s\\S]*?\\):\\s*```json\\s*[\\s\\S]*?```",
        "```json\\s*\\{[\\s\\S]*?\\\"session[\\s\\S]*?\\}\\s*```",
        "\\[\\[reply_to[^\\]]*\\]\\]\\s*",
        "¥¥\\[[\\s\\S]*?\\]¥¥",
        "^\\[[\\w\\d\\-:+ ]+\\]\\s*",
        "\\[media attached:[^\\]]*\\]\\s*",
        "To send an image back,[\\s\\S]*?(?:Keep caption in the text body\\.)\\s*",
        "^System:\\s*\\[[^\\n]*Exec completed[\\s\\S]*$",
        "data:image/[a-z+]+;base64,[A-Za-z0-9+/=]+",
    ]
    for pattern in patterns { result = regexReplace(result, pattern) }
    result = result.replacingOccurrences(of: "\0", with: "")
    result = regexReplace(result, "\\n{3,}", "\n\n")
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

func shouldCaptureEvent(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return false }
    if isFrameworkNoise(trimmed) { return false }
    if trimmed.hasPrefix("/") { return false }
    return true
}

private func isFrameworkNoise(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "(session bootstrap)" { return true }
    if trimmed.hasPrefix("A new session was started via") { return true }
    if trimmed.hasPrefix("✅ New session started") { return true }
    if trimmed.hasPrefix("Pre-compaction memory flush") { return true }
    if trimmed == "NO_REPLY" { return true }
    return false
}
