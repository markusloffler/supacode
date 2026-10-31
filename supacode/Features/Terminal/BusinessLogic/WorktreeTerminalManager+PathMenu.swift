import AppKit
import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared

private let terminalPathLogger = SupaLogger("TerminalPathMenu")

/// Bridges the terminal right-click "open this path" items to the app store:
/// the menu reads the installed editors from it and sends the open back.
extension WorktreeTerminalManager {
  func pathMenuContext(for worktreeID: Worktree.ID) -> TerminalPathMenuContext? {
    guard let appStore else { return nil }
    return appStore.withState { state in
      // Remote paths don't exist on this machine.
      guard let worktree = state.repositories.worktree(for: worktreeID), worktree.host == nil else { return nil }
      let installed = state.installedOpenActions
      let fileOpenActions = installed.filter(\.canOpenFiles)
      let selection =
        state.repositories.repositoryID(containing: worktreeID)
        .flatMap { state.repositories.openActionByRepositoryID[$0] }
        ?? OpenWorktreeAction.unresolvedDefault(defaultEditorID: state.settings.defaultEditorID, installed: installed)
      let resolved = OpenWorktreeAction.availableSelection(selection, installed: installed)
      let icon = openActionIcon
      return TerminalPathMenuContext(
        worktreeRoot: worktree.workingDirectory,
        fileOpenActions: fileOpenActions,
        primaryAction: (resolved.canOpenFiles ? resolved : nil) ?? fileOpenActions.first,
        doubleClickOpensMarkdown: state.settings.terminalDoubleClickOpensMarkdown,
        icon: { icon?($0) }
      )
    }
  }

  func openTerminalPath(_ request: TerminalPathOpenRequest, worktreeID: Worktree.ID) {
    guard let appStore else {
      terminalPathLogger.warning("openTerminalPath: app store unavailable, ignoring.")
      return
    }
    switch request {
    case .open(let url, let action):
      appStore.send(.openFile(url, with: action))
    case .markdownEditor(let url):
      appStore.send(.markdown(.openInEditor(url)))
      appStore.send(.repositories(.revealInFileExplorer(worktreeID: worktreeID, url: url, presentInspector: false)))
    case .revealInFileExplorer(let url):
      appStore.send(.repositories(.revealInFileExplorer(worktreeID: worktreeID, url: url, presentInspector: true)))
    }
  }
}
