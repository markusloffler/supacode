import Foundation

/// Joins soft line breaks for read mode, approximating how a Markdown renderer
/// flows a paragraph. Each joined `\n` becomes a space and the continuation
/// line's quote markers and indentation become zero-width spaces, so the result
/// has the same UTF-16 length as the source and every offset maps 1:1 back to it.
///
/// A line-based approximation, not a CommonMark parser: a break joins only
/// between two plain text lines at the same quote depth (or a lazy quote
/// continuation), never across blank lines, block starts (headings, lists,
/// nested quotes, tables, rules, HTML), code, hard breaks, or a setext underline.
/// Indented code never interrupts a paragraph and does not exist inside a list,
/// so an indented line below text (a lazy list continuation) joins.
enum MarkdownSoftBreaks {
  static func joined(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count > 1 else { return text }
    var result = String()
    result.reserveCapacity(text.utf8.count)
    var inFence = false
    var inIndentedCode = false
    var inList = false
    var previousBlank = true
    var hiddenPrefix = 0
    for index in lines.indices {
      let line = lines[index]
      result += String(repeating: "\u{200B}", count: hiddenPrefix)
      result += line.dropFirst(hiddenPrefix)
      hiddenPrefix = 0
      let quote = QuotePrefix(line)
      let isFence = isFenceLine(quote.body)
      let blank = isBlank(line)
      if !inFence, !blank {
        if isListItem(trimmed(quote.body)) {
          inList = true
        } else if previousBlank, quote.body.first != " ", quote.body.first != "\t" {
          inList = false
        }
        let indented = quote.body.hasPrefix("    ") || quote.body.hasPrefix("\t")
        inIndentedCode = indented && !inList && (previousBlank || inIndentedCode)
      }
      previousBlank = blank
      let lineInCode = inFence || isFence || (inIndentedCode && !blank)
      if isFence { inFence.toggle() }
      guard index < lines.index(before: lines.endIndex) else { break }
      let nextQuote = QuotePrefix(lines[index + 1])
      let sameQuote = nextQuote.depth == quote.depth || (quote.depth > 0 && nextQuote.depth == 0)
      let joins =
        !lineInCode && !inFence && sameQuote && !isFenceLine(nextQuote.body)
        && joinsSoftBreak(quote.body, nextQuote.body)
      result += joins ? " " : "\n"
      if joins {
        let indentation = nextQuote.body.prefix(while: { $0 == " " || $0 == "\t" }).count
        hiddenPrefix = nextQuote.length + indentation
      }
    }
    return result
  }

  /// Whether the break between two non-code lines is a soft break.
  static func joinsSoftBreak(_ line: Substring, _ next: Substring) -> Bool {
    guard !isBlank(line), !isBlank(next) else { return false }
    // Two trailing spaces or a backslash are an explicit hard break.
    guard !line.hasSuffix("  "), !line.hasSuffix("\\") else { return false }
    guard !endsBlock(line), !startsBlock(next), !isSetextUnderline(next) else { return false }
    return true
  }

  /// The leading `>` markers of a line (each with up to three spaces before
  /// and one after), and the text after them.
  private struct QuotePrefix {
    var depth = 0
    var length = 0
    var body: Substring

    init(_ line: Substring) {
      body = line
      while true {
        let rest = MarkdownSoftBreaks.content(body)
        guard rest.first == ">" else { break }
        var afterMarker = rest.dropFirst()
        if afterMarker.first == " " { afterMarker = afterMarker.dropFirst() }
        length += body.count - afterMarker.count
        depth += 1
        body = afterMarker
      }
    }
  }

  private static func isBlank(_ line: Substring) -> Bool {
    line.allSatisfy(\.isWhitespace)
  }

  /// Up to three spaces of indentation are insignificant for block starts.
  private static func content(_ line: Substring) -> Substring {
    var trimmed = line
    var removed = 0
    while removed < 3, trimmed.first == " " {
      trimmed = trimmed.dropFirst()
      removed += 1
    }
    return trimmed
  }

  /// A line without any indentation; nested list items sit at any depth.
  private static func trimmed(_ line: Substring) -> Substring {
    line.drop(while: { $0 == " " || $0 == "\t" })
  }

  private static func isFenceLine(_ line: Substring) -> Bool {
    let body = content(line)
    return body.hasPrefix("```") || body.hasPrefix("~~~")
  }

  /// A line that ends its block: a heading, table row, rule, or HTML line.
  private static func endsBlock(_ line: Substring) -> Bool {
    let body = content(line)
    return body.hasPrefix("#") || isTableRow(body) || isThematicBreak(body) || body.hasPrefix("<")
  }

  /// A line that opens a new block instead of continuing the paragraph.
  private static func startsBlock(_ line: Substring) -> Bool {
    let body = content(line)
    if body.hasPrefix("#") || body.hasPrefix(">") || body.hasPrefix("<") { return true }
    if isTableRow(body) || isThematicBreak(body) || isListItem(trimmed(line)) { return true }
    return false
  }

  private static func isListItem(_ body: Substring) -> Bool {
    if let first = body.first, "-*+".contains(first) {
      let rest = body.dropFirst()
      return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }
    let digits = body.prefix(while: \.isNumber)
    guard !digits.isEmpty, digits.count <= 9 else { return false }
    let rest = body.dropFirst(digits.count)
    guard let marker = rest.first, marker == "." || marker == ")" else { return false }
    let afterMarker = rest.dropFirst()
    return afterMarker.isEmpty || afterMarker.first == " " || afterMarker.first == "\t"
  }

  private static func isTableRow(_ body: Substring) -> Bool {
    body.hasPrefix("|") || body.contains(" | ")
  }

  private static func isThematicBreak(_ body: Substring) -> Bool {
    let marks = body.filter { !$0.isWhitespace }
    guard marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
    return marks.allSatisfy { $0 == mark }
  }

  /// `===` or `---` under a line turns that line into a heading.
  private static func isSetextUnderline(_ line: Substring) -> Bool {
    let body = content(line).trimmingCharacters(in: .whitespaces)
    guard let mark = body.first, mark == "=" || mark == "-" else { return false }
    return body.allSatisfy { $0 == mark }
  }
}
