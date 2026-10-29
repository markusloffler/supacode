import AppKit
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The editor's "Prompt Edit…" context-menu entry and the popover it opens.
@MainActor
final class PromptEditController {
  private static let logger = SupaLogger("PromptEdit")

  weak var model: MarkdownEditorModel?
  private var popover: NSPopover?

  nonisolated init() {}

  nonisolated deinit {}

  /// Prepends "Prompt Edit…" to the engine's context menu. Disabled, with the
  /// reason as tooltip, when nothing is selected or no agent session runs.
  func buildContextMenu(_ menu: NSMenu, selection range: NSRange) -> NSMenu {
    let item = NSMenuItem(title: "Prompt Edit…", action: nil, keyEquivalent: "")
    item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
    let targets = model?.promptEditTargets() ?? []
    if range.length == 0 {
      item.toolTip = "Select text to describe a change for a coding agent."
    } else if targets.isEmpty {
      item.toolTip = "No coding agent session is running in this worktree."
    } else {
      let handler = MenuActionHandler { [weak self] in
        self?.present(range: range, targets: targets)
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

  func dismiss() {
    popover?.close()
    popover = nil
  }

  private func present(range: NSRange, targets: [PromptEditTarget]) {
    guard let model, let textView = model.textView else { return }
    guard
      let selection = PromptEditPayload.selection(
        in: model.document.text, range: range, relativePath: model.relativePath)
    else { return }
    Self.logger.info("[USER] Opened prompt edit for \(model.relativePath) lines \(selection.lines)")
    dismiss()
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = NSHostingController(
      rootView: PromptEditPopoverView(
        selection: selection,
        targets: targets,
        onSubmit: { [weak self] instruction, target, focusesAgent in
          self?.submit(selection: selection, instruction: instruction, target: target, focusesAgent: focusesAgent)
        },
        onCancel: { [weak self] in
          Self.logger.info("[USER] Cancelled prompt edit popover")
          self?.dismiss()
        }
      )
    )
    popover.show(relativeTo: Self.anchorRect(for: range, in: textView), of: textView, preferredEdge: .maxY)
    self.popover = popover
  }

  private func submit(
    selection: PromptEditSelection,
    instruction: String,
    target: PromptEditTarget,
    focusesAgent: Bool
  ) {
    dismiss()
    guard let model else { return }
    // The agent must read what the user sees.
    model.document.save()
    let lines = "\(selection.lines.lowerBound)-\(selection.lines.upperBound)"
    let request = PromptEditRequest(
      id: UUID(),
      worktreeID: model.worktreeID,
      editorContentID: model.contentID,
      surfaceID: target.surfaceID,
      agent: target.agent,
      payload: PromptEditPayload.format(selection, instruction: instruction),
      logSummary: "\(selection.relativePath) lines \(lines)",
      focusesAgent: focusesAgent
    )
    Self.logger.info("[USER] Submitted prompt edit to \(target.agent.rawValue): \(request.logSummary)")
    model.send(.promptEditSubmitted(request))
  }

  /// The selection's first line rect in the text view's coordinates.
  private static func anchorRect(for range: NSRange, in textView: NSTextView) -> NSRect {
    var actual = NSRange()
    let screenRect = textView.firstRect(forCharacterRange: range, actualRange: &actual)
    guard let window = textView.window, !screenRect.isEmpty else {
      return textView.visibleRect
    }
    return textView.convert(window.convertFromScreen(screenRect), from: nil)
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

/// The instruction field shown next to the selection.
struct PromptEditPopoverView: View {
  let selection: PromptEditSelection
  let targets: [PromptEditTarget]
  let onSubmit: (String, PromptEditTarget, Bool) -> Void
  let onCancel: () -> Void

  @State private var instruction = ""
  @State private var targetID: PromptEditTarget.ID?
  @Shared(.markdownPromptEditFocusesAgent) private var focusesAgent: Bool
  @FocusState private var isFieldFocused: Bool

  private var selectedTarget: PromptEditTarget? {
    targets.first { $0.id == targetID } ?? targets.first
  }

  private var canSubmit: Bool {
    selectedTarget != nil && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Prompt Edit")
          .font(.headline)
        Text(locationLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      TextField("Describe the change…", text: $instruction)
        .textFieldStyle(.roundedBorder)
        .focused($isFieldFocused)
        .onSubmit(submit)
      if targets.count > 1 {
        Picker("Agent", selection: $targetID) {
          ForEach(targets) { target in
            Text(Self.label(for: target)).tag(Optional(target.id))
          }
        }
        .help("The coding agent session that receives the instruction.")
      } else if let target = targets.first {
        Text("To \(Self.label(for: target))")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Toggle("Focus agent after sending", isOn: Binding($focusesAgent))
        .help("Switch to the agent's terminal once the instruction is sent.")
      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
          .help("Close without sending (Esc)")
        Button("Send", action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(!canSubmit)
          .help("Send the instruction to the agent session (Return)")
      }
    }
    .padding()
    .frame(width: 380)
    .onAppear {
      targetID = targets.first?.id
      isFieldFocused = true
    }
  }

  private var locationLabel: String {
    let lines =
      selection.lines.count == 1
      ? "line \(selection.lines.lowerBound)"
      : "lines \(selection.lines.lowerBound)–\(selection.lines.upperBound)"
    return "\(selection.relativePath) · \(lines)"
  }

  private func submit() {
    guard canSubmit, let selectedTarget else { return }
    onSubmit(instruction, selectedTarget, focusesAgent)
  }

  private static func label(for target: PromptEditTarget) -> String {
    let state =
      switch PromptEditReadiness.of(target.activity) {
      case .ready: ""
      case .wait: " (busy, will queue)"
      case .gone: " (ended)"
      }
    return "\(target.agent.displayName) — \(target.title)\(state)"
  }
}
