import AppKit
import SwiftUI

/// A file's uncommitted changes against HEAD. Counts, change navigation and
/// the layout switch live in the editor tab's toolbar (`EditorDiffToolbarView`).
struct DiffViewerView: View {
  let model: DiffViewerModel
  /// Passed in by `DiffSwitchView`, whose body reliably re-runs on a switch.
  let sideBySide: Bool
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      PromptEditStatusBar(model: model)
      switch model.phase {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ContentUnavailableView {
          Label("Cannot Show Changes", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        }
      case .loaded(let document) where !document.diff.hasChanges:
        ContentUnavailableView(
          "No Changes", systemImage: "checkmark.circle",
          description: Text("\(model.fileName) matches the committed version."))
      case .loaded(let document):
        DiffTextRepresentable(model: model, document: document, sideBySide: sideBySide, isDark: colorScheme == .dark)
      }
    }
    // The pane behind is the terminal's; draw the text background like the editors.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
    .onAppear { model.activate() }
    .onDisappear { model.deactivate() }
    .onChange(of: colorScheme, initial: true) { _, scheme in
      model.setDark(scheme == .dark)
    }
  }
}

/// Bridges the AppKit diff columns: selectable across lines, with Prompt Edit
/// on the selection like the editors.
private struct DiffTextRepresentable: NSViewRepresentable {
  let model: DiffViewerModel
  let document: DiffViewerModel.Document
  let sideBySide: Bool
  let isDark: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(model: model)
  }

  func makeNSView(context: Context) -> DiffTextPaneView {
    let pane = DiffTextPaneView()
    model.pane = pane
    return pane
  }

  func updateNSView(_ pane: DiffTextPaneView, context: Context) {
    // The text views draw in the editors' light / dark choice.
    pane.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    context.coordinator.show(document, sideBySide: sideBySide, in: pane)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    private let model: DiffViewerModel
    /// What the pane shows: the document's text identity and the layout.
    private var shown: (document: ObjectIdentifier, sideBySide: Bool)?

    init(model: DiffViewerModel) {
      self.model = model
    }

    nonisolated deinit {}

    func show(_ document: DiffViewerModel.Document, sideBySide: Bool, in pane: DiffTextPaneView) {
      let key = ObjectIdentifier(document.unified.text)
      guard shown?.document != key || shown?.sideBySide != sideBySide else { return }
      shown = (key, sideBySide)
      let columns = sideBySide ? [document.oldColumn, document.newColumn] : [document.unified]
      pane.show(columns) { [model] textView in
        textView.delegate = self
        textView.onFocus = { [weak model, weak textView] in model?.activeTextView = textView }
      }
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
      model.promptEdit.buildContextMenu(menu, selection: view.selectedRange())
    }
  }
}
