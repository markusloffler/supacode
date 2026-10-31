import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Backs the ⌘⇧O file search: hands the palette the selected worktree's root to
/// list, and opens the picked file (Markdown in the Supacode editor, anything
/// else in the project's editor at the project root). Composed next to
/// `AppFeature`'s core so the upstream reducer only forwards to it.
struct FileSearchAppReducer: Reducer {
  typealias State = AppFeature.State
  typealias Action = AppFeature.Action

  private static let logger = SupaLogger("FileSearch")

  @Dependency(\.workspaceClient) private var workspaceClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .commandPalette(.delegate(.projectFilesRequested)):
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID),
          let root = FileExplorerFeature.Context(worktree: worktree).root
        else {
          Self.logger.debug("projectFilesRequested: no local worktree selected, closing the file search.")
          return .send(.commandPalette(.setPresented(false)))
        }
        return .send(.commandPalette(.loadProjectFiles(root: root)))

      case .commandPalette(.delegate(.openProjectFile(let url, let root))):
        return open(url, root: root, state: state)

      default:
        return .none
      }
    }
  }

  private func open(_ url: URL, root: URL, state: State) -> Effect<Action> {
    Self.logger.info("[USER] Opened \(url.lastPathComponent) from the file search.")
    guard !MarkdownOpenRouter.isMarkdown(url) else {
      var effects: [Effect<Action>] = [.send(.markdown(.openInEditor(url)))]
      if let worktreeID = state.repositories.selectedWorktreeID {
        effects.append(
          .send(.repositories(.revealInFileExplorer(worktreeID: worktreeID, url: url, presentInspector: false)))
        )
      }
      return .merge(effects)
    }
    // The repository's editor, as the toolbar resolves it; a non-editor pick
    // (Finder, a terminal) falls through to the system default app.
    let resolved = OpenWorktreeAction.availableSelection(
      state.openActionSelection,
      installed: state.installedOpenActions
    )
    let action = resolved.canOpenFiles ? resolved : nil
    return .run { @MainActor [workspaceClient] send in
      guard let error = await workspaceClient.openFileInProject(url, root, action) else { return }
      send(.openWorktreeFailed(error))
    }
  }
}
