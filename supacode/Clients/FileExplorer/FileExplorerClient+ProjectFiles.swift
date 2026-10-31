import Foundation
import SupacodeSettingsShared

private nonisolated let projectFilesLogger = SupaLogger("ProjectFiles")

nonisolated extension FileExplorerClient {
  /// Caps the plain-folder walk so a home-directory "project" can't stall the search.
  static let projectFileLimit = 50_000
  /// The palette waits on the listing, so allow far more than a context menu does.
  static let projectFilesTimeoutMilliseconds = 5_000

  /// Root-relative paths of the project's files, sorted for a stable empty-query list.
  static func projectFiles(root: URL) -> [String] {
    var files = TerminalPathResolver.worktreeFiles(root: root, timeoutMilliseconds: projectFilesTimeoutMilliseconds)
    if files.isEmpty {
      projectFilesLogger.debug("No git listing for \(root.lastPathComponent); walking the folder.")
      files = walkedFiles(root: root)
    }
    projectFilesLogger.debug("Listed \(files.count) file(s) in \(root.lastPathComponent).")
    return files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  private static func walkedFiles(root: URL) -> [String] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return [] }
    let prefix = root.standardizedFileURL.path(percentEncoded: false)
    let base = prefix.hasSuffix("/") ? prefix : prefix + "/"
    var files: [String] = []
    for case let url as URL in enumerator {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
      let path = url.standardizedFileURL.path(percentEncoded: false)
      guard path.hasPrefix(base) else { continue }
      files.append(String(path.dropFirst(base.count)))
      if files.count >= projectFileLimit {
        projectFilesLogger.info("Folder walk in \(root.lastPathComponent) hit the \(projectFileLimit) file cap.")
        break
      }
    }
    return files
  }
}
