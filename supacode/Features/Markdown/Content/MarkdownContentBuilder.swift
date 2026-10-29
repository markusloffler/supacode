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
    let worktreeID = request.worktreeID
    let targets = promptEditTargets
    let model = MarkdownEditorModel(
      contentID: request.contentID,
      worktreeID: worktreeID,
      relativePath: state.relativePath,
      fileURL: state.fileURL(in: root),
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
