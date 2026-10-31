import AppKit
import SupacodeSettingsShared

private let pathMenuLogger = SupaLogger("TerminalPathMenu")

/// The "open this path" section of the terminal's right-click menu. Ghostty
/// selects the word under a right-click (or keeps a selection containing it)
/// before the menu opens, so the selection is the candidate path.
extension GhosttySurfaceView {
  func addPathItems(to menu: NSMenu) {
    guard let context = pathMenuContext?() else { return }
    let matches = resolveSelectedPath(context: context)
    guard !matches.isEmpty else { return }

    if matches.count == 1, let url = matches.first {
      for item in pathItems(for: url, context: context) { menu.addItem(item) }
    } else {
      for url in matches {
        let title = TerminalPathResolver.relativePath(of: url, under: context.worktreeRoot) ?? url.lastPathComponent
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        let submenu = NSMenu()
        for child in pathItems(for: url, context: context) { submenu.addItem(child) }
        item.submenu = submenu
        menu.addItem(item)
      }
    }
    menu.addItem(.separator())
  }

  /// Called after a left release: a double-click on a single Markdown file
  /// opens it in the Supacode editor when the setting is on. Ghostty has
  /// selected the word by then, so the selection is the candidate. While a TUI
  /// captures the mouse only Shift+double-click counts: Ghostty then selects
  /// instead of reporting the click to the app.
  func openMarkdownOnDoubleClick(_ event: NSEvent, mouseCaptured: Bool) {
    guard event.clickCount == 2,
      event.modifierFlags.isDisjoint(with: [.control, .option, .command]),
      !mouseCaptured || event.modifierFlags.contains(.shift),
      let context = pathMenuContext?(), context.doubleClickOpensMarkdown
    else { return }
    let matches = resolveSelectedPath(context: context)
    guard matches.count == 1, let url = matches.first, MarkdownOpenRouter.isMarkdown(url) else { return }
    pathMenuLogger.info("[USER] Double-clicked \(url.lastPathComponent), opening in Supacode Editor")
    onOpenPath?(.markdownEditor(url))
  }

  /// Files the current selection names, resolved against the cwd and worktree.
  private func resolveSelectedPath(context: TerminalPathMenuContext) -> [URL] {
    guard
      let selection = accessibilitySelectedText(),
      let candidate = TerminalPathResolver.candidate(from: selection)
    else { return [] }
    let workingDirectory = bridge.state.pwd.map { URL(filePath: $0, directoryHint: .isDirectory) }
    let matches = TerminalPathResolver.resolve(
      candidate,
      workingDirectory: workingDirectory,
      worktreeRoot: context.worktreeRoot
    )
    pathMenuLogger.debug("Path candidate '\(candidate)' resolved to \(matches.count) file(s).")
    return matches
  }

  private func pathItems(for url: URL, context: TerminalPathMenuContext) -> [NSMenuItem] {
    var items: [NSMenuItem] = []
    if let primary = context.primaryAction {
      items.append(
        pathItem("Open with \(primary.labelTitle)", #selector(openPathWith(_:)), PathPayload(url: url, action: primary))
      )
    }
    if MarkdownOpenRouter.isMarkdown(url) {
      let item = pathItem("Open in Supacode Editor", #selector(openPathInMarkdownEditor(_:)), PathPayload(url: url))
      item.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
      items.append(item)
    }
    if !context.fileOpenActions.isEmpty {
      let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
      let submenu = NSMenu()
      for action in context.fileOpenActions {
        let item = pathItem(action.labelTitle, #selector(openPathWith(_:)), PathPayload(url: url, action: action))
        item.image = context.icon(action)
        submenu.addItem(item)
      }
      openWith.submenu = submenu
      items.append(openWith)
    }
    let locate = pathItem("Locate in File Inspector", #selector(locatePathInFileInspector(_:)), PathPayload(url: url))
    locate.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
    items.append(locate)
    let reveal = pathItem("Reveal in Finder", #selector(revealPathInFinder(_:)), PathPayload(url: url))
    reveal.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    items.append(reveal)
    return items
  }

  private func pathItem(_ title: String, _ action: Selector, _ payload: PathPayload) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.representedObject = payload
    return item
  }

  @objc private func openPathWith(_ sender: NSMenuItem) {
    guard let payload = sender.representedObject as? PathPayload, let action = payload.action else { return }
    pathMenuLogger.info("[USER] Open \(payload.url.lastPathComponent) with \(action.labelTitle) from terminal menu")
    onOpenPath?(.open(payload.url, with: action))
  }

  @objc private func openPathInMarkdownEditor(_ sender: NSMenuItem) {
    guard let payload = sender.representedObject as? PathPayload else { return }
    pathMenuLogger.info("[USER] Open \(payload.url.lastPathComponent) in Supacode Editor from terminal menu")
    onOpenPath?(.markdownEditor(payload.url))
  }

  @objc private func locatePathInFileInspector(_ sender: NSMenuItem) {
    guard let payload = sender.representedObject as? PathPayload else { return }
    pathMenuLogger.info("[USER] Locate \(payload.url.lastPathComponent) in File Inspector from terminal menu")
    onOpenPath?(.revealInFileExplorer(payload.url))
  }

  @objc private func revealPathInFinder(_ sender: NSMenuItem) {
    guard let payload = sender.representedObject as? PathPayload else { return }
    pathMenuLogger.info("[USER] Reveal \(payload.url.lastPathComponent) in Finder from terminal menu")
    NSWorkspace.shared.activateFileViewerSelecting([payload.url])
  }
}

/// `representedObject` for the path items; a class because AppKit stores `Any`.
private final class PathPayload {
  let url: URL
  let action: OpenWorktreeAction?

  init(url: URL, action: OpenWorktreeAction? = nil) {
    self.url = url
    self.action = action
  }

  nonisolated deinit {}
}
