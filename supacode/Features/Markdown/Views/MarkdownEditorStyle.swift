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

  /// Typora's GitHub theme (`theme/github.css`), as far as the engine's
  /// configuration reaches. CSS colors apply in light appearance; dark falls
  /// back to system colors, the CSS being light-only. Not representable:
  /// heading rules under h1/h2, the h6 and blockquote text colors, table and
  /// code backgrounds and borders, and the width media queries.
  private static var github: Self {
    MarkdownFonts.registerBundled()
    // html { font-size: 16px }, scaled with Dynamic Type.
    let fontSize = round(16 * typeScale)
    let fontName = NSFont(name: "OpenSans-Regular", size: fontSize) != nil ? "OpenSans-Regular" : "HelveticaNeue"
    let font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
    var configuration = MarkdownEditorConfiguration.default

    var theme = MarkdownEditorTheme.default
    // body { color: rgb(51, 51, 51) }
    theme.bodyText = dynamic(light: hex(0x333333), dark: .labelColor)
    // --control-text-color: #777
    theme.mutedText = dynamic(light: hex(0x777777), dark: .secondaryLabelColor)
    // a { color: #4183C4 }
    theme.link = dynamic(light: hex(0x4183C4), dark: .linkColor)
    // hr { background-color: #e7e7e7 }
    theme.strikethroughColor = dynamic(light: hex(0xE7E7E7), dark: .separatorColor)
    configuration.theme = theme

    // body { line-height: 1.6 }; the engine adds to the font's own line height.
    let naturalLineHeight = ceil(font.ascender - font.descender + font.leading)
    configuration.paragraph = ParagraphStyle(
      spacingFactor: 0,
      lineHeightExtraSpacing: max(0, round(fontSize * 1.6 - naturalLineHeight))
    )
    // h1 2.25em … h6 1em; margin-top: 1rem, tempered because the blank line
    // before a heading already adds a line of space.
    configuration.headings = HeadingStyle(
      fontMultipliers: [2.25, 1.75, 1.5, 1.25, 1.0, 1.0],
      topSpacingEm: [0.6, 0.6, 0.5, 0.4, 0.4, 0.4]
    )
    // ul, ol { padding-left: 30px }
    configuration.lists.indentPerLevel = round(30 * typeScale)
    // code, .md-fences { font-size: 0.9em }
    configuration.inlineCode.fontSizeScale = 0.9
    configuration.codeBlock.fontSizeScale = 0.9
    // #write { max-width: 860px; padding: 30px }
    configuration.readingWidth = round(860 * typeScale)
    configuration.textInsets = TextInsets(horizontal: round(30 * typeScale), vertical: round(30 * typeScale))

    return Self(
      configuration: configuration,
      fontName: fontName,
      fontSize: fontSize,
      background: dynamic(light: .white, dark: .textBackgroundColor)
    )
  }

  private static func hex(_ value: Int) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }

  private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
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
