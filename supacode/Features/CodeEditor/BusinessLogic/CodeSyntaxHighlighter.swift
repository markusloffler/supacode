import AppKit
import MarkdownEngineCodeBlocks

/// Syntax colouring through the highlight.js bridge that ships with the
/// Markdown engine. One bridge per appearance, each pinned to its theme so
/// colouring never reads the app's appearance and can run off the main thread.
nonisolated enum CodeSyntaxHighlighter {
  /// Longer texts stay plain: highlight.js re-lexes the whole file per edit.
  static let maxLength = 300_000

  /// Foreground colour runs covering the whole highlighted text.
  struct Runs: @unchecked Sendable {
    let runs: [(range: NSRange, color: NSColor)]
  }

  private static let light = HighlightJSBridge(lightTheme: .githubLight, autoSwitchAppearance: false)
  private static let dark = HighlightJSBridge(
    lightTheme: .githubDark, darkTheme: .githubDark, autoSwitchAppearance: false)

  /// Nil when highlight.js failed; blocking, call it off the main thread.
  static func runs(code: String, language: String, dark isDark: Bool) -> Runs? {
    let bridge = isDark ? dark : light
    guard let highlighted = bridge.highlight(code: code, language: language) else { return nil }
    var runs: [(range: NSRange, color: NSColor)] = []
    highlighted.enumerateAttribute(
      .foregroundColor, in: NSRange(location: 0, length: highlighted.length)
    ) { value, range, _ in
      if let color = value as? NSColor { runs.append((range, color)) }
    }
    return Runs(runs: runs)
  }
}
