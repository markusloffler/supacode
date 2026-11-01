import AppKit
import SupacodeSettingsShared
import SwiftUI

/// Prompt Edit for an editor: the selection panel (cut/copy/paste plus the
/// instruction field) that appears on selection, and the "Prompt Edit…"
/// context-menu entry that opens it with the field focused.
@MainActor
final class PromptEditController {
  private static let logger = SupaLogger("PromptEdit")

  weak var host: (any PromptEditSource)?
  private let panel = SelectionPanelController()

  nonisolated init() {}

  nonisolated deinit {}

  func activate() {
    panel.textView = { [weak self] in self?.host?.textView }
    panel.makeContent = { [weak self] range in self?.panelContent(range: range) }
    panel.start()
  }

  func deactivate() {
    panel.stop()
  }

  /// Prepends "Prompt Edit…" to the editor's context menu. Disabled, with the
  /// reason as tooltip, when nothing is selected or no agent session runs.
  func buildContextMenu(_ menu: NSMenu, selection range: NSRange) -> NSMenu {
    let item = NSMenuItem(title: "Prompt Edit…", action: nil, keyEquivalent: "")
    item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
    let targets = host?.promptEditTargets() ?? []
    if range.length == 0 {
      item.toolTip = "Select text to describe a change for a coding agent."
    } else if targets.isEmpty {
      item.toolTip = "No coding agent session is running in this worktree."
    } else {
      let handler = MenuActionHandler { [weak self] in
        Self.logger.info("[USER] Chose Prompt Edit from the context menu")
        self?.panel.present(range: range)
      }
      item.target = handler
      item.action = #selector(MenuActionHandler.invoke)
      // `target` is weak; the represented object keeps the handler alive.
      item.representedObject = handler
      item.toolTip = "Ask a coding agent session in this worktree to edit the selection."
    }
    menu.insertItem(item, at: 0)
    menu.insertItem(.separator(), at: 1)
    return menu
  }

  private func panelContent(range: NSRange) -> SelectionPanelContent? {
    guard let host, let textView = host.textView else { return nil }
    let selection = host.promptEditSelection(for: range)
    let view = SelectionPanelView(
      selection: selection,
      targets: host.promptEditTargets(),
      isEditable: textView.isEditable,
      onCommand: { [weak self] command in self?.perform(command) },
      onSubmit: { [weak self] instruction, target, focusesAgent in
        guard let selection else { return }
        self?.submit(selection: selection, instruction: instruction, target: target, focusesAgent: focusesAgent)
      },
      onCancel: { [weak self] in
        Self.logger.info("[USER] Closed the selection panel")
        self?.panel.dismissAndRefocus()
      }
    )
    return SelectionPanelContent(view: AnyView(view), wantsKeyboard: view.showsPrompt)
  }

  private func perform(_ command: SelectionPanelView.Command) {
    guard let textView = host?.textView else { return }
    Self.logger.info("[USER] Tapped \(command.rawValue) in the selection panel")
    panel.dismissAndRefocus()
    switch command {
    case .cut: textView.cut(nil)
    case .copy: textView.copy(nil)
    case .paste: textView.paste(nil)
    }
  }

  private func submit(
    selection: PromptEditSelection,
    instruction: String,
    target: PromptEditTarget,
    focusesAgent: Bool
  ) {
    panel.dismissAndRefocus()
    guard let host else { return }
    host.prepareForPromptEdit()
    let diffNote = selection.diff == nil ? "" : " (diff)"
    let lines = "\(selection.lines.lowerBound)-\(selection.lines.upperBound)\(diffNote)"
    let request = PromptEditRequest(
      id: UUID(),
      worktreeID: host.worktreeID,
      editorContentID: host.contentID,
      surfaceID: target.surfaceID,
      agent: target.agent,
      payload: PromptEditPayload.format(selection, instruction: instruction),
      logSummary: "\(selection.relativePath) lines \(lines)",
      focusesAgent: focusesAgent
    )
    Self.logger.info("[USER] Submitted prompt edit to \(target.agent.rawValue): \(request.logSummary)")
    host.send(.promptEditSubmitted(request))
  }
}

/// Target-action bridge for a closure-backed menu item.
private final class MenuActionHandler: NSObject {
  private let action: () -> Void

  init(action: @escaping () -> Void) {
    self.action = action
  }

  nonisolated deinit {}

  @objc func invoke() {
    action()
  }
}
