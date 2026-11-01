import Foundation

/// The part of the document a Prompt Edit refers to.
struct PromptEditSelection: Equatable, Sendable {
  /// Where a selection that does not cover whole lines starts and ends.
  enum Boundary: Equatable, Sendable {
    /// Short enough to quote in full.
    case whole(String)
    /// The opening and closing words of a longer selection.
    case span(start: String, end: String)
  }

  /// Worktree-relative path of the edited file.
  var relativePath: String
  /// One-based, inclusive line numbers in the raw Markdown.
  var lines: ClosedRange<Int>
  /// Set only when the selection starts or ends mid-line, where the line range
  /// alone would overstate the block.
  var boundary: Boundary?
  // MARK: Diff viewer
  /// Set for a selection made in a diff.
  var diff: DiffContext?

  /// What a diff selection adds to the plain line range.
  struct DiffContext: Equatable, Sendable {
    /// The selected lines removed since HEAD, quoted; nil when none were selected.
    var removed: Boundary?
    /// Only removed lines were selected: `lines` is just where they were.
    var removedOnly: Bool
  }
}

/// Builds the single-line instruction a coding agent receives. Plain language
/// and a plain relative path, so every agent understands it.
enum PromptEditPayload {
  /// Characters quoted from each end of a mid-line selection.
  static let excerptLength = 32

  /// The selection's line range and boundary; nil for an empty or
  /// out-of-bounds range. `range` is in UTF-16 units of `text`.
  static func selection(in text: String, range: NSRange, relativePath: String) -> PromptEditSelection? {
    let nsText = text as NSString
    guard range.length > 0, range.location != NSNotFound, NSMaxRange(range) <= nsText.length else { return nil }
    let partial = !startsAtLineStart(nsText, range: range) || !endsAtLineEnd(nsText, range: range)
    return PromptEditSelection(
      relativePath: relativePath,
      lines: lineRange(in: nsText, range: range),
      boundary: partial ? boundary(of: nsText.substring(with: range)) : nil
    )
  }

  /// One-based inclusive lines covered by `range`. A selection that ends right
  /// after a line break does not extend onto the next line.
  static func lineRange(in text: NSString, range: NSRange) -> ClosedRange<Int> {
    let start = newlineCount(in: text, upTo: range.location) + 1
    var end = NSMaxRange(range)
    if range.length > 0, text.character(at: end - 1) == 0x0A {
      end -= 1
    }
    let endLine = max(start, newlineCount(in: text, upTo: end) + 1)
    return start...endLine
  }

  /// The selection quoted in full when short, else its opening and closing
  /// words; single-line, quotes neutralized.
  static func boundary(of selected: String) -> PromptEditSelection.Boundary {
    let words =
      selected
      .split(whereSeparator: \.isWhitespace)
      .map { $0.replacing("\"", with: "'") }
    let collapsed = words.joined(separator: " ")
    guard collapsed.count > excerptLength * 2 else { return .whole(collapsed) }
    return .span(start: leadingWords(words), end: trailingWords(words))
  }

  /// `Apply the following prompt to the file docs/foo.md, lines 12-18 (from "…"
  /// to "…"). Prompt: "Make this shorter". (If the prompt asks for a change, always
  /// edit the file in place.)` Generic, so questions get answers; the closing
  /// note keeps agents from answering an edit request in the terminal instead.
  static func format(_ selection: PromptEditSelection, instruction: String) -> String {
    let path =
      selection.relativePath.contains(where: \.isWhitespace)
      ? "`\(selection.relativePath)`" : selection.relativePath
    let request = instruction.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    if let diff = selection.diff {
      return formatDiff(selection, diff: diff, path: path, request: request)
    }
    return "Apply the following prompt to the file \(path), \(location(of: selection)). \(prompt(request))"
  }

  /// The instruction quoted (its own quotes neutralized), so it reads as one unit.
  private static func prompt(_ request: String) -> String {
    let quoted = request.replacing("\"", with: "'")
    return "Prompt: \"\(quoted)\". (If the prompt asks for a change, always edit the file in place.)"
  }

  /// `line 12` / `lines 12-18`, plus the quoted boundary of a mid-line selection.
  private static func location(of selection: PromptEditSelection) -> String {
    let lines =
      selection.lines.count == 1
      ? "line \(selection.lines.lowerBound)"
      : "lines \(selection.lines.lowerBound)-\(selection.lines.upperBound)"
    return selection.boundary.map { "\(lines) (\(quote($0)))" } ?? lines
  }

  private static func quote(_ boundary: PromptEditSelection.Boundary) -> String {
    switch boundary {
    case .whole(let text): "\"\(text)\""
    case .span(let start, let end): "from \"\(start)\" to \"\(end)\""
    }
  }

  // MARK: Diff viewer
  /// A diff selection points the agent at the uncommitted change; removed lines
  /// no longer exist in the file, so they are quoted and anchored at their spot.
  private static func formatDiff(
    _ selection: PromptEditSelection,
    diff: PromptEditSelection.DiffContext,
    path: String,
    request: String
  ) -> String {
    let gitDiff = "see `git diff HEAD -- \(selection.relativePath)`"
    let removed = diff.removed.map(quote)
    if diff.removedOnly {
      return "Apply the following prompt to the file \(path) near line \(selection.lines.lowerBound), where"
        + " uncommitted changes removed these lines: \(removed ?? "\"\"") (\(gitDiff)). \(prompt(request))"
    }
    let replaced = removed.map { "; this block replaced these removed lines: \($0)" } ?? ""
    return "Apply the following prompt to the file \(path), \(location(of: selection)). The file has uncommitted"
      + " changes (\(gitDiff))\(replaced). \(prompt(request))"
  }

  private static func startsAtLineStart(_ text: NSString, range: NSRange) -> Bool {
    range.location == 0 || text.character(at: range.location - 1) == 0x0A
  }

  private static func endsAtLineEnd(_ text: NSString, range: NSRange) -> Bool {
    let end = NSMaxRange(range)
    return text.character(at: end - 1) == 0x0A || end == text.length || text.character(at: end) == 0x0A
  }

  private static func leadingWords(_ words: [Substring]) -> String {
    var result = ""
    for word in words {
      let next = result.isEmpty ? String(word) : result + " " + word
      guard next.count <= excerptLength || result.isEmpty else { break }
      result = next
    }
    return result + "…"
  }

  private static func trailingWords(_ words: [Substring]) -> String {
    var result = ""
    for word in words.reversed() {
      let next = result.isEmpty ? String(word) : word + " " + result
      guard next.count <= excerptLength || result.isEmpty else { break }
      result = next
    }
    return "…" + result
  }

  private static func newlineCount(in text: NSString, upTo location: Int) -> Int {
    var count = 0
    var searchRange = NSRange(location: 0, length: min(location, text.length))
    while true {
      let found = text.range(of: "\n", options: .literal, range: searchRange)
      guard found.location != NSNotFound else { return count }
      count += 1
      let next = NSMaxRange(found)
      searchRange = NSRange(location: next, length: NSMaxRange(searchRange) - next)
    }
  }
}
