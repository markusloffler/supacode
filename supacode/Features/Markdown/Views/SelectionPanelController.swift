import AppKit
import SupacodeSettingsShared
import SwiftUI

/// Floats a panel next to a text view's selection once the user finishes
/// selecting (mouse released, keyboard idle), and removes it when the
/// selection collapses or moves. The panel is a child window, so it can
/// extend past the editor pane; it follows scrolling and resizes, and takes
/// the keyboard when it has a prompt field.
@MainActor
final class SelectionPanelController {
  private static let logger = SupaLogger("SelectionPanel")
  /// How long a selection must stay put before the panel appears.
  private static let settleDelay: TimeInterval = 0.25
  private static let gap: CGFloat = 6

  /// The text view whose selection is tracked.
  var textView: () -> NSTextView? = { nil }
  /// The panel for `range`.
  var makeContent: (_ range: NSRange) -> SelectionPanelContent? = { _ in nil }

  private var window: SelectionPanelWindow?
  /// Reports the text view leaving its window or being hidden.
  private var anchor: SelectionAnchorView?
  private var range: NSRange?
  private var placesAbove = true
  private var selectionObserver: (any NSObjectProtocol)?
  private var layoutObservers: [any NSObjectProtocol] = []
  private var pending: DispatchWorkItem?

  nonisolated init() {}

  nonisolated deinit {}

  func start() {
    guard selectionObserver == nil else { return }
    selectionObserver = NotificationCenter.default.addObserver(
      forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let sender = (notification.object as AnyObject?).map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        self?.selectionChanged(in: sender)
      }
    }
  }

  func stop() {
    if let selectionObserver {
      NotificationCenter.default.removeObserver(selectionObserver)
    }
    selectionObserver = nil
    pending?.cancel()
    pending = nil
    dismiss()
  }

  /// Shows the panel for `range` right away.
  func present(range: NSRange) {
    pending?.cancel()
    dismiss()
    guard
      let textView = textView(), let parent = textView.window, range.length > 0,
      let content = makeContent(range)
    else { return }
    let window = SelectionPanelWindow(content: content.view)
    window.onSizeChange = { [weak self] in self?.layout() }
    self.window = window
    self.range = range
    let anchor = SelectionAnchorView()
    anchor.onDetach = { [weak self] in self?.dismiss() }
    textView.addSubview(anchor)
    self.anchor = anchor
    observeLayout(of: textView)
    placesAbove = Self.fitsAbove(window.contentSize, selection: Self.screenRect(of: range, in: textView))
    layout()
    parent.addChildWindow(window, ordered: .above)
    if content.wantsKeyboard {
      window.makeKey()
    }
    Self.logger.debug("Presented selection panel for range \(range.location)+\(range.length)")
  }

  func dismiss() {
    for observer in layoutObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    layoutObservers = []
    anchor?.onDetach = nil
    anchor?.removeFromSuperview()
    anchor = nil
    if let window {
      window.parent?.removeChildWindow(window)
      window.orderOut(nil)
    }
    window = nil
    range = nil
  }

  /// Dismisses the panel and hands the keyboard back to the text view.
  func dismissAndRefocus() {
    dismiss()
    guard let textView = textView(), let window = textView.window else { return }
    window.makeKey()
    window.makeFirstResponder(textView)
  }

  private func selectionChanged(in sender: ObjectIdentifier?) {
    guard let textView = textView(), sender == ObjectIdentifier(textView) else { return }
    pending?.cancel()
    pending = nil
    let selected = textView.selectedRange()
    if let range, range != selected {
      dismiss()
    }
    guard selected.length > 0, window == nil else { return }
    schedulePresentation()
  }

  /// Waits for the selection to settle; a drag in progress postpones it.
  private func schedulePresentation() {
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let textView = self.textView() else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
          self.schedulePresentation()
          return
        }
        let selected = textView.selectedRange()
        guard selected.length > 0, textView.window?.firstResponder === textView else { return }
        self.present(range: selected)
      }
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
  }

  /// Follows the selection while the editor scrolls or its pane resizes.
  private func observeLayout(of textView: NSTextView) {
    guard let scrollView = textView.enclosingScrollView else { return }
    let center = NotificationCenter.default
    let relayout: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated { self?.layout() }
    }
    layoutObservers = [
      center.addObserver(
        forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main, using: relayout),
      center.addObserver(
        forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main, using: relayout),
    ]
  }

  /// Above the selection when it fits, else below; always on screen. Closes
  /// once the selection scrolls out of the editor's viewport.
  private func layout() {
    guard let window, let range, let textView = textView() else { return }
    guard textView.visibleRect.intersects(Self.viewRect(of: range, in: textView)) else {
      dismiss()
      return
    }
    let size = window.contentSize
    let selection = Self.screenRect(of: range, in: textView)
    let screen = (textView.window?.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
    let preferredY = placesAbove ? selection.maxY + Self.gap : selection.minY - Self.gap - size.height
    let y = min(max(preferredY, screen.minY), screen.maxY - size.height)
    let x = min(max(selection.minX, screen.minX), screen.maxX - size.width)
    window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
  }

  private static func fitsAbove(_ size: NSSize, selection: NSRect) -> Bool {
    let screen = NSScreen.screens.first { $0.frame.intersects(selection) }?.visibleFrame ?? .infinite
    return selection.maxY + gap + size.height <= screen.maxY
  }

  /// The bounding rect of the selection's first and last character, in screen
  /// coordinates.
  private static func screenRect(of range: NSRange, in textView: NSTextView) -> NSRect {
    let ends = [
      NSRange(location: range.location, length: 1),
      NSRange(location: NSMaxRange(range) - 1, length: 1),
    ]
    let rects = ends.compactMap { end -> NSRect? in
      var actual = NSRange()
      let rect = textView.firstRect(forCharacterRange: end, actualRange: &actual)
      return rect.isEmpty ? nil : rect
    }
    guard let first = rects.first else {
      return textView.window?.convertToScreen(textView.convert(textView.visibleRect, to: nil)) ?? .zero
    }
    return rects.dropFirst().reduce(first) { $0.union($1) }
  }

  /// `screenRect(of:in:)` in the text view's own coordinates.
  private static func viewRect(of range: NSRange, in textView: NSTextView) -> NSRect {
    guard let window = textView.window else { return .zero }
    return textView.convert(window.convertFromScreen(screenRect(of: range, in: textView)), from: nil)
  }
}

/// What the selection panel shows, and whether it takes the keyboard (its
/// prompt field is focused on appear).
struct SelectionPanelContent {
  let view: AnyView
  let wantsKeyboard: Bool
}
