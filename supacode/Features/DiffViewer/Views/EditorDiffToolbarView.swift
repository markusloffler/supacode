import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The docked bar of an editor or viewer tab: the file path and the diff mode
/// toggle; in diff mode also the change counts, navigation and layout switch.
struct EditorDiffToolbarView: View {
  let model: DiffViewerModel
  @Shared(.editorDiffMode) private var diffMode: Bool

  private static let logger = SupaLogger("DiffViewer")

  var body: some View {
    HStack(spacing: 10) {
      if diffMode, case .loaded(let document) = model.phase {
        diffSummary(document)
        Spacer(minLength: 0)
        diffControls
      } else {
        Text(model.relativePath)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      Toggle(isOn: diffModeBinding) {
        Label("Changes", systemImage: "plus.forwardslash.minus")
      }
      .toggleStyle(.button)
      .help(
        diffMode
          ? "Show the file instead of its changes"
          : "Show the uncommitted changes against HEAD, for every file you open until turned off")
    }
    .buttonStyle(.borderless)
    .font(.callout.monospacedDigit())
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func diffSummary(_ document: DiffViewerModel.Document) -> some View {
    HStack(spacing: 10) {
      Text("+\(document.diff.addedCount)")
        .foregroundStyle(.green)
      Text("−\(document.diff.removedCount)")
        .foregroundStyle(.red)
      Text(summary(document))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var diffControls: some View {
    let hasChanges = !model.hunkStarts().isEmpty
    return HStack(spacing: 10) {
      Button {
        model.step(-1)
      } label: {
        Image(systemName: "chevron.up")
          .accessibilityLabel("Previous Change")
      }
      .help("Scroll to the previous change")
      .disabled(!hasChanges)
      Button {
        model.step(1)
      } label: {
        Image(systemName: "chevron.down")
          .accessibilityLabel("Next Change")
      }
      .help("Scroll to the next change")
      .disabled(!hasChanges)
      Button {
        Self.logger.info("[USER] Reloaded diff of \(model.relativePath)")
        model.reload()
      } label: {
        Image(systemName: "arrow.clockwise")
          .accessibilityLabel("Reload")
      }
      .help("Reload the diff, e.g. after a commit")
      Button {
        model.toggleLayout()
      } label: {
        Image(systemName: model.sideBySide ? "rectangle" : "rectangle.split.2x1")
          .accessibilityLabel(model.sideBySide ? "Unified" : "Side by Side")
      }
      .help(
        model.sideBySide
          ? "Show the changes in a single column" : "Show the committed and current version side by side")
    }
  }

  private func summary(_ document: DiffViewerModel.Document) -> String {
    let count = model.hunkStarts().count
    let changes = count == 1 ? "1 change" : "\(count) changes"
    if document.isNewFile { return "\(model.relativePath) · \(changes) · new file" }
    if document.isDeleted { return "\(model.relativePath) · \(changes) · deleted" }
    return "\(model.relativePath) · \(changes) against HEAD"
  }

  private var diffModeBinding: Binding<Bool> {
    Binding(
      get: { diffMode },
      set: { value in
        Self.logger.info("[USER] Turned diff mode \(value ? "on" : "off") in \(model.relativePath)")
        $diffMode.withLock { $0 = value }
      }
    )
  }
}
