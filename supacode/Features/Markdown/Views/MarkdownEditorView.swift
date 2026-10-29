import AppKit
import MarkdownEngine
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Hosts the editor as a tab renderer and fulfills focus requests once the
/// engine's text view is in a window.
final class MarkdownHostingView: NSHostingView<MarkdownEditorView> {
  private weak var model: MarkdownEditorModel?

  init(model: MarkdownEditorModel) {
    self.model = model
    super.init(rootView: MarkdownEditorView(model: model, document: model.document))
    // The pane sizes the renderer; never let SwiftUI push back.
    sizingOptions = []
    model.hostView = self
  }

  @available(*, unavailable)
  required init(rootView: MarkdownEditorView) {
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

/// The Markdown editor: in-place styled text (markers hidden, revealed at the
/// caret) with disk-conflict and Prompt Edit status bars above it. Read mode
/// shows a non-editable copy with soft line breaks joined.
struct MarkdownEditorView: View {
  let model: MarkdownEditorModel
  @Bindable var document: MarkdownDocument
  @Shared(.markdownEditModeAppearance) private var editModeAppearance: MarkdownEditorAppearance
  @Shared(.markdownReadModeAppearance) private var readModeAppearance: MarkdownEditorAppearance
  @Shared(.markdownEditorTheme) private var themeChoice: MarkdownEditorThemeChoice

  var body: some View {
    let style = MarkdownEditorStyle.resolve(themeChoice)
    return VStack(spacing: 0) {
      MarkdownDocumentBanner(document: document)
      MarkdownPromptEditStatusBar(model: model)
      if let loadError = document.loadError {
        ContentUnavailableView {
          Label("Cannot Open \(model.fileName)", systemImage: "doc.questionmark")
        } description: {
          Text(loadError)
        }
      } else {
        NativeTextViewWrapper(
          text: editorText,
          configuration: style.configuration,
          fontName: style.fontName,
          fontSize: style.fontSize,
          documentId: model.contentID.rawValue.uuidString,
          isEditable: !model.isReadMode,
          isFocused: Binding(
            get: { model.isEditorFocused },
            set: { model.editorFocusChanged($0) }
          ),
          onBuildContextMenu: { menu, range in
            model.promptEdit.buildContextMenu(menu, selection: range)
          }
        )
        // Some settings (the reading column) only apply when the view is built.
        .id(themeChoice)
        .overlay(alignment: .topTrailing) {
          MarkdownModeToggle(model: model)
        }
      }
    }
    .background(Color(nsColor: style.background))
    // AppKit appearance, not SwiftUI's color scheme: the engine's text view
    // resolves its system colors from it.
    .onChange(of: appearance, initial: true) { _, appearance in
      model.hostView?.appearance = appearance.nsAppearance
    }
  }

  private var appearance: MarkdownEditorAppearance {
    model.isReadMode ? readModeAppearance : editModeAppearance
  }

  /// The source in edit mode; in read mode a same-length copy with soft
  /// breaks joined, so selections still map 1:1 onto the file.
  private var editorText: Binding<String> {
    guard model.isReadMode else { return $document.text }
    return .constant(MarkdownSoftBreaks.joined(document.text))
  }
}

/// Switches between read and edit mode.
private struct MarkdownModeToggle: View {
  let model: MarkdownEditorModel

  var body: some View {
    Button {
      model.toggleReadMode()
    } label: {
      Image(systemName: model.isReadMode ? "pencil" : "book")
        .accessibilityLabel(model.isReadMode ? "Edit Mode" : "Read Mode")
    }
    .buttonStyle(.borderless)
    .padding(6)
    .background(.regularMaterial, in: .circle)
    .padding(8)
    .help(helpText)
  }

  private var helpText: String {
    let title = model.isReadMode ? "Switch to edit mode" : "Switch to read mode"
    guard let shortcut = model.readModeShortcutDisplay else { return title }
    return "\(title) (\(shortcut))"
  }
}

/// Disk-side problems that need a decision: an external change over unsaved
/// edits, a deleted file, or a failed save.
private struct MarkdownDocumentBanner: View {
  let document: MarkdownDocument

  private static let logger = SupaLogger("MarkdownEditor")

  var body: some View {
    if let issue = document.diskIssue {
      switch issue {
      case .changedOnDisk:
        bar("File changed on disk.", systemImage: "exclamationmark.triangle") {
          Button("Reload") {
            Self.logger.info("[USER] Reloaded \(document.fileURL.lastPathComponent) from disk over local edits")
            document.reloadFromDisk()
          }
          .help("Discard your edits and load the version on disk.")
          Button("Keep Mine") {
            Self.logger.info("[USER] Kept local edits over disk for \(document.fileURL.lastPathComponent)")
            document.keepBufferOverDisk()
          }
          .help("Overwrite the file on disk with your edits.")
        }
      case .deleted:
        bar("File was deleted on disk.", systemImage: "trash") {
          Button("Recreate File") {
            Self.logger.info("[USER] Recreated deleted file \(document.fileURL.lastPathComponent)")
            document.save()
          }
          .help("Save the editor's content to recreate the file.")
        }
      }
    } else if let saveError = document.saveError {
      bar("Could not save: \(saveError)", systemImage: "exclamationmark.octagon") {
        Button("Retry") {
          Self.logger.info("[USER] Retried saving \(document.fileURL.lastPathComponent)")
          document.save()
        }
        .help("Try saving the file again (⌘S).")
      }
    }
  }

  private func bar(
    _ message: String,
    systemImage: String,
    @ViewBuilder actions: () -> some View
  ) -> some View {
    StatusBar(message: message, systemImage: systemImage, actions: actions)
  }
}

/// The editor's latest Prompt Edit: queued (cancellable), sent, or failed.
private struct MarkdownPromptEditStatusBar: View {
  let model: MarkdownEditorModel

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

/// A thin message row docked above the editor.
private struct StatusBar<Actions: View>: View {
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

extension MarkdownEditorAppearance {
  /// Nil follows the window, i.e. the app's appearance.
  fileprivate var nsAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}
