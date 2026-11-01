import AppKit
import Observation
import SupacodeSettingsShared

/// Live state of one text/code editor tab: the document (shared with the
/// Markdown editor), syntax colouring, and the AppKit plumbing (focus, ⌘S,
/// find bar chords) around its text view.
@MainActor
@Observable
final class CodeEditorModel: PromptEditHost {
  private static let logger = SupaLogger("CodeEditor")

  let contentID: ContentID
  let worktreeID: Worktree.ID
  let relativePath: String
  let document: MarkdownDocument
  var promptEditStatus: PromptEditStatus?

  @ObservationIgnored let highlighter: CodeHighlightController
  /// Candidate agent sessions in this worktree, resolved on demand.
  @ObservationIgnored let promptEditTargets: () -> [PromptEditTarget]
  /// Routes editor intents into `AppFeature`.
  @ObservationIgnored let send: (MarkdownAction) -> Void
  /// The hosting view, set while mounted.
  @ObservationIgnored weak var hostView: NSView?
  /// The text view and its scroll view, set by the representable.
  @ObservationIgnored weak var textView: NSTextView? {
    didSet { highlighter.textView = textView }
  }
  @ObservationIgnored weak var scrollView: NSScrollView?
  @ObservationIgnored private var keyMonitor: Any?
  @ObservationIgnored private var wantsFocus = true
  @ObservationIgnored private var isEditorFocused = false
  @ObservationIgnored let promptEdit = PromptEditController()

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
    self.highlighter = CodeHighlightController(
      language: CodeLanguage.highlightName(forFileName: (relativePath as NSString).lastPathComponent))
    self.promptEditTargets = promptEditTargets
    self.send = send
    promptEdit.host = self
  }

  nonisolated deinit {}

  var fileName: String {
    (relativePath as NSString).lastPathComponent
  }

  func activate() {
    document.startWatching()
    installKeyMonitor()
    promptEdit.activate()
  }

  func deactivate() {
    removeKeyMonitor()
    promptEdit.deactivate()
    highlighter.cancel()
    document.close()
  }

  /// Makes the text view first responder, now or once it is in a window.
  func focusEditor() {
    wantsFocus = true
    fulfillPendingFocus()
  }

  /// Called by the hosting view whenever it lands in a window.
  func fulfillPendingFocus() {
    guard wantsFocus, let textView, let window = textView.window else { return }
    wantsFocus = false
    window.makeFirstResponder(textView)
  }

  /// The text view gained or lost first responder.
  func editorFocusChanged(_ focused: Bool) {
    guard focused != isEditorFocused else { return }
    isEditorFocused = focused
    guard focused else { return }
    send(.editorFocused(contentID, worktreeID: worktreeID))
  }

  private func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let consumed = MainActor.assumeIsolated { () -> Bool in
        guard let self, let shortcut = Shortcut(event) else { return false }
        return self.perform(shortcut)
      }
      return consumed ? nil : event
    }
  }

  private func removeKeyMonitor() {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
    }
    keyMonitor = nil
  }

  /// Editor-scoped chords, active only while the text view or its find bar
  /// has focus. Caught here because the app menu binds ⌘F to terminal search.
  private enum Shortcut {
    case save
    case find(NSTextFinder.Action)

    init?(_ event: NSEvent) {
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
      case ("s", .command): self = .save
      case ("f", .command): self = .find(.showFindInterface)
      case ("f", [.command, .option]): self = .find(.showReplaceInterface)
      case ("g", .command): self = .find(.nextMatch)
      case ("g", [.command, .shift]): self = .find(.previousMatch)
      case ("e", .command): self = .find(.setSearchString)
      default: return nil
      }
    }
  }

  private func perform(_ shortcut: Shortcut) -> Bool {
    guard
      let textView, let scrollView, let window = textView.window, window.isKeyWindow,
      let responder = window.firstResponder as? NSView, responder.isDescendant(of: scrollView)
    else { return false }
    switch shortcut {
    case .save:
      Self.logger.info("[USER] Saved \(relativePath) with ⌘S")
      document.save()
    case .find(let action):
      Self.logger.info("[USER] Find action \(action.rawValue) in \(relativePath)")
      let sender = NSMenuItem()
      sender.tag = action.rawValue
      textView.performTextFinderAction(sender)
    }
    return true
  }
}
