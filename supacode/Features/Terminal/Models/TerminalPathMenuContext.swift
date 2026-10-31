import AppKit
import Foundation
import SupacodeSettingsShared

/// What a terminal's right-click menu needs to offer "open this path": the
/// worktree to search, the editors to list, and their icons. Nil for remote
/// worktrees, whose paths don't exist on this machine.
struct TerminalPathMenuContext {
  let worktreeRoot: URL
  /// Installed editors that can open a single file, in menu order.
  let fileOpenActions: [OpenWorktreeAction]
  /// The repository's selected editor when it can open files, else the first one.
  let primaryAction: OpenWorktreeAction?
  /// Settings toggle: a double-click on a Markdown file name opens the Supacode editor.
  let doubleClickOpensMarkdown: Bool
  let icon: (OpenWorktreeAction) -> NSImage?
}

/// A path open picked from a terminal's right-click menu.
enum TerminalPathOpenRequest: Equatable {
  case open(URL, with: OpenWorktreeAction)
  case markdownEditor(URL)
  case revealInFileExplorer(URL)
}
