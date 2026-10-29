import SwiftUI

/// Opens a file in the built-in Markdown editor. Always equal: it only
/// captures the stable app store, so a new instance never needs to invalidate.
struct MarkdownEditorOpener: Equatable {
  let open: (URL) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
  /// Nil where the editor is not reachable. Lets the file explorer offer the
  /// editor without threading a callback through every inspector view.
  @Entry var openInMarkdownEditor: MarkdownEditorOpener?
}
