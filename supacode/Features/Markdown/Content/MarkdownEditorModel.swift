import AppKit
import Observation
import Sharing
import SupacodeSettingsShared

/// Live state of one Markdown editor tab: the document, the Prompt Edit
/// status, the read/edit mode, and the AppKit plumbing (focus, ⌘S, ⌘/, ⌘F) around
/// the engine's text view.
@MainActor
@Observable
final class MarkdownEditorModel: PromptEditHost {
  private static let logger = SupaLogger("MarkdownEditor")

  let contentID: ContentID
  let worktreeID: Worktree.ID
  let relativePath: String
  let document: MarkdownDocument
  var promptEditStatus: PromptEditStatus?
  /// Read mode: not editable, soft line breaks joined like a renderer would.
  var isReadMode = true

  /// Candidate agent sessions in this worktree, resolved on demand.
  @ObservationIgnored let promptEditTargets: () -> [PromptEditTarget]
  /// Routes editor intents into `AppFeature`.
  @ObservationIgnored let send: (MarkdownAction) -> Void
  /// The hosting view, set while mounted.
  @ObservationIgnored weak var hostView: NSView?
  @ObservationIgnored private var keyMonitor: Any?
  @ObservationIgnored private var wantsFocus = true
  /// Mirrors the engine's first-responder reports.
  @ObservationIgnored private(set) var isEditorFocused = false
  @ObservationIgnored let promptEdit = PromptEditController()
  @ObservationIgnored @Shared(.settingsFile) private var settingsFile

  init(
    contentID: ContentID,
    worktreeID: Worktree.ID,
    relativePath: String,
    fileURL: URL,
    promptEditTargets: @escaping () -> [PromptEditTarget],
    send: @escaping (MarkdownAction) -> Void
  ) {
    self.contentID = contentID
    self.worktreeID = worktreeID
    self.relativePath = relativePath
    self.document = MarkdownDocument(fileURL: fileURL)
    self.promptEditTargets = promptEditTargets
    self.send = send
    promptEdit.host = self
  }

  nonisolated deinit {}

  var fileName: String {
    (relativePath as NSString).lastPathComponent
  }

  /// The engine's text view inside the mounted hierarchy.
  var textView: NSTextView? {
    hostView.flatMap(Self.firstTextView(in:))
  }

  func activate() {
    document.startWatching()
    installKeyMonitor()
    promptEdit.activate()
  }

  func deactivate() {
    removeKeyMonitor()
    promptEdit.deactivate()
    document.close()
  }

  /// Makes the text view first responder, now or once it is in a window.
  func focusEditor() {
    wantsFocus = true
    fulfillPendingFocus()
  }

  /// Called by the hosting view whenever it lands in a window or lays out.
  func fulfillPendingFocus() {
    guard wantsFocus, let textView, let window = textView.window else { return }
    wantsFocus = false
    window.makeFirstResponder(textView)
  }

  /// The engine reported a first-responder change.
  func editorFocusChanged(_ focused: Bool) {
    guard focused != isEditorFocused else { return }
    isEditorFocused = focused
    guard focused else { return }
    send(.editorFocused(contentID, worktreeID: worktreeID))
  }

  /// Switches between read and edit mode, keeping roughly the same text at the
  /// top of the viewport.
  func toggleReadMode() {
    let anchor = textView.flatMap(MarkdownScrollAnchor.capture(in:))
    isReadMode.toggle()
    Self.logger.info("[USER] Switched \(relativePath) to \(isReadMode ? "read" : "edit") mode")
    focusEditor()
    guard let anchor else { return }
    // The engine swaps text and restyles over the next layout passes; settle
    // the scroll position after them.
    for delay in [0.0, 0.1] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let textView = self?.textView else { return }
        MarkdownScrollAnchor.restore(anchor, in: textView)
      }
    }
  }

  private func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let consumed = MainActor.assumeIsolated { () -> Bool in
        guard let self, let shortcut = Shortcut(event, overrides: self.settingsFile.global.shortcutOverrides) else {
          return false
        }
        return self.perform(shortcut)
      }
      return consumed ? nil : event
    }
  }

  /// The read-mode toggle chord for tooltips; nil when the user disabled it.
  var readModeShortcutDisplay: String? {
    let overrides = settingsFile.global.shortcutOverrides
    guard overrides[.toggleMarkdownReadMode] != nil else { return "⌘/" }
    return AppShortcut.display(of: AppShortcuts.toggleMarkdownReadMode.effective(from: overrides))
  }

  private func removeKeyMonitor() {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
    }
    keyMonitor = nil
  }

  /// Editor-scoped shortcuts, active only while this editor has focus. Find
  /// chords are caught here because the app menu binds ⌘F to terminal search.
  @MainActor private enum Shortcut {
    case save
    case toggleReadMode
    case find(NSTextFinder.Action)

    init?(_ event: NSEvent, overrides: [AppShortcutID: AppShortcutOverride]) {
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
      case ("s", .command): self = .save
      case ("f", .command): self = .find(.showFindInterface)
      case ("f", [.command, .option]): self = .find(.showReplaceInterface)
      case ("g", .command): self = .find(.nextMatch)
      case ("g", [.command, .shift]): self = .find(.previousMatch)
      case ("e", .command): self = .find(.setSearchString)
      default:
        guard Self.isReadModeToggle(event, modifiers: modifiers, overrides: overrides) else { return nil }
        self = .toggleReadMode
      }
    }

    private static func isReadModeToggle(
      _ event: NSEvent,
      modifiers: NSEvent.ModifierFlags,
      overrides: [AppShortcutID: AppShortcutOverride]
    ) -> Bool {
      if overrides[.toggleMarkdownReadMode] != nil {
        return AppShortcuts.toggleMarkdownReadMode.effective(from: overrides)?.matches(event) == true
      }
      // The default matches by character, not key code: `matches` would resolve "/" to the
      // unshifted 7 key on German (⌘7, Select Tab 7), whereas the typed chord is ⌘⇧7.
      return event.charactersIgnoringModifiers == "/" && modifiers.subtracting(.shift) == .command
    }
  }

  private func perform(_ shortcut: Shortcut) -> Bool {
    guard let textView, let window = textView.window, window.isKeyWindow else { return false }
    let responder = window.firstResponder
    switch shortcut {
    case .save:
      guard responder === textView else { return false }
      Self.logger.info("[USER] Saved \(relativePath) with ⌘S")
      document.save()
    case .toggleReadMode:
      guard responder === textView else { return false }
      toggleReadMode()
    case .find(let action):
      // The find bar's field editor counts as focus too, so ⌘G works from it.
      guard let scrollView = textView.enclosingScrollView,
        let responderView = responder as? NSView, responderView.isDescendant(of: scrollView)
      else { return false }
      Self.logger.info("[USER] Find action \(action.rawValue) in \(relativePath)")
      textView.usesFindBar = true
      textView.isIncrementalSearchingEnabled = true
      let sender = NSMenuItem()
      sender.tag = action.rawValue
      textView.performTextFinderAction(sender)
    }
    return true
  }

  private static func firstTextView(in view: NSView) -> NSTextView? {
    // Skip the find bar's field editor, which lives in the same scroll view.
    if let textView = view as? NSTextView, !textView.isFieldEditor { return textView }
    for subview in view.subviews {
      if let found = firstTextView(in: subview) { return found }
    }
    return nil
  }
}
