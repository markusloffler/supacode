import AppKit
import SupacodeSettingsShared

/// The file behind an editor or viewer tab, and what the tab's right-click file
/// items (mirroring the File Inspector's) need to act on it.
@MainActor
struct TabFileMenu {
  private static let logger = SupaLogger("TabFileMenu")

  let fileURL: URL
  /// Path relative to the worktree root.
  let relativePath: String
  /// Installed editors and their icons, read when the menu builds; nil hides the editor items.
  let context: () -> TerminalPathMenuContext?
  /// Routes opens and the inspector rename to the app store.
  let perform: (TerminalPathOpenRequest) -> Void

  var fileName: String { fileURL.lastPathComponent }

  func openInDefaultApp() {
    Self.logger.info("[USER] Open \(fileName) from tab menu")
    guard !NSWorkspace.shared.open(fileURL) else { return }
    Self.logger.warning("No system-default app opened \(fileName).")
  }

  func open(with action: OpenWorktreeAction) {
    Self.logger.info("[USER] Open \(fileName) with \(action.labelTitle) from tab menu")
    perform(.open(fileURL, with: action))
  }

  func revealInFinder() {
    Self.logger.info("[USER] Reveal \(fileName) in Finder from tab menu")
    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
  }

  func rename() {
    Self.logger.info("[USER] Rename \(fileName) from tab menu")
    perform(.renameInFileExplorer(fileURL))
  }

  /// Writes the file URL so Finder can paste the file itself, like Cmd+C there.
  func copyFile() {
    Self.logger.info("[USER] Copy \(fileName) from tab menu")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([fileURL as NSURL])
  }

  func copyPathname() {
    Self.logger.info("[USER] Copy pathname of \(fileName) from tab menu")
    copyString(fileURL.path(percentEncoded: false))
  }

  func copyRelativePath() {
    Self.logger.info("[USER] Copy relative path of \(fileName) from tab menu")
    copyString(relativePath)
  }

  private func copyString(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
