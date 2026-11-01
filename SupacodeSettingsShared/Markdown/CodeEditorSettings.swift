import Sharing

/// App-storage handles for the built-in text/code editor, a sibling of the
/// Markdown editor that shares its open gates and edit-mode appearance.
nonisolated extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
  /// Long lines wrap at the pane edge instead of scrolling horizontally.
  public static var codeEditorSoftWrap: Self {
    Self[.appStorage("codeEditorSoftWrap"), default: false]
  }
}
