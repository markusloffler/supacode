import AppKit
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Hosts the code editor as a tab renderer and fulfills focus requests once
/// the text view is in a window.
final class CodeEditorHostingView: NSHostingView<CodeEditorView> {
  private weak var model: CodeEditorModel?

  init(model: CodeEditorModel) {
    self.model = model
    super.init(rootView: CodeEditorView(model: model, document: model.document))
    // The pane sizes the renderer; never let SwiftUI push back.
    sizingOptions = []
    model.hostView = self
  }

  @available(*, unavailable)
  required init(rootView: CodeEditorView) {
    fatalError("init(rootView:) is unavailable")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  nonisolated deinit {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    // SwiftUI builds the text view on its next layout pass.
    DispatchQueue.main.async { [weak self] in
      self?.model?.fulfillPendingFocus()
    }
  }
}

/// The text/code editor: a monospaced, syntax-coloured text view with the
/// Markdown editor's disk-conflict and Prompt Edit status bars above it.
struct CodeEditorView: View {
  let model: CodeEditorModel
  let document: MarkdownDocument
  @Shared(.codeEditorSoftWrap) private var softWrap: Bool
  @Shared(.markdownEditModeAppearance) private var appearance: MarkdownEditorAppearance

  var body: some View {
    VStack(spacing: 0) {
      MarkdownDocumentBanner(document: document)
      PromptEditStatusBar(model: model)
      if let loadError = document.loadError {
        ContentUnavailableView {
          Label("Cannot Open \(model.fileName)", systemImage: "doc.questionmark")
        } description: {
          Text(loadError)
        }
      } else {
        CodeTextView(model: model, reloadGeneration: document.reloadGeneration, softWrap: softWrap)
          .overlay(alignment: .topTrailing) {
            CodeSoftWrapToggle(isOn: Binding($softWrap), fileName: model.fileName)
          }
      }
    }
    // AppKit appearance: the text view and the highlight theme resolve from it.
    .onChange(of: appearance, initial: true) { _, appearance in
      model.hostView?.appearance = appearance.nsAppearance
    }
  }
}

/// Switches long lines between wrapping and horizontal scrolling.
private struct CodeSoftWrapToggle: View {
  @Binding var isOn: Bool
  let fileName: String

  private static let logger = SupaLogger("CodeEditor")

  var body: some View {
    Button {
      isOn.toggle()
      Self.logger.info("[USER] Turned soft wrap \(isOn ? "on" : "off") in \(fileName)")
    } label: {
      Image(systemName: isOn ? "arrow.left.and.right.text.vertical" : "arrow.turn.down.left")
        .accessibilityLabel(isOn ? "Disable Soft Wrap" : "Enable Soft Wrap")
    }
    .buttonStyle(.borderless)
    .padding(6)
    .background(.regularMaterial, in: .circle)
    .padding(8)
    .help(isOn ? "Scroll long lines horizontally instead of wrapping" : "Wrap long lines at the pane edge")
  }
}
