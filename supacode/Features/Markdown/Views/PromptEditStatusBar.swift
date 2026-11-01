import SupacodeSettingsShared
import SwiftUI

/// The editor's latest Prompt Edit: queued (cancellable), sent, or failed.
struct PromptEditStatusBar: View {
  let model: any PromptEditHost

  var body: some View {
    Group {
      switch model.promptEditStatus {
      case .queued(_, let agent):
        StatusBar(
          message: "Prompt edit queued until \(agent.displayName) is ready.",
          systemImage: "clock",
          showsProgress: true
        ) {
          Button("Cancel") { model.cancelQueuedPromptEdit() }
            .help("Cancel the queued prompt edit.")
        }
      case .sent(let agent):
        StatusBar(message: "Prompt edit sent to \(agent.displayName).", systemImage: "checkmark.circle") {
          EmptyView()
        }
      case .failed(let message):
        StatusBar(message: message, systemImage: "exclamationmark.triangle") {
          Button("Dismiss") { model.dismissPromptEditStatus() }
            .help("Hide this message.")
        }
      case nil:
        EmptyView()
      }
    }
    .task(id: model.promptEditStatus) {
      guard case .sent = model.promptEditStatus else { return }
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      model.dismissPromptEditStatus()
    }
  }
}

/// A thin message row docked above an editor.
struct StatusBar<Actions: View>: View {
  let message: String
  let systemImage: String
  var showsProgress = false
  let actions: Actions

  init(
    message: String,
    systemImage: String,
    showsProgress: Bool = false,
    @ViewBuilder actions: () -> Actions
  ) {
    self.message = message
    self.systemImage = systemImage
    self.showsProgress = showsProgress
    self.actions = actions()
  }

  var body: some View {
    HStack(spacing: 8) {
      if showsProgress {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: systemImage)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      Text(message)
        .font(.callout)
        .lineLimit(2)
      Spacer(minLength: 8)
      actions
        .controlSize(.small)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}
