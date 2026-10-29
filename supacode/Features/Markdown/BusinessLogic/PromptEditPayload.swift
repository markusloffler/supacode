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

  /// `Edit the file docs/foo.md in place, lines 12-18 (from "…" to "…").
  /// Make the following change to this block: Make this shorter.`
  /// The edit wording is explicit: a bare "In <file>: translate" reads as a
  /// question, and agents answer it in the terminal instead of editing.
  static func format(_ selection: PromptEditSelection, instruction: String) -> String {
    let path =
      selection.relativePath.contains(where: \.isWhitespace)
      ? "`\(selection.relativePath)`" : selection.relativePath
    let lines =
      selection.lines.count == 1
      ? "line \(selection.lines.lowerBound)"
      : "lines \(selection.lines.lowerBound)-\(selection.lines.upperBound)"
    let location =
      switch selection.boundary {
      case nil: lines
      case .whole(let text): "\(lines) (\"\(text)\")"
      case .span(let start, let end): "\(lines) (from \"\(start)\" to \"\(end)\")"
      }
    let request = instruction.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    let sentence = request.last.map { ".!?".contains($0) } == true ? request : request + "."
    return "Edit the file \(path) in place, \(location). Make the following change to this block: \(sentence)"
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
