import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Builds Markdown editor contents for the layout factory.
@MainActor
struct MarkdownContentBuilder {
  private static let logger = SupaLogger("MarkdownContentBuilder")

  /// The worktree's local root; nil for a vanished or remote worktree.
  var worktreeRoot: (Worktree.ID) -> URL?
  /// Agent sessions a Prompt Edit from this worktree can target.
  var promptEditTargets: (Worktree.ID) -> [PromptEditTarget]
  /// Routes editor intents into `AppFeature`.
  var send: (MarkdownAction) -> Void

  func make(_ request: ContentRequest, state: MarkdownContentState) -> any TabContent {
    guard let root = worktreeRoot(request.worktreeID) else {
      Self.logger.error("No local worktree \(request.worktreeID.rawValue) for editor \(request.contentID.rawValue)")
      return InertTabContent(id: request.contentID, state: request.content)
    }
    // MARK: Diff viewer
    // Every editor and viewer can flip to the file's diff.
    let send = send
    let worktreeID = request.worktreeID
    let targets = promptEditTargets
    let diffModel = DiffViewerModel(
      contentID: request.contentID,
      worktreeID: worktreeID,
      relativePath: state.relativePath,
      worktreeRoot: root,
      promptEditTargets: { targets(worktreeID) },
      send: send
    )
    return DiffSwitchingContent(
      inner: makeEditor(request, state: state, root: root),
      diffModel: diffModel,
      onClick: { send(.editorFocused(request.contentID, worktreeID: worktreeID)) }
    )
  }

  private func makeEditor(_ request: ContentRequest, state: MarkdownContentState, root: URL) -> any TabContent {
    let worktreeID = request.worktreeID
    let targets = promptEditTargets
    let fileURL = state.fileURL(in: root)
    // MARK: Code editor
    // A missing file falls back to the code editor, which shows the load error.
    switch MarkdownOpenRouter.editorKind(for: fileURL) ?? .code {
    case .markdown:
      break
    case .quickLook:
      return QuickLookContent(id: request.contentID, state: state, fileURL: fileURL)
    case .code:
      let model = CodeEditorModel(
        contentID: request.contentID,
        worktreeID: worktreeID,
        relativePath: state.relativePath,
        fileURL: fileURL,
        promptEditTargets: { targets(worktreeID) },
        send: send
      )
      return CodeEditorContent(id: request.contentID, state: state, model: model)
    }
    let model = MarkdownEditorModel(
      contentID: request.contentID,
      worktreeID: worktreeID,
      relativePath: state.relativePath,
      fileURL: fileURL,
      promptEditTargets: { targets(worktreeID) },
      send: send
    )
    return MarkdownContent(id: request.contentID, state: state, model: model)
  }
}

extension MarkdownContentBuilder {
  /// The live builder, reading worktrees and agent presence from the app store.
  static func live(terminalManager: WorktreeTerminalManager) -> Self {
    Self(
      worktreeRoot: { [weak terminalManager] id in
        guard
          let worktree = terminalManager?.appStore?.withState({ $0.repositories.worktree(for: id) }),
          worktree.host == nil
        else { return nil }
        return worktree.workingDirectory
      },
      promptEditTargets: { [weak terminalManager] id in
        terminalManager?.appStore?.withState { $0.promptEditTargets(in: id) } ?? []
      },
      send: { [weak terminalManager] action in
        terminalManager?.appStore?.send(.markdown(action))
      }
    )
  }
}
