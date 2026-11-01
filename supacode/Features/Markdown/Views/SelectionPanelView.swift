import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The panel floating next to an editor selection: cut/copy/paste, and the
/// Prompt Edit instruction field when an agent session can take it.
struct SelectionPanelView: View {
  enum Command: String {
    case cut, copy, paste
  }

  let selection: PromptEditSelection?
  let targets: [PromptEditTarget]
  let isEditable: Bool
  let onCommand: (Command) -> Void
  let onSubmit: (String, PromptEditTarget, Bool) -> Void
  let onCancel: () -> Void

  @State private var instruction = ""
  @State private var targetID: PromptEditTarget.ID?
  @Shared(.markdownPromptEditFocusesAgent) private var focusesAgent: Bool
  @FocusState private var isFieldFocused: Bool

  private var selectedTarget: PromptEditTarget? {
    targets.first { $0.id == targetID } ?? targets.first
  }

  /// The instruction field, focused on appear; needs a selection and an agent.
  var showsPrompt: Bool {
    selection != nil && !targets.isEmpty
  }

  private var canSubmit: Bool {
    selectedTarget != nil && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        commandButton(.cut, title: "Cut", systemImage: "scissors", help: "Cut the selection (⌘X)")
          .disabled(!isEditable)
        commandButton(.copy, title: "Copy", systemImage: "doc.on.doc", help: "Copy the selection (⌘C)")
        commandButton(.paste, title: "Paste", systemImage: "doc.on.clipboard", help: "Replace the selection (⌘V)")
          .disabled(!isEditable)
        if let selection {
          Spacer(minLength: 16)
          Text(Self.locationLabel(of: selection))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      if showsPrompt {
        Divider()
        promptSection
      } else if selection != nil {
        Divider()
        Label("No agent running", systemImage: "sparkles")
          .font(.callout)
          .foregroundStyle(.secondary)
          .help(
            "Prompt Edit needs a coding agent session in this worktree. "
              + "Some agents (e.g. Copilot) only report their session after the first prompt."
          )
      }
    }
    .padding(14)
    .frame(width: showsPrompt ? 440 : nil)
    .background(.regularMaterial, in: .rect(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(.separator)
    }
    .onExitCommand(perform: onCancel)
    .onAppear {
      targetID = targets.first?.id
      isFieldFocused = showsPrompt
    }
  }

  @ViewBuilder private var promptSection: some View {
    // Return sends, ⌥Return breaks the line.
    TextField("Ask an agent to edit the selection…", text: $instruction, axis: .vertical)
      .lineLimit(2...8)
      .textFieldStyle(.plain)
      .padding(8)
      .background(.background.secondary, in: .rect(cornerRadius: 6))
      .focused($isFieldFocused)
      .onSubmit(submit)
    HStack(spacing: 12) {
      if targets.count > 1 {
        Picker("Agent", selection: $targetID) {
          ForEach(targets) { target in
            Text(Self.label(for: target)).tag(Optional(target.id))
          }
        }
        .labelsHidden()
        .help("The coding agent session that receives the instruction.")
      } else if let target = targets.first {
        Label(target.agent.displayName, systemImage: "sparkles")
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help("Sends to \(Self.label(for: target)).")
      }
      Spacer(minLength: 4)
      Toggle("Focus agent", isOn: Binding($focusesAgent))
        .help("Switch to the agent's terminal once the instruction is sent.")
      Button("Send", action: submit)
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
        .help("Send the instruction to the agent session (Return)")
    }
  }

  private func commandButton(_ command: Command, title: String, systemImage: String, help: String) -> some View {
    Button {
      onCommand(command)
    } label: {
      Label(title, systemImage: systemImage)
        .labelStyle(.iconOnly)
        .font(.title3)
        .frame(width: 28, height: 24)
    }
    .buttonStyle(.borderless)
    .help(help)
  }

  private func submit() {
    guard canSubmit, let selectedTarget else { return }
    onSubmit(instruction, selectedTarget, focusesAgent)
  }

  private static func locationLabel(of selection: PromptEditSelection) -> String {
    selection.lines.count == 1
      ? "Line \(selection.lines.lowerBound)"
      : "Lines \(selection.lines.lowerBound)–\(selection.lines.upperBound)"
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
