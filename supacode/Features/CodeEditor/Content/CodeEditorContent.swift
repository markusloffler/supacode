import AppKit
import SwiftUI

/// Text/code editor content. It shares the Markdown editor's content kind and
/// persisted state (a relative path), so routing, the shared editor pane and
/// layout restore treat both alike; the builder picks this one for non-Markdown
/// files. Like Markdown, the file is the session: saved on teardown.
@MainActor
final class CodeEditorContent: TabContent {
  let id: ContentID
  let kind: ContentKind = .markdown
  let model: CodeEditorModel
  private let state: MarkdownContentState
  private let codeChrome: CodeEditorTabChrome
  private var hostingView: CodeEditorHostingView?

  init(id: ContentID, state: MarkdownContentState, model: CodeEditorModel) {
    self.id = id
    self.state = state
    self.model = model
    self.codeChrome = CodeEditorTabChrome(model: model)
  }

  nonisolated deinit {}

  var renderer: NSView? { hostingView }

  var chrome: (any TabChrome)? { codeChrome }

  var isBusy: Bool { model.document.hasUnsavableChanges }

  func startSession(at geometry: ContentGeometry) {
    guard hostingView == nil else { return }
    model.activate()
    hostingView = CodeEditorHostingView(model: model)
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
}

/// Tab chrome for a code editor: the file name as title, a dirty dot, and the
/// shimmer while a Prompt Edit waits for its agent.
@MainActor
final class CodeEditorTabChrome: TabChrome {
  private let model: CodeEditorModel

  init(model: CodeEditorModel) {
    self.model = model
  }

  nonisolated deinit {}

  var accessory: AnyView? {
    guard model.document.isDirty else { return nil }
    return AnyView(MarkdownDirtyDot())
  }

  var isWorking: Bool { model.isPromptEditQueued }

  var progress: TerminalTabProgressDisplay? { nil }

  var isReadOnly: Bool { false }

  var reportedTitle: String? { model.fileName }
}
