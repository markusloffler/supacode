import Foundation

/// Markdown-editor persisted state. The path is relative to the worktree root
/// so a restored layout survives the worktree moving on disk.
nonisolated struct MarkdownContentState: Equatable, Codable, Sendable {
  var relativePath: String

  /// The file name shown as the tab title.
  var fileName: String {
    (relativePath as NSString).lastPathComponent
  }

  /// The absolute file URL under the worktree root.
  func fileURL(in worktreeRoot: URL) -> URL {
    worktreeRoot.appending(path: relativePath, directoryHint: .notDirectory)
  }
}
