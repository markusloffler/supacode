import AppKit
import SwiftUI

/// The borderless child window holding the selection panel. It becomes key
/// only when a view inside needs the keyboard (the prompt field), so clicking
/// its buttons leaves the text view focused.
final class SelectionPanelWindow: NSPanel {
  /// Called when the SwiftUI content grows or shrinks (e.g. a multi-line prompt).
  var onSizeChange: (() -> Void)? {
    get { hostingView.onSizeChange }
    set { hostingView.onSizeChange = newValue }
  }

  private let hostingView: SelectionPanelHostingView

  init(content: AnyView) {
    hostingView = SelectionPanelHostingView(rootView: content)
    super.init(
      contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    becomesKeyOnlyIfNeeded = true
    isReleasedWhenClosed = false
    contentView = hostingView
  }

  nonisolated deinit {}

  override var canBecomeKey: Bool { true }

  override var canBecomeMain: Bool { false }

  var contentSize: NSSize { hostingView.fittingSize }
}

/// Reports SwiftUI size changes so the window can be re-framed.
private final class SelectionPanelHostingView: NSHostingView<AnyView> {
  var onSizeChange: (() -> Void)?

  required init(rootView: AnyView) {
    super.init(rootView: rootView)
    sizingOptions = [.intrinsicContentSize]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  nonisolated deinit {}

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    DispatchQueue.main.async { [weak self] in
      self?.onSizeChange?()
      self?.window?.invalidateShadow()
    }
  }
}

/// A zero-size subview of the text view that reports when the editor leaves
/// its window or gets hidden (tab switch), so the panel closes with it.
final class SelectionAnchorView: NSView {
  var onDetach: (() -> Void)?

  nonisolated deinit {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { onDetach?() }
  }

  override func viewDidHide() {
    super.viewDidHide()
    onDetach?()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
