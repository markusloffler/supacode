import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// One coding-agent session a Prompt Edit can go to.
struct PromptEditTarget: Equatable, Identifiable, Sendable {
  var surfaceID: UUID
  var agent: SkillAgent
  var activity: AgentPresenceFeature.Activity
  /// The hosting terminal tab's title.
  var title: String

  var id: String { "\(surfaceID.uuidString)-\(agent.rawValue)" }
}

/// Whether a queued Prompt Edit may be injected now.
enum PromptEditReadiness: Equatable {
  /// At its prompt: idle, awaiting input, or parked after a failed turn.
  case ready
  /// Mid-turn; injected text would land in a busy TUI.
  case wait
  /// The session is gone.
  case gone

  static func of(_ activity: AgentPresenceFeature.Activity?) -> Self {
    switch activity {
    case nil: .gone
    case .idle, .awaitingInput, .error: .ready
    case .busy, .compacting: .wait
    }
  }
}

/// Agent sessions of a worktree, from agent presence (any `SkillAgent`).
enum PromptEditTargeting {
  /// Every (terminal, agent) pair in the layout, the last focused session
  /// first, then ready ones, then by title.
  static func targets(
    in layout: PaneLayout,
    presence: AgentPresenceFeature.State,
    lastFocusedSurfaceID: UUID?,
    title: (TabItem) -> String
  ) -> [PromptEditTarget] {
    var targets: [PromptEditTarget] = []
    for pane in layout.panes {
      for tab in pane.tabs where tab.content.kind == .terminal {
        let surfaceID = tab.content.id.rawValue
        for agent in presence.bySurface[surfaceID] ?? [] {
          let key = AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: surfaceID)
          targets.append(
            PromptEditTarget(
              surfaceID: surfaceID,
              agent: agent,
              activity: presence.records[key]?.activity ?? .idle,
              title: title(tab)
            )
          )
        }
      }
    }
    return targets.sorted { lhs, rhs in
      let lhsFocused = lhs.surfaceID == lastFocusedSurfaceID
      let rhsFocused = rhs.surfaceID == lastFocusedSurfaceID
      if lhsFocused != rhsFocused { return lhsFocused }
      let lhsReady = PromptEditReadiness.of(lhs.activity) == .ready
      let rhsReady = PromptEditReadiness.of(rhs.activity) == .ready
      if lhsReady != rhsReady { return lhsReady }
      if lhs.title != rhs.title { return lhs.title < rhs.title }
      return lhs.agent.rawValue < rhs.agent.rawValue
    }
  }

  /// The live activity of a target session; nil when it ended.
  static func activity(
    of surfaceID: UUID,
    agent: SkillAgent,
    in presence: AgentPresenceFeature.State
  ) -> AgentPresenceFeature.Activity? {
    presence.records[AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: surfaceID)]?.activity
  }
}

/// A submitted Prompt Edit, queued until its session is ready.
struct PromptEditRequest: Equatable, Identifiable, Sendable {
  let id: UUID
  let worktreeID: Worktree.ID
  /// The editor the request came from; receives the status.
  let editorContentID: ContentID
  let surfaceID: UUID
  let agent: SkillAgent
  /// The single-line instruction the agent receives.
  let payload: String
  /// Release-safe log summary (no prompt text): "<path> lines a-b".
  let logSummary: String
  let focusesAgent: Bool
}

/// Releases queued requests whose sessions settled.
enum PromptEditQueue {
  struct Drain: Equatable {
    var ready: [PromptEditRequest] = []
    var dropped: [PromptEditRequest] = []
  }

  /// Removes and returns the requests that are now ready or whose session is
  /// gone; waiting ones stay queued in order.
  static func drain(
    _ pending: inout IdentifiedArrayOf<PromptEditRequest>,
    readiness: (PromptEditRequest) -> PromptEditReadiness
  ) -> Drain {
    var drain = Drain()
    for request in pending {
      switch readiness(request) {
      case .ready:
        drain.ready.append(request)
        pending.remove(id: request.id)
      case .gone:
        drain.dropped.append(request)
        pending.remove(id: request.id)
      case .wait:
        continue
      }
    }
    return drain
  }
}
