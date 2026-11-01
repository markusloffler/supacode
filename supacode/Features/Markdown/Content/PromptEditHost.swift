import AppKit
import SupacodeSettingsShared

/// Where the editor's latest Prompt Edit stands; written by `AppFeature`.
enum PromptEditStatus: Equatable {
  /// Waiting for the agent's turn to end.
  case queued(requestID: UUID, agent: SkillAgent)
  case sent(agent: SkillAgent)
  case failed(String)
}

/// Offers Prompt Edit on a text selection: the editors, and the read-only diff.
@MainActor
protocol PromptEditSource: AnyObject {
  var contentID: ContentID { get }
  var worktreeID: Worktree.ID { get }
  var relativePath: String { get }
  /// The text view the selection lives in, while mounted.
  var textView: NSTextView? { get }
  var promptEditStatus: PromptEditStatus? { get set }
  /// Candidate agent sessions in this worktree, resolved on demand.
  var promptEditTargets: () -> [PromptEditTarget] { get }
  /// Routes editor intents into `AppFeature`.
  var send: (MarkdownAction) -> Void { get }
  /// What `range` of `textView` refers to; nil when it cannot be referenced.
  func promptEditSelection(for range: NSRange) -> PromptEditSelection?
  /// Runs right before a request goes out.
  func prepareForPromptEdit()
}

/// An editor with a document: the Markdown and the text/code editor models.
@MainActor
protocol PromptEditHost: PromptEditSource {
  var document: MarkdownDocument { get }
}

extension PromptEditHost {
  func promptEditSelection(for range: NSRange) -> PromptEditSelection? {
    PromptEditPayload.selection(in: document.text, range: range, relativePath: relativePath)
  }

  /// The agent must read what the user sees.
  func prepareForPromptEdit() {
    document.save()
  }
}

extension PromptEditSource {
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
