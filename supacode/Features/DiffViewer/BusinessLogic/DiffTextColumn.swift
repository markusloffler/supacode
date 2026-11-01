import AppKit

/// One text view's worth of diff: the text, and for each of its lines the diff
/// line it shows. Side by side has an old and a new column whose lines align
/// row by row (padding fills the gaps); unified has one column.
nonisolated struct DiffTextColumn: @unchecked Sendable {
  enum Side: Sendable {
    case unified
    case old
    case new
  }

  let side: Side
  let text: NSAttributedString
  /// One entry per text line; nil is padding opposite an unpaired change.
  let lines: [LineDiff.Line?]
  /// UTF-16 offset where each text line starts.
  let lineStarts: [Int]

  /// Joins the side's highlighted lines; immutable once built.
  init(
    side: Side, lines: [LineDiff.Line?], oldLines: [NSAttributedString], newLines: [NSAttributedString], font: NSFont
  ) {
    let text = NSMutableAttributedString()
    let newline = NSAttributedString(string: "\n", attributes: [.font: font])
    var starts: [Int] = []
    starts.reserveCapacity(lines.count)
    for (index, line) in lines.enumerated() {
      starts.append(text.length)
      if let content = Self.content(of: line, side: side, oldLines: oldLines, newLines: newLines) {
        text.append(content)
      }
      if index < lines.count - 1 { text.append(newline) }
    }
    self.side = side
    self.text = text
    self.lines = lines
    self.lineStarts = starts
  }

  /// The line number shown in the gutter.
  func number(at index: Int) -> Int? {
    guard let line = lines[index] else { return nil }
    let value: Int? =
      switch side {
      case .old: line.oldIndex
      case .new: line.newIndex
      case .unified: line.newIndex ?? line.oldIndex
      }
    return value.map { $0 + 1 }
  }

  /// The text line holding UTF-16 `location`.
  func lineIndex(containing location: Int) -> Int {
    var low = 0
    var high = lineStarts.count - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
    }
    return max(0, low)
  }

  /// The text lines `range` touches; a range ending right after a line break
  /// does not reach onto the next line.
  func lineIndices(for range: NSRange) -> ClosedRange<Int>? {
    guard !lineStarts.isEmpty else { return nil }
    let first = lineIndex(containing: range.location)
    let end = range.length > 0 ? NSMaxRange(range) - 1 : range.location
    return first...max(first, lineIndex(containing: end))
  }

  private static func content(
    of line: LineDiff.Line?, side: Side, oldLines: [NSAttributedString], newLines: [NSAttributedString]
  ) -> NSAttributedString? {
    guard let line else { return nil }
    switch side {
    case .old: return line.oldIndex.map { oldLines[$0] }
    case .new: return line.newIndex.map { newLines[$0] }
    case .unified: return line.newIndex.map { newLines[$0] } ?? line.oldIndex.map { oldLines[$0] }
    }
  }
}

/// Turns the diff lines a selection covers into a Prompt Edit selection: the
/// current file's line range, plus the removed lines quoted. Removed lines
/// alone are anchored where they were.
enum DiffPromptSelection {
  static func selection(
    of selected: [LineDiff.Line?],
    oldTexts: [String],
    newLineCount: Int,
    relativePath: String
  ) -> PromptEditSelection? {
    let lines = selected.compactMap(\.self)
    guard !lines.isEmpty else { return nil }
    let current = lines.compactMap(\.newIndex)
    let removedText = lines.filter { $0.kind == .removed }.compactMap(\.oldIndex).map { oldTexts[$0] }
    let removed = removedText.isEmpty ? nil : PromptEditPayload.boundary(of: removedText.joined(separator: "\n"))
    if let first = current.min(), let last = current.max() {
      return PromptEditSelection(
        relativePath: relativePath,
        lines: (first + 1)...(last + 1),
        boundary: nil,
        diff: .init(removed: removed, removedOnly: false)
      )
    }
    let anchor = min(max(1, (lines.first?.newPosition ?? 0) + 1), max(1, newLineCount))
    return PromptEditSelection(
      relativePath: relativePath,
      lines: anchor...anchor,
      boundary: nil,
      diff: .init(removed: removed, removedOnly: true)
    )
  }
}
