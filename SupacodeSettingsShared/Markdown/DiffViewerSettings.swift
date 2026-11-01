import Sharing

/// App-storage handles for the built-in diff viewer.
nonisolated extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
  /// Editor and viewer tabs show the file's uncommitted changes instead of the
  /// file; one app-wide mode, so it stays on while other files open.
  public static var editorDiffMode: Self {
    Self[.appStorage("editorDiffMode"), default: false]
  }

  /// Old and new side by side; off shows one unified column.
  public static var diffViewerSideBySide: Self {
    Self[.appStorage("diffViewerSideBySide"), default: true]
  }
}
