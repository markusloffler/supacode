import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

private nonisolated let fileShowLogger = SupaLogger("FileShow")

// MARK: - File show.

/// `supacode show` (OSC 3008 from a terminal) and `supacode://file/show` (other
/// apps): bring up a file and select a range in it.
extension AppFeature {
  /// Deeplink entry. Validated synchronously so a socket caller gets the error.
  func handleFileShowDeeplink(
    path: URL,
    selection: EditorSelection?,
    state: inout State
  ) -> Effect<Action> {
    switch Self.fileShowTarget(path, in: state.repositories) {
    case .failure(let failure):
      fileShowLogger.warning("File show deeplink rejected: \(failure.message)")
      state.alert = Self.fileShowAlert(failure.message)
      return .none
    case .success(let worktree):
      return fileShowEffect(path: path, selection: selection, worktree: worktree, returnFocusTo: nil)
    }
  }

  /// Terminal entry. The host already confined the path to its own worktree. The
  /// signal is unauthenticated, so a failure is only logged, never an alert. The
  /// requesting terminal keeps focus, so the user can keep talking to its agent.
  func handleTerminalFileShow(
    path: URL,
    selection: EditorSelection?,
    sourceWorktreeID: Worktree.ID,
    sourceSurfaceID: UUID,
    state: inout State
  ) -> Effect<Action> {
    switch Self.fileShowTarget(path, in: state.repositories) {
    case .failure(let failure):
      fileShowLogger.warning("File show from \(sourceWorktreeID) rejected: \(failure.message)")
      return .none
    case .success(let worktree):
      return fileShowEffect(path: path, selection: selection, worktree: worktree, returnFocusTo: sourceSurfaceID)
    }
  }

  private struct FileShowFailure: Error {
    let message: String
  }

  private static func fileShowTarget(
    _ path: URL, in repositories: RepositoriesFeature.State
  ) -> Result<Worktree, FileShowFailure> {
    let displayPath = path.path(percentEncoded: false)
    guard let worktree = localWorktree(containing: path, in: repositories) else {
      return .failure(FileShowFailure(message: "\(displayPath) is not inside a local worktree known to Supacode."))
    }
    guard MarkdownOpenRouter.opensInEditor(path) else {
      return .failure(FileShowFailure(message: "\(displayPath) does not exist or is not a file."))
    }
    return .success(worktree)
  }

  private func fileShowEffect(
    path: URL, selection: EditorSelection?, worktree: Worktree, returnFocusTo surfaceID: UUID?
  ) -> Effect<Action> {
    fileShowLogger.info(
      "File show: \(path.path(percentEncoded: false)) in \(worktree.id) selection=\(String(describing: selection))")
    return .concatenate(
      .send(.repositories(.selectWorktree(worktree.id))),
      .send(.markdown(.show(path, worktreeID: worktree.id, selection: selection, returnFocusTo: surfaceID)))
    )
  }

  /// The innermost live local worktree whose directory holds `fileURL`, so a
  /// worktree nested inside another repository's folder wins over its parent.
  static func localWorktree(containing fileURL: URL, in repositories: RepositoriesFeature.State) -> Worktree? {
    repositories.repositories
      .flatMap(\.worktrees)
      .filter { worktree in
        worktree.host == nil && !worktree.isMissing
          && MarkdownOpenRouter.relativePath(of: fileURL, under: worktree.workingDirectory) != nil
      }
      .max { lhs, rhs in
        lhs.workingDirectory.path(percentEncoded: false).count < rhs.workingDirectory.path(percentEncoded: false).count
      }
  }

  private static func fileShowAlert(_ message: String) -> AlertState<Alert> {
    AlertState {
      TextState("Cannot Show File")
    } actions: {
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("OK")
      }
    } message: {
      TextState(message)
    }
  }
}
