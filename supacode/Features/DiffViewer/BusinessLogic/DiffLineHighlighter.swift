import AppKit

/// Splits a text into syntax-coloured lines for the diff viewer. The whole text
/// is highlighted at once (so multi-line strings and comments colour right),
/// then the colour runs are cut at line breaks.
nonisolated enum DiffLineHighlighter {
  /// Blocking (highlight.js); call it off the main thread.
  static func lines(of text: String, fileName: String, dark: Bool, font: NSFont) -> [NSAttributedString] {
    let lines = LineDiff.splitLines(text)
    let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
    let attributed = lines.map { NSMutableAttributedString(string: $0, attributes: base) }
    guard
      let language = CodeLanguage.highlightName(forFileName: fileName),
      (text as NSString).length <= CodeSyntaxHighlighter.maxLength,
      let runs = CodeSyntaxHighlighter.runs(code: text, language: language, dark: dark)?.runs
    else { return attributed }
    // UTF-16 start offset of each line; every line but the last ends in "\n".
    var starts: [Int] = []
    starts.reserveCapacity(lines.count)
    var offset = 0
    for line in attributed {
      starts.append(offset)
      offset += line.length + 1
    }
    var lineIndex = 0
    for run in runs.sorted(by: { $0.range.location < $1.range.location }) {
      while lineIndex + 1 < starts.count, starts[lineIndex + 1] <= run.range.location {
        lineIndex += 1
      }
      // A run can span several lines (block comments, multi-line strings).
      var index = lineIndex
      while index < attributed.count, starts[index] < NSMaxRange(run.range) {
        let lineStart = starts[index]
        let lower = max(run.range.location, lineStart) - lineStart
        let upper = min(NSMaxRange(run.range), lineStart + attributed[index].length) - lineStart
        if upper > lower {
          attributed[index].addAttribute(
            .foregroundColor, value: run.color, range: NSRange(location: lower, length: upper - lower))
        }
        index += 1
      }
    }
    return attributed
  }
}
