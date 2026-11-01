import AppKit
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Renderer of a diff-switchable tab: the wrapped editor, or its diff.
final class DiffSwitchHostingView: NSHostingView<DiffSwitchView> {
  private let onClick: () -> Void
  /// Watches clicks inside the tab without consuming them, so the pane takes
  /// focus (and drops its unfocused dim) in every mode, text selection intact.
  private var clickMonitor: Any?

  init(rootView: DiffSwitchView, onClick: @escaping () -> Void) {
    self.onClick = onClick
    super.init(rootView: rootView)
    // The pane sizes the renderer; never let SwiftUI push back.
    sizingOptions = []
  }

  @available(*, unavailable)
  required init(rootView: DiffSwitchView) {
    fatalError("init(rootView:) is unavailable")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  nonisolated deinit {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let clickMonitor {
      NSEvent.removeMonitor(clickMonitor)
      self.clickMonitor = nil
    }
    guard window != nil else { return }
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, event.window === self.window,
          self.bounds.contains(self.convert(event.locationInWindow, from: nil))
        else { return }
        self.onClick()
      }
      return event
    }
  }
}

/// Shows the editor, or the diff while diff mode is on.
struct DiffSwitchView: View {
  /// The wrapped content's renderer; nil when it failed to start.
  let editor: NSView?
  let diffModel: DiffViewerModel
  @Shared(.editorDiffMode) private var diffMode: Bool
  @Shared(.markdownEditModeAppearance) private var appearance: MarkdownEditorAppearance
  @Environment(\.colorScheme) private var systemScheme

  var body: some View {
    Group {
      if diffMode {
        DiffViewerView(model: diffModel, sideBySide: diffModel.sideBySide)
          // Match the editors' light / dark override.
          .environment(\.colorScheme, colorScheme(for: appearance))
      } else if let editor {
        HostedRendererView(view: editor)
      } else {
        Color.clear
      }
    }
  }

  private func colorScheme(for appearance: MarkdownEditorAppearance) -> ColorScheme {
    switch appearance {
    case .system: systemScheme
    case .light: .light
    case .dark: .dark
    }
  }
}

/// Embeds an existing AppKit renderer; the same instance comes back when the
/// diff is switched off again, so the editor keeps its state.
private struct HostedRendererView: NSViewRepresentable {
  let view: NSView

  func makeNSView(context: Context) -> NSView {
    view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
