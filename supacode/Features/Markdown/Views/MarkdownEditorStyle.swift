import AppKit
import CoreText
import MarkdownEngine
import SupacodeSettingsShared

/// Everything the editor's look is built from: the engine configuration plus
/// the font and background the wrapper and host own.
@MainActor
struct MarkdownEditorStyle {
  var configuration: MarkdownEditorConfiguration
  var fontName: String
  var fontSize: CGFloat
  var background: NSColor

  /// Built once per theme: the view resolves on every update, and fresh
  /// dynamic colors would make the engine restyle each time.
  private static var cache: [MarkdownEditorThemeChoice: Self] = [:]

  static func resolve(_ choice: MarkdownEditorThemeChoice) -> Self {
    if let cached = cache[choice] { return cached }
    let style: Self =
      switch choice {
      case .system: system
      case .github: github
      }
    cache[choice] = style
    return style
  }

  /// Dynamic Type scale relative to the default body size (13 pt).
  private static var typeScale: CGFloat {
    NSFont.preferredFont(forTextStyle: .body).pointSize / 13
  }

  /// System font and colors, padding proportional to the font.
  private static var system: Self {
    let fontSize = NSFont.preferredFont(forTextStyle: .title3).pointSize
    var configuration = MarkdownEditorConfiguration.default
    configuration.textInsets = TextInsets(horizontal: ceil(fontSize), vertical: ceil(fontSize))
    return Self(configuration: configuration, fontName: "SF Pro", fontSize: fontSize, background: .textBackgroundColor)
  }

  /// Typora's GitHub theme (`theme/github.css`), rendered through the
  /// options of our swift-markdown-engine fork. CSS colors apply in light
  /// appearance; dark falls back to system colors, the CSS being light-only.
  /// Not representable: the width media queries.
  private static var github: Self {
    MarkdownFonts.registerBundled()
    // html { font-size: 16px }, scaled with Dynamic Type.
    let rem = round(16 * typeScale)
    let fontSize = rem
    let fontName = NSFont(name: "OpenSans-Regular", size: fontSize) != nil ? "OpenSans-Regular" : "HelveticaNeue"
    let font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
    var configuration = MarkdownEditorConfiguration.default
    configuration.theme = githubTheme
    // body { -webkit-font-smoothing: antialiased }
    configuration.smoothsFonts = false

    // body { line-height: 1.6 }; the engine adds to the font's own line height.
    let naturalLineHeight = ceil(font.ascender - font.descender + font.leading)
    let lineExtra = max(0, round(fontSize * 1.6 - naturalLineHeight))
    // p, blockquote, ul, ol, table { margin: 0.8em 0 }: the blank line
    // between two blocks is their collapsed margin.
    let blankLine = round(0.8 * fontSize)
    configuration.paragraph = ParagraphStyle(
      spacingFactor: 0, lineHeightExtraSpacing: lineExtra, blankLineHeight: blankLine)
    // Typora lays list items out looser than paragraphs: 1.75em lines and
    // about half an em between items (measured).
    configuration.lists.extraLineHeight = max(0, round(fontSize * 1.75) - naturalLineHeight)
    configuration.lists.itemSpacing = round(0.5 * fontSize)
    configuration.headings = githubHeadings(rem: rem, fontSize: fontSize, blankLine: blankLine)
    // blockquote { border-left: 4px solid #dfe2e5; padding: 0 15px }; the text keeps
    // the body color instead of Typora's #777.
    configuration.blockquote = BlockquoteStyle(
      extraLineHeight: lineExtra,
      indentPerLevel: 19,
      barOffset: 0,
      textOffset: 0,
      barWidth: 4,
      barColor: githubBorder,
      textColor: configuration.theme.bodyText
    )
    // hr { height: 2px; background-color: #e7e7e7 }
    configuration.thematicBreak.ruleThickness = 2
    configuration.thematicBreak.ruleColor = MarkdownEditorColors.dynamic(
      light: MarkdownEditorColors.hex(0xE7E7E7), dark: .separatorColor)
    // .md-fences, code { border: 1px solid #e7eaed; background-color: #f8f8f8;
    // border-radius: 3px; font-size: 0.9em }
    let codeBorder = MarkdownEditorColors.dynamic(light: MarkdownEditorColors.hex(0xE7EAED), dark: .separatorColor)
    configuration.services.syntaxHighlighter = MarkdownCodeHighlighter(background: githubFill)
    configuration.codeBlock.fontSizeScale = 0.9
    configuration.codeBlock.horizontalIndent = 8
    configuration.codeBlock.borderColor = codeBorder
    configuration.codeBlock.cornerRadius = 3
    // .md-fences { padding-top: 8px; padding-bottom: 6px }, minus the code
    // lines' own spacing.
    configuration.codeBlock.hiddenFenceLineHeight = max(1, 7 - configuration.codeBlock.paragraphSpacing)
    // code { background-color: #f3f4f4; padding: 0 2px }
    configuration.inlineCode = InlineCodeStyle(
      fontSizeScale: 0.9,
      drawsBox: true,
      backgroundColor: MarkdownEditorColors.dynamic(
        light: MarkdownEditorColors.hex(0xF3F4F4), dark: .quaternarySystemFill),
      borderColor: codeBorder,
      cornerRadius: 3,
      horizontalPadding: 2,
      verticalPadding: 1
    )
    // table th, td { border: 1px solid #dfe2e5; padding: 6px 13px }
    // table tr:nth-child(2n), thead { background-color: #f8f8f8 }
    configuration.table = TableStyle(
      cellHorizontalPadding: 13,
      cellVerticalPadding: 6,
      borderColor: githubBorder,
      headerBackground: githubFill,
      stripeBackground: githubFill
    )
    // Item text starts about 38px in, a 6px disc bullet 19px before it (measured in Typora).
    configuration.lists.indentPerLevel = round(19 * typeScale)
    configuration.lists.markerSlotWidth = round(19 * typeScale)
    configuration.lists.bulletDiameter = round(0.35 * fontSize)
    // #write { max-width: 860px; padding: 30px }
    configuration.readingWidth = round(860 * typeScale)
    configuration.readingWidthShrinksToFit = true
    configuration.textInsets = TextInsets(horizontal: round(30 * typeScale), vertical: round(30 * typeScale))

    return Self(
      configuration: configuration,
      fontName: fontName,
      fontSize: fontSize,
      background: MarkdownEditorColors.dynamic(light: .white, dark: .textBackgroundColor)
    )
  }

  /// #dfe2e5: table grid and blockquote bar.
  private static let githubBorder = MarkdownEditorColors.dynamic(
    light: MarkdownEditorColors.hex(0xDFE2E5), dark: .separatorColor)
  /// #f8f8f8: fences, table header and striped rows.
  private static let githubFill = MarkdownEditorColors.dynamic(
    light: MarkdownEditorColors.hex(0xF8F8F8), dark: .quaternarySystemFill)

  private static var githubTheme: MarkdownEditorTheme {
    var theme = MarkdownEditorTheme.default
    // body { color: rgb(51, 51, 51) }
    theme.bodyText = MarkdownEditorColors.dynamic(light: MarkdownEditorColors.hex(0x333333), dark: .labelColor)
    // --control-text-color: #777; also blockquote { color: #777 }
    let muted = MarkdownEditorColors.dynamic(light: MarkdownEditorColors.hex(0x777777), dark: .secondaryLabelColor)
    theme.mutedText = muted
    // a { color: #4183C4 }
    theme.link = MarkdownEditorColors.dynamic(light: MarkdownEditorColors.hex(0x4183C4), dark: .linkColor)
    // h6 { color: #777 }
    theme.headingText = [6: muted]
    // h1, h2 { border-bottom: 1px solid #eee }
    theme.headingRule = MarkdownEditorColors.dynamic(light: MarkdownEditorColors.hex(0xEEEEEE), dark: .separatorColor)
    return theme
  }

  /// h1 2.25em … h6 1em with their CSS line heights. margin: 1rem 0, of
  /// which the blank line around a heading already supplies `blankLine`, so
  /// the heading adds the rest above and below. h1, h2 get the
  /// border-bottom rule right below the line box.
  private static func githubHeadings(rem: CGFloat, fontSize: CGFloat, blankLine: CGFloat) -> HeadingStyle {
    let multipliers: [CGFloat] = [2.25, 1.75, 1.5, 1.25, 1.0, 1.0]
    let marginEm = multipliers.map { max(0, rem - blankLine) / (fontSize * $0) }
    return HeadingStyle(
      fontMultipliers: multipliers,
      topSpacingEm: marginEm,
      bottomSpacingEm: marginEm,
      lineHeightMultiples: [1.2, 1.225, 1.43, 1.4, 1.4, 1.4],
      ruleLevels: [1, 2],
      ruleGapEm: 0,
      ruleThickness: 1
    )
  }
}

/// Color helpers shared by the editor styles and the code highlighter.
nonisolated enum MarkdownEditorColors {
  static func hex(_ value: Int) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }

  static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
  }
}

/// Fonts shipped for editor themes, registered for this process on first use.
@MainActor
enum MarkdownFonts {
  private static let logger = SupaLogger("MarkdownFonts")
  private static var isRegistered = false

  static func registerBundled() {
    guard !isRegistered else { return }
    isRegistered = true
    let urls = Bundle.main.urls(forResourcesWithExtension: "woff2", subdirectory: nil) ?? []
    guard !urls.isEmpty else {
      logger.warning("No bundled editor fonts found; themes fall back to system fonts.")
      return
    }
    // Synchronous, so the very first style resolution already sees the fonts.
    var registered = 0
    for url in urls {
      var error: Unmanaged<CFError>?
      if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
        registered += 1
      } else {
        let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
        logger.warning("Failed to register \(url.lastPathComponent): \(reason)")
      }
    }
    logger.debug("Registered \(registered) of \(urls.count) bundled editor fonts")
  }
}
