import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared

/// Markdown editor intents routed through `AppFeature`.
enum MarkdownAction: Equatable {
  /// Open a file in the worktree's editor pane (explorer double-click, or the
  /// explicit "Open in Supacode Editor" menu entry).
  case openInEditor(URL)
  case promptEditSubmitted(PromptEditRequest)
  case promptEditCancelled(UUID)
  /// The editor took input focus; pane focus follows it, like a terminal.
  case editorFocused(ContentID, worktreeID: Worktree.ID)
}

/// Markdown editor bookkeeping on `AppFeature.State`.
struct MarkdownAppState: Equatable {
  /// Prompt Edits waiting for their agent's turn to end, oldest first.
  var pendingPromptEdits: IdentifiedArrayOf<PromptEditRequest> = []
  /// The terminal surface last focused per worktree: the default Prompt Edit
  /// target.
  var lastFocusedSurfaceByWorktree: [Worktree.ID: UUID] = [:]
}

extension AppFeature.State {
  /// Agent sessions in the worktree a Prompt Edit can go to.
  func promptEditTargets(in worktreeID: Worktree.ID) -> [PromptEditTarget] {
    guard let layout = terminals.layouts[id: worktreeID]?.layout else { return [] }
    return PromptEditTargeting.targets(
      in: layout,
      presence: agentPresence,
      lastFocusedSurfaceID: markdown.lastFocusedSurfaceByWorktree[worktreeID],
      title: { TabTitle.resolved(for: $0, runtime: ContentRuntime.liveValue) }
    )
  }
}

/// Opens files in editor panes and runs the Prompt Edit queue. Composed next
/// to `AppFeature`'s core so the upstream reducer only forwards to it.
struct MarkdownAppReducer: Reducer {
  typealias State = AppFeature.State
  typealias Action = AppFeature.Action

  private static let logger = SupaLogger("MarkdownEditor")

  @Dependency(ContentRuntime.self) private var contentRuntime
  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(\.continuousClock) private var clock
  @Dependency(\.uuid) private var uuid

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .markdown(.openInEditor(let fileURL)):
        return openInEditor(fileURL, state: &state)
      case .markdown(.promptEditSubmitted(let request)):
        return submit(request, state: &state)
      case .markdown(.promptEditCancelled(let requestID)):
        guard let request = state.markdown.pendingPromptEdits.remove(id: requestID) else { return .none }
        return status(nil, for: request)
      case .markdown(.editorFocused(let contentID, let worktreeID)):
        guard let layout = state.terminals.layouts[id: worktreeID]?.layout,
          let located = layout.tab(containingContent: contentID),
          located.pane.id != layout.focusedPaneID
        else { return .none }
        return .send(.terminals(.layouts(.element(id: worktreeID, action: .contentRequestedFocus(content: contentID)))))
      case .agentPresence(.delegate(.surfacesChanged(let surfaces))):
        return drainQueue(touching: surfaces, sessionsEnded: false, state: &state)
      case .terminalEvent(.focusChanged(let worktreeID, let surfaceID)):
        state.markdown.lastFocusedSurfaceByWorktree[worktreeID] = surfaceID
        return .none
      case .terminalEvent(.surfacesClosed(_, let ids)):
        // Presence drops the records too, but a session without hooks never had
        // one; drop its queued requests here.
        return drainQueue(touching: ids, sessionsEnded: true, state: &state)
      default:
        return .none
      }
    }
  }

  // MARK: - Open.

  private func openInEditor(_ fileURL: URL, state: inout State) -> Effect<Action> {
    guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID),
      worktree.host == nil
    else {
      Self.logger.warning("openInEditor: no local worktree selected for \(fileURL.lastPathComponent)")
      return .none
    }
    guard let relativePath = MarkdownOpenRouter.relativePath(of: fileURL, under: worktree.workingDirectory) else {
      Self.logger.warning("openInEditor: \(fileURL.path(percentEncoded: false)) is outside the worktree")
      return .none
    }
    Self.logger.info("[USER] Opened markdown file in editor: \(relativePath)")
    let layoutState = state.terminals.layouts[id: worktree.id]
    let layout = layoutState?.layout ?? PaneLayout()
    let route = MarkdownOpenRouter.route(
      relativePath: relativePath,
      in: layout,
      windowedPaneIDs: layoutState?.windowedPaneIDs ?? [],
      newPaneID: PaneID(rawValue: uuid())
    )
    let content = MarkdownContentState(relativePath: relativePath)
    let focusedContentID = layout.focusedPaneID.flatMap { layout.panes[id: $0]?.selectedTab?.content.id }
    let spec = NewTabSpec(
      title: content.fileName,
      icon: "doc.text",
      content: .markdown(content),
      geometry: contentRuntime.spawnGeometry(near: focusedContentID)
    )
    let layoutAction: LayoutFeature.Action
    var focusExisting: ContentID?
    switch route {
    case .selectTab(let tabID):
      layoutAction = .selectTab(id: tabID)
      focusExisting = layout.pane(containingTab: tabID)?.tabs[id: tabID]?.content.id
    case .newTab(let paneID):
      layoutAction = .newTab(inPane: paneID, spec: spec)
    case .split(let anchor):
      layoutAction = .splitPane(id: anchor, direction: .right, spec: spec)
    }
    var effects: [Effect<Action>] = []
    if layoutState == nil {
      effects.append(.send(.terminals(.attachLayout(worktreeID: worktree.id, titlePrefix: worktree.name))))
    }
    effects.append(.send(.terminals(.layouts(.element(id: worktree.id, action: layoutAction)))))
    if let focusExisting {
      effects.append(
        .run { @MainActor [contentRuntime] _ in
          MarkdownContent.focusEditor(focusExisting, runtime: contentRuntime)
        }
      )
    }
    return .concatenate(effects)
  }

  // MARK: - Prompt Edit.

  private func readiness(of request: PromptEditRequest, in state: State) -> PromptEditReadiness {
    PromptEditReadiness.of(
      PromptEditTargeting.activity(of: request.surfaceID, agent: request.agent, in: state.agentPresence)
    )
  }

  private func submit(_ request: PromptEditRequest, state: inout State) -> Effect<Action> {
    switch readiness(of: request, in: state) {
    case .ready:
      return inject(request, state: state)
    case .wait:
      Self.logger.info("Prompt edit queued until \(request.agent.rawValue) is ready: \(request.logSummary)")
      // One queued edit per editor: a newer one replaces it.
      let superseded = state.markdown.pendingPromptEdits.filter { $0.editorContentID == request.editorContentID }
      for old in superseded {
        state.markdown.pendingPromptEdits.remove(id: old.id)
      }
      state.markdown.pendingPromptEdits.append(request)
      return status(.queued(requestID: request.id, agent: request.agent), for: request)
    case .gone:
      Self.logger.warning("Prompt edit dropped, \(request.agent.rawValue) session ended: \(request.logSummary)")
      return status(.failed("The \(request.agent.displayName) session has ended."), for: request)
    }
  }

  /// Sends or drops queued requests on the given surfaces; `sessionsEnded`
  /// drops them outright (their terminals closed).
  private func drainQueue(touching surfaces: Set<UUID>, sessionsEnded: Bool, state: inout State) -> Effect<Action> {
    guard state.markdown.pendingPromptEdits.contains(where: { surfaces.contains($0.surfaceID) }) else {
      return .none
    }
    let snapshot = state
    let drain = PromptEditQueue.drain(&state.markdown.pendingPromptEdits) { request in
      guard surfaces.contains(request.surfaceID) else { return .wait }
      return sessionsEnded ? .gone : readiness(of: request, in: snapshot)
    }
    var effects = drain.ready.map { inject($0, state: snapshot) }
    for dropped in drain.dropped {
      Self.logger.warning("Queued prompt edit dropped, \(dropped.agent.rawValue) session ended: \(dropped.logSummary)")
      let message = "The \(dropped.agent.displayName) session ended before the edit was sent."
      effects.append(status(.failed(message), for: dropped))
    }
    return .merge(effects)
  }

  /// Pastes the payload into the agent's terminal and submits it with a
  /// separate Return. A surface without a live renderer goes through the
  /// focusing path, which wakes it.
  private func inject(_ request: PromptEditRequest, state: State) -> Effect<Action> {
    let surfaceContentID = ContentID(rawValue: request.surfaceID)
    let worktree = state.repositories.worktree(for: request.worktreeID)
    let tabID = state.terminals.layouts[id: request.worktreeID]?.layout
      .tab(containingContent: surfaceContentID)?.tab.id
    Self.logger.info("[USER] Prompt edit sent: \(request.agent.rawValue) \(request.logSummary)")
    return .run { @MainActor [contentRuntime, terminalClient, clock] _ in
      if let surface = contentRuntime.renderer(for: surfaceContentID) as? GhosttySurfaceView {
        TerminalInjector.paste(request.payload, into: surface)
        try? await clock.sleep(for: TerminalInjector.submitDelay)
        TerminalInjector.submit(surface)
        if request.focusesAgent, let worktree, let tabID {
          terminalClient.send(.focusSurface(worktree, tabID: tabID, surfaceID: request.surfaceID))
        }
      } else if let worktree, let tabID {
        terminalClient.send(
          .focusSurface(worktree, tabID: tabID, surfaceID: request.surfaceID, input: request.payload + "\r"))
      } else {
        Self.logger.warning("Prompt edit target surface vanished: \(request.logSummary)")
        MarkdownContent.setPromptEditStatus(
          .failed("The agent's terminal is gone."), for: request.editorContentID, runtime: contentRuntime)
        return
      }
      MarkdownContent.setPromptEditStatus(
        .sent(agent: request.agent), for: request.editorContentID, runtime: contentRuntime)
    }
  }

  private func status(_ status: PromptEditStatus?, for request: PromptEditRequest) -> Effect<Action> {
    .run { @MainActor [contentRuntime] _ in
      MarkdownContent.setPromptEditStatus(status, for: request.editorContentID, runtime: contentRuntime)
    }
  }
}
