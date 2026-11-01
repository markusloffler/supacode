import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks

/// Fenced-code highlighting for the editor's GitHub theme: highlight.js with
/// the token colors Typora shows (CodeMirror's default theme) in light and
/// GitHub Dark in dark appearance, resolved per drawing appearance instead of
/// the key window's, because the editor can override its own appearance.
nonisolated struct MarkdownCodeHighlighter: SyntaxHighlighter {
  private static let light = HighlightJSBridge(lightTheme: codeMirrorLight(), autoSwitchAppearance: false)
  private static let dark = HighlightJSBridge(
    lightTheme: .githubDark, darkTheme: .githubDark, autoSwitchAppearance: false)

  let background: NSColor

  func codeFont(size: CGFloat) -> NSFont {
    Self.light.codeFont(size: size)
  }

  func backgroundColor() -> NSColor {
    background
  }

  /// Light runs carry dynamic colors whose dark side comes from the dark
  /// theme at the same location (both themes share the grammar's tokens).
  func highlight(code: String, language: String?) -> NSAttributedString? {
    guard let lightRuns = Self.light.highlight(code: code, language: language) else { return nil }
    let darkRuns = Self.dark.highlight(code: code, language: language)
    let result = NSMutableAttributedString(attributedString: lightRuns)
    lightRuns.enumerateAttribute(
      .foregroundColor, in: NSRange(location: 0, length: lightRuns.length)
    ) { value, range, _ in
      guard let lightColor = value as? NSColor else { return }
      let darkColor =
        darkRuns.flatMap { $0.length > range.location ? $0 : nil }?
        .attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        ?? .labelColor
      result.addAttribute(
        .foregroundColor, value: MarkdownEditorColors.dynamic(light: lightColor, dark: darkColor), range: range)
    }
    return result
  }

  var appearanceDidChangeNotification: Notification.Name? { nil }

  /// CodeMirror's `cm-s-default` colors mapped onto highlight.js scopes.
  private static func codeMirrorLight() -> CodeHighlightTheme {
    let groups: [(Int, [String])] = [
      (0x770088, ["keyword", "doctag", "template-tag", "selector-tag"]),
      (0x3300AA, ["built_in", "name"]),
      (0x0000CC, ["attr", "attribute", "selector-attr", "selector-class", "selector-id", "link"]),
      (0x0000FF, ["title", "title.function", "title.class", "section"]),
      (0x221199, ["literal", "symbol", "variable.language"]),
      (0x116644, ["number"]),
      (0x0055AA, ["variable", "template-variable"]),
      (0x008855, ["type"]),
      (0xAA5500, ["comment", "quote"]),
      (0xAA1111, ["string", "deletion"]),
      (0xFF5500, ["regexp", "subst"]),
      (0x555555, ["meta"]),
      (0x117700, ["addition", "bullet"]),
    ]
    var colors: [String: NSColor] = [:]
    for (value, scopes) in groups {
      for scope in scopes { colors[scope] = MarkdownEditorColors.hex(value) }
    }
    return CodeHighlightTheme(foreground: .black, background: .white, colors: colors)
  }
}
