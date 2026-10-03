import Foundation
import LanguageModelCore

/// Swift/iOS port of Prose Polish Suite's read-only lexical/layout guard.
/// No Python, subprocess, network, model or filesystem access. This is a bounded Markdown
/// subset, never a semantic-equivalence, fluency or character-fidelity validator.
public enum AgentProseGuard {
  public enum Status: String, Codable, Sendable {
    case mechanicalPassSemanticsUnverified = "MECHANICAL_PASS_SEMANTICS_UNVERIFIED"
    case mechanicalFail = "MECHANICAL_FAIL"
    case unsupported = "UNSUPPORTED"
    case inputError = "INPUT_ERROR"
  }

  public struct Issue: Codable, Equatable, Sendable {
    public let check: String
    public let block: Int?
  }

  public struct Report: Encodable, Equatable, Sendable {
    public let status: Status
    public let issues: [Issue]
    public let reason: String?
    public let sourceSHA256: String
    public let candidateSHA256: String
    public let semanticVerification = "NOT_PERFORMED"
  }

  public static let maximumInputBytes = 256 * 1_024

  public static func compare(source: String, candidate: String, anchors: [String] = []) -> Report {
    var issues: [Issue] = []
    func result(_ status: Status, _ reason: String? = nil) -> Report {
      Report(status: status, issues: issues, reason: reason,
        sourceSHA256: SHA256HexDigest.digest(source), candidateSHA256: SHA256HexDigest.digest(candidate))
    }
    guard source.utf8.count <= maximumInputBytes, candidate.utf8.count <= maximumInputBytes,
      anchors.count <= 64, anchors.reduce(0, { $0 + $1.utf8.count }) <= 32 * 1_024
    else { return result(.inputError, "Input exceeds the native guard's bounded size.") }
    do {
      if try eolProfile(source) != eolProfile(candidate) {
        issues.append(Issue(check: "encoding_layout", block: nil))
      }
      let original = try blocks(source), edited = try blocks(candidate)
      if original.count != edited.count { issues.append(Issue(check: "block_inventory", block: nil)) }
      for (offset, pair) in zip(original, edited).enumerated() {
        let (a, b) = pair
        if a.kind != b.kind || !exact(a.marker, b.marker) {
          issues.append(Issue(check: "block_kind_or_marker", block: offset + 1))
          continue
        }
        if a.opaque || a.kind == "gap" {
          if !exact(a.text, b.text) { issues.append(Issue(check: "opaque_or_gap_changed", block: offset + 1)) }
        } else {
          let left = try protected(a.text), right = try protected(b.text)
          for key in left.keys.sorted() where !exact(left[key] ?? [], right[key] ?? []) {
            issues.append(Issue(check: key, block: offset + 1))
          }
        }
      }
      for anchor in anchors {
        guard !anchor.isEmpty, occurrences(anchor, in: source) > 0 else {
          return result(.inputError, "An explicit anchor is empty or absent from the source.")
        }
        if occurrences(anchor, in: source) != occurrences(anchor, in: candidate) {
          issues.append(Issue(check: "explicit_anchor_count", block: nil))
        }
      }
      return result(issues.isEmpty ? .mechanicalPassSemanticsUnverified : .mechanicalFail)
    } catch let error as Unsupported {
      return result(.unsupported, error.reason)
    } catch {
      return result(.inputError, "Guard parsing failed: \(error.localizedDescription)")
    }
  }

  public static func compare(source: Data, candidate: Data, anchors: [String] = []) -> Report {
    guard source.count <= maximumInputBytes, candidate.count <= maximumInputBytes,
      String(data: source, encoding: .utf8) != nil,
      String(data: candidate, encoding: .utf8) != nil
    else {
      return Report(status: .inputError, issues: [], reason: "Expected bounded UTF-8 input.",
        sourceSHA256: SHA256HexDigest.digest(source), candidateSHA256: SHA256HexDigest.digest(candidate))
    }
    // Foundation's encoding initializer strips a BOM; validate with it, then decode the exact
    // valid bytes using Swift's UTF-8 decoder so the preservation comparison still sees the BOM.
    return compare(source: String(decoding: source, as: UTF8.self),
      candidate: String(decoding: candidate, as: UTF8.self), anchors: anchors)
  }

  private struct Unsupported: Error { let reason: String }
  private struct Block {
    let kind: String
    let text: String
    var marker = ""
    var opaque: Bool { ["code", "frontmatter", "opaque", "heading", "rule"].contains(kind) }
  }

  private static let fence = #"^ {0,3}(`{3,}|~{3,})([^\r\n]*)$"#
  private static let heading = #"^ {0,3}#{1,6}(?:\s|$)"#
  private static let list = #"^( {0,3}(?:[-+*]|\d+[.)])\s+)(.*)$"#
  private static let rule = #"^ {0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$"#
  private static let number = #"(?<![A-Za-z0-9_])(?:[+−-]|[$€£¥₩])?\d+(?:[.,:/\-]\d+)*(?:[%％‰°]|\s?(?:milliseconds?|seconds?|minutes?|hours?|bytes?|km/h|m/s²|m/s|[kMGTP]?B|[kMG]?Hz|ms|μs|µs|ns|kg|mg|km|cm|mm|mL|ml|kW|MW|°C|°F|s|h|m|L|l|A|V|W|초|분|시간|일|개월|년|명|개|원|秒|分钟|分|小时|日|年|人|円|元|个))?(?![A-Za-z0-9_])"#

  private static func matches(_ pattern: String, _ text: String) throws -> [NSTextCheckingResult] {
    try NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
  }
  private static func has(_ pattern: String, _ text: String) throws -> Bool { try matches(pattern, text).isEmpty == false }
  private static func captures(_ pattern: String, _ text: String) throws -> [String] {
    try matches(pattern, text).map { (text as NSString).substring(with: $0.range) }
  }
  private static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
  private static func exact(_ a: [String], _ b: [String]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { exact($0, $1) }
  }
  private static func occurrences(_ value: String, in text: String) -> Int {
    let ns = text as NSString
    var offset = 0, count = 0
    while offset < ns.length {
      let found = ns.range(of: value, options: .literal, range: NSRange(location: offset, length: ns.length - offset))
      if found.location == NSNotFound { break }
      count += 1
      offset = NSMaxRange(found)
    }
    return count
  }

  private static func eolProfile(_ text: String) throws -> [String] {
    let kinds = Set(try captures(#"\r\n|\n|\r"#, text))
    if kinds.count > 1 { throw Unsupported(reason: "Mixed newline styles require byte-aware review.") }
    if kinds.contains("\r") { throw Unsupported(reason: "Bare CR is unsupported.") }
    return [kinds.first ?? "", text.hasSuffix("\n") ? "newline" : "", text.hasPrefix("\u{FEFF}") ? "bom" : ""]
  }

  private static func blocks(_ input: String) throws -> [Block] {
    _ = try eolProfile(input)
    let text = input.hasPrefix("\u{FEFF}") ? String(input.dropFirst()) : input
    // Unlike String equality, all protected comparisons use exact UTF-8 bytes.
    var lines = text.components(separatedBy: "\n")
    for i in 0..<max(0, lines.count - 1) { lines[i] += "\n" }
    if lines.last == "" { lines.removeLast() }
    func bare(_ i: Int) -> String { lines[i].trimmingCharacters(in: .newlines) }
    func blank(_ i: Int) -> Bool { bare(i).trimmingCharacters(in: .whitespaces).isEmpty }
    var output: [Block] = [], i = 0
    while i < lines.count {
      let line = bare(i)
      if blank(i) {
        var j = i + 1
        while j < lines.count && blank(j) { j += 1 }
        output.append(Block(kind: "gap", text: lines[i..<j].joined())); i = j; continue
      }
      if i == 0 && line == "---" {
        var j = i + 1
        while j < lines.count && !["---", "..."].contains(bare(j)) { j += 1 }
        guard j < lines.count else { throw Unsupported(reason: "Unclosed front matter.") }
        output.append(Block(kind: "frontmatter", text: lines[i...j].joined())); i = j + 1; continue
      }
      if let match = try matches(fence, line).first {
        let delimiter = (line as NSString).substring(with: match.range(at: 1))
        let info = (line as NSString).substring(with: match.range(at: 2))
        if delimiter.first == "`" && info.contains("`") { throw Unsupported(reason: "Backtick in fence info string.") }
        let closing = "^ {0,3}" + NSRegularExpression.escapedPattern(for: String(delimiter.prefix(1))) + "{\(delimiter.count),}\\s*$"
        var j = i + 1
        while j < lines.count {
          if try has(closing, bare(j)) { break }
          j += 1
        }
        guard j < lines.count else { throw Unsupported(reason: "Unclosed code fence.") }
        output.append(Block(kind: "code", text: lines[i...j].joined())); i = j + 1; continue
      }
      if try has(heading, line) {
        output.append(Block(kind: "heading", text: lines[i])); i += 1; continue
      }
      if i + 1 < lines.count, try has(#"^ {0,3}(?:=+|-+)\s*$"#, bare(i + 1)) {
        output.append(Block(kind: "heading", text: lines[i...i + 1].joined())); i += 2; continue
      }
      if try has(rule, line) { output.append(Block(kind: "rule", text: lines[i])); i += 1; continue }
      if try has(#"^ {0,3}>|^ {0,3}\[[^\]]+\]:|^ {4}|^\t"#, line) || line.contains("|") {
        var j = i + 1
        while j < lines.count && !blank(j) { j += 1 }
        output.append(Block(kind: "opaque", text: lines[i..<j].joined())); i = j; continue
      }
      if let match = try matches(list, line).first {
        output.append(Block(kind: "list", text: lines[i], marker: (line as NSString).substring(with: match.range(at: 1))))
        i += 1
        if i < lines.count && !blank(i),
          try has(list, bare(i)) == false && has(heading, bare(i)) == false && has(fence, bare(i)) == false {
          throw Unsupported(reason: "Multiline/nested lists require a Markdown-aware host.")
        }
        continue
      }
      var j = i + 1
      while j < lines.count && !blank(j) {
        if try has(fence, bare(j)) || has(heading, bare(j)) || has(list, bare(j)) || has(rule, bare(j)) { break }
        j += 1
      }
      output.append(Block(kind: "prose", text: lines[i..<j].joined())); i = j
    }
    for block in output where !block.opaque && block.kind != "gap" {
      let masked = try inlineCode(block.text).masked
      if try has(#"<(?:/?[A-Za-z][\w:-]*\b|!--|!DOCTYPE)"#, masked) {
        throw Unsupported(reason: "HTML/MDX is outside the supported subset.")
      }
      if try has(#"(?<!\\)\$[^\n$]+(?<!\\)\$|\\\(|\\\[|\\begin\{"#, masked) {
        throw Unsupported(reason: "Mathematical markup requires a math-aware host.")
      }
    }
    return output
  }

  private static func inlineCode(_ text: String) throws -> (code: [String], masked: String) {
    let delimiters = try matches(#"(?<!\\)(?<!`)`+(?!`)"#, text)
    let ns = text as NSString
    var ranges: [NSRange] = [], k = 0
    while k < delimiters.count {
      let start = delimiters[k]
      var j = k + 1
      while j < delimiters.count && delimiters[j].range.length != start.range.length { j += 1 }
      guard j < delimiters.count else { throw Unsupported(reason: "Unclosed inline-code delimiter.") }
      ranges.append(NSRange(location: start.range.location, length: NSMaxRange(delimiters[j].range) - start.range.location))
      k = j + 1
    }
    let masked = NSMutableString(string: text)
    for range in ranges.reversed() { masked.replaceCharacters(in: range, with: String(repeating: " ", count: range.length)) }
    return (ranges.map { ns.substring(with: $0) }, masked as String)
  }

  private static func links(_ text: String) throws -> [String] {
    let ns = text as NSString
    var found: [String] = []
    for match in try matches(#"(?<!\\)\]\("#, text) {
      let start = NSMaxRange(match.range)
      var depth = 1, j = start
      while j < ns.length && depth > 0 {
        let char = ns.character(at: j)
        if char == 92 { j += 2; continue }
        if char == 40 { depth += 1 }
        if char == 41 { depth -= 1 }
        j += 1
      }
      guard depth == 0 else { throw Unsupported(reason: "Unclosed Markdown link destination.") }
      found.append(ns.substring(with: NSRange(location: start, length: j - 1 - start)))
    }
    return found
  }

  private static func protected(_ text: String) throws -> [String: [String]] {
    let (code, masked) = try inlineCode(text)
    var quotes: [(Int, String)] = []
    var patterns = [#"‘(?:\\.|(?<=\w)’(?=\w)|[^‘’\n])*’"#,
      #""(?:\\.|[^"\n])*""#, #"(?<![\w])'(?:\\.|(?<=\w)'(?=\w)|[^'\n])*'(?![\w])"#]
    for (left, right) in [("“", "”"), ("«", "»"), ("「", "」"), ("『", "』"), ("《", "》")] {
      patterns.append(left + "[^" + left + right + "\\n]*" + right)
    }
    for pattern in patterns {
      for match in try matches(pattern, masked) {
        quotes.append((match.range.location, (masked as NSString).substring(with: match.range)))
      }
    }
    return [
      "inline_code": code,
      "numbers": try captures(#"\d+(?:[.,:/\-]\d+)*"#, masked),
      "number_units_known": try captures(number, masked),
      "links": try links(masked),
      "urls": try captures(#"(?:https?://|mailto:)[^\s<>"「」『』《》]+"#, masked),
      "quotes": quotes.sorted { $0.0 < $1.0 }.map(\.1),
    ]
  }
}
