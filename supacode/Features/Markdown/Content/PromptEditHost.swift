import AppKit
import SupacodeSettingsShared

/// Where the editor's latest Prompt Edit stands; written by `AppFeature`.
enum PromptEditStatus: Equatable {
  /// Waiting for the agent's turn to end.
  case queued(requestID: UUID, agent: SkillAgent)
  case sent(agent: SkillAgent)
  case failed(String)
}

/// An editor that offers Prompt Edit on its selection: the Markdown and the
/// text/code editor models.
@MainActor
protocol PromptEditHost: AnyObject {
  var contentID: ContentID { get }
  var worktreeID: Worktree.ID { get }
  var relativePath: String { get }
  var document: MarkdownDocument { get }
  /// The text view the selection lives in, while mounted.
  var textView: NSTextView? { get }
  var promptEditStatus: PromptEditStatus? { get set }
  /// Candidate agent sessions in this worktree, resolved on demand.
  var promptEditTargets: () -> [PromptEditTarget] { get }
  /// Routes editor intents into `AppFeature`.
  var send: (MarkdownAction) -> Void { get }
}

extension PromptEditHost {
  func cancelQueuedPromptEdit() {
    guard case .queued(let requestID, _) = promptEditStatus else { return }
    SupaLogger("PromptEdit").info("[USER] Cancelled queued prompt edit for \(relativePath)")
    send(.promptEditCancelled(requestID))
  }

  func dismissPromptEditStatus() {
    promptEditStatus = nil
  }

  /// A queued Prompt Edit shimmers the editor's tab.
  var isPromptEditQueued: Bool {
    if case .queued = promptEditStatus { return true }
    return false
  }
}
