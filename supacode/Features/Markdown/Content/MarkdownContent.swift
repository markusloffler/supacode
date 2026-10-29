import AppKit
import SwiftUI

/// Markdown editor content. The file is the session: nothing outlives the
/// renderer, so the editor saves on teardown and never hibernates.
@MainActor
final class MarkdownContent: TabContent {
  let id: ContentID
  let kind: ContentKind = .markdown
  let model: MarkdownEditorModel
  private let state: MarkdownContentState
  private let markdownChrome: MarkdownTabChrome
  private var hostingView: MarkdownHostingView?

  init(id: ContentID, state: MarkdownContentState, model: MarkdownEditorModel) {
    self.id = id
    self.state = state
    self.model = model
    self.markdownChrome = MarkdownTabChrome(model: model)
  }

  nonisolated deinit {}

  var renderer: NSView? { hostingView }

  var chrome: (any TabChrome)? { markdownChrome }

  // Edits that closing would lose (an unresolved disk conflict or a failed
  // save); everything else is saved on teardown.
  var isBusy: Bool { model.document.hasUnsavableChanges }

  func startSession(at geometry: ContentGeometry) {
    guard hostingView == nil else { return }
    model.activate()
    hostingView = MarkdownHostingView(model: model)
  }

  func hibernate() {
    tearDown()
  }

  func tearDown() {
    guard hostingView != nil else { return }
    model.deactivate()
    hostingView = nil
  }

  func snapshot() -> ContentSnapshot {
    ContentSnapshot(id: id, state: .markdown(state))
  }

  /// Focuses the editor of a live Markdown content, if `id` is one.
  static func focusEditor(_ id: ContentID, runtime: ContentRuntime) {
    (runtime.content(for: id) as? MarkdownContent)?.model.focusEditor()
  }

  /// Publishes a Prompt Edit status to the editor that sent it.
  static func setPromptEditStatus(_ status: PromptEditStatus?, for id: ContentID, runtime: ContentRuntime) {
    (runtime.content(for: id) as? MarkdownContent)?.model.promptEditStatus = status
  }
}

/// Tab chrome for an editor: the file name as title, a dirty dot, and the
/// shimmer while a Prompt Edit waits for its agent.
@MainActor
final class MarkdownTabChrome: TabChrome {
  private let model: MarkdownEditorModel

  init(model: MarkdownEditorModel) {
    self.model = model
  }

  nonisolated deinit {}

  var accessory: AnyView? {
    guard model.document.isDirty else { return nil }
    return AnyView(MarkdownDirtyDot())
  }

  var isWorking: Bool {
    if case .queued = model.promptEditStatus { return true }
    return false
  }

  var progress: TerminalTabProgressDisplay? { nil }

  var isReadOnly: Bool { false }

  var reportedTitle: String? { model.fileName }
}

/// Unsaved-changes marker before the tab title.
private struct MarkdownDirtyDot: View {
  var body: some View {
    Circle()
      .fill(.secondary)
      .frame(width: 6, height: 6)
      .padding(.trailing, 2)
      .help("Unsaved changes")
      .accessibilityLabel("Unsaved changes")
  }
}
