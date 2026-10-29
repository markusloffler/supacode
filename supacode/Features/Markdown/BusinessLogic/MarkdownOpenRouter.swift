import Foundation

/// Decides where a Markdown file opens in a worktree's layout. One editor pane
/// per worktree: files open as tabs in it, and the first one splits it off to
/// the right of the focused pane.
enum MarkdownOpenRouter {
  static let fileExtensions: Set<String> = ["md", "markdown", "mdx"]

  enum Route: Equatable {
    /// The file is already open: select its tab.
    case selectTab(TabID)
    /// Add a tab to the worktree's editor pane.
    case newTab(inPane: PaneID)
    /// Split a new editor pane off this pane.
    case split(anchor: PaneID)
  }

  static func isMarkdown(_ url: URL) -> Bool {
    fileExtensions.contains(url.pathExtension.lowercased())
  }

  /// `fileURL`'s path relative to `root`; nil when it lies outside.
  static func relativePath(of fileURL: URL, under root: URL) -> String? {
    let candidates = [
      (fileURL.standardizedFileURL, root.standardizedFileURL),
      (fileURL.resolvingSymlinksInPath(), root.resolvingSymlinksInPath()),
    ]
    for (file, base) in candidates {
      let filePath = file.path(percentEncoded: false)
      var basePath = base.path(percentEncoded: false)
      if !basePath.hasSuffix("/") { basePath += "/" }
      if filePath.hasPrefix(basePath), filePath.count > basePath.count {
        return String(filePath.dropFirst(basePath.count))
      }
    }
    return nil
  }

  /// Where `relativePath` opens. A fresh `newPaneID` bootstraps an empty layout.
  static func route(
    relativePath: String,
    in layout: PaneLayout,
    windowedPaneIDs: Set<PaneID>,
    newPaneID: @autoclosure () -> PaneID
  ) -> Route {
    for pane in layout.panes {
      for tab in pane.tabs {
        if case .markdown(let state) = tab.content.state, state.relativePath == relativePath {
          return .selectTab(tab.id)
        }
      }
    }
    if let editorPane = layout.panes.first(where: { pane in
      pane.tabs.contains { $0.content.kind == .markdown }
    }) {
      return .newTab(inPane: editorPane.id)
    }
    // A windowed pane refuses splits; anchor on a pane in the main layout.
    let inline = layout.tree.leaves().filter { !windowedPaneIDs.contains($0) }
    if let focused = layout.focusedPaneID, inline.contains(focused) {
      return .split(anchor: focused)
    }
    if let anchor = inline.first {
      return .split(anchor: anchor)
    }
    return .newTab(inPane: layout.panes.first?.id ?? newPaneID())
  }
}
