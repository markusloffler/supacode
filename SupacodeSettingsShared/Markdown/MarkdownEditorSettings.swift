import Sharing

/// App-storage handles for the built-in Markdown editor. Kept out of the
/// shared settings file so the feature stays a self-contained personal mod.
nonisolated extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
  /// "Open Markdown files in built-in editor": double-clicked `.md` files open
  /// in an editor pane instead of the open-file script / default app.
  public static var markdownEditorEnabled: Self {
    Self[.appStorage("markdownEditorEnabled"), default: true]
  }

  /// Whether a sent Prompt Edit moves focus to the agent's terminal.
  public static var markdownPromptEditFocusesAgent: Self {
    Self[.appStorage("markdownPromptEditFocusesAgent"), default: false]
  }
}

/// Appearance override for the Markdown editor, independent of the app's.
public nonisolated enum MarkdownEditorAppearance: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  public var id: Self { self }

  public var title: String {
    switch self {
    case .system: "Same as App"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

nonisolated extension SharedReaderKey where Self == AppStorageKey<MarkdownEditorAppearance>.Default {
  /// Appearance of the editor in edit mode.
  public static var markdownEditModeAppearance: Self {
    Self[.appStorage("markdownEditModeAppearance"), default: .system]
  }

  /// Appearance of the editor in read mode.
  public static var markdownReadModeAppearance: Self {
    Self[.appStorage("markdownReadModeAppearance"), default: .system]
  }
}

/// The editor's typography and color theme.
public nonisolated enum MarkdownEditorThemeChoice: String, CaseIterable, Identifiable, Sendable {
  /// System font and colors.
  case system
  /// Adapted from Typora's GitHub theme: Open Sans, GitHub colors in light
  /// appearance, a centered reading column.
  case github

  public var id: Self { self }

  public var title: String {
    switch self {
    case .system: "System"
    case .github: "GitHub"
    }
  }
}

nonisolated extension SharedReaderKey where Self == AppStorageKey<MarkdownEditorThemeChoice>.Default {
  public static var markdownEditorTheme: Self {
    Self[.appStorage("markdownEditorTheme"), default: .system]
  }
}
