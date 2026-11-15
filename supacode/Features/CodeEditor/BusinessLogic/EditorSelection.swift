import Foundation

/// A text range an agent asks Supacode to show (`supacode show`). Lines and
/// columns are 1-based. A missing column spans the whole line: the start of the
/// first line through the end of the last. The end column is inclusive.
nonisolated struct EditorSelection: Equatable, Sendable {
  struct Position: Equatable, Sendable {
    var line: Int
    var column: Int?
  }

  var start: Position
  var end: Position

  init(start: Position, end: Position) {
    self.start = start
    self.end = end
  }

  /// Parses the `from` / `to` deeplink values (`12` or `12:5`); `to` defaults to `from`.
  init?(from: String, to: String?) {
    guard let start = Self.parsePosition(from) else { return nil }
    guard let to else {
      self.init(start: start, end: start)
      return
    }
    guard let end = Self.parsePosition(to) else { return nil }
    self.init(start: start, end: end)
  }

  static func parsePosition(_ value: String) -> Position? {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), let line = Int(parts[0]), line >= 1 else { return nil }
    guard parts.count == 2 else { return Position(line: line) }
    guard let column = Int(parts[1]), column >= 1 else { return nil }
    return Position(line: line, column: column)
  }

  /// The UTF-16 range in `text`, clamped to it; nil when the start line lies past the end.
  func range(in text: String) -> NSRange? {
    let string = text as NSString
    let lines = Self.lineContentRanges(in: string)
    guard start.line <= lines.count else { return nil }
    let startLine = lines[start.line - 1]
    let startOffset =
      start.column.map { startLine.location + Self.utf16Offset(ofColumn: $0 - 1, in: startLine, of: string) }
      ?? startLine.location
    // An end before the start collapses onto the start position.
    let endPosition = (end.line, end.column ?? .max) < (start.line, start.column ?? 0) ? start : end
    let endLine = lines[min(endPosition.line, lines.count) - 1]
    let endOffset =
      endPosition.column.map { endLine.location + Self.utf16Offset(ofColumn: $0, in: endLine, of: string) }
      ?? NSMaxRange(endLine)
    return NSRange(location: startOffset, length: max(0, endOffset - startOffset))
  }

  /// Each line's content range, without its terminator. A trailing newline
  /// yields a final empty line, like an editor shows it.
  private static func lineContentRanges(in string: NSString) -> [NSRange] {
    var ranges: [NSRange] = []
    var location = 0
    repeat {
      var lineStart = 0
      var lineEnd = 0
      var contentsEnd = 0
      string.getLineStart(
        &lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      ranges.append(NSRange(location: lineStart, length: contentsEnd - lineStart))
      location = lineEnd
    } while location < string.length
    if string.length > 0, NSMaxRange(ranges[ranges.count - 1]) < string.length {
      ranges.append(NSRange(location: string.length, length: 0))
    }
    return ranges
  }

  /// The UTF-16 offset of `characters` user-perceived characters into the line, clamped to it.
  private static func utf16Offset(ofColumn characters: Int, in line: NSRange, of string: NSString) -> Int {
    let content = string.substring(with: line)
    let index = content.index(content.startIndex, offsetBy: characters, limitedBy: content.endIndex) ?? content.endIndex
    return content.utf16.distance(from: content.startIndex, to: index)
  }
}
