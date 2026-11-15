import AppKit
import SupacodeSettingsShared

/// Applies an `EditorSelection` (`supacode show`) to an editor's text view. A
/// freshly opened tab builds its text view over the next layout passes, so the
/// request waits until the view is in a window and shows the whole document,
/// retrying for a short while. A newer request supersedes a pending one.
@MainActor
final class EditorSelectionRevealer {
  private static let logger = SupaLogger("EditorSelection")
  private static let retryDelays: [Duration] = [
    .zero, .milliseconds(50), .milliseconds(150), .milliseconds(300), .milliseconds(600), .seconds(1), .seconds(2),
  ]
  /// The Markdown engine restyles over the next passes after a selection
  /// change, and its scroll view replays a saved offset for up to 1 s after a
  /// document arrives; re-reveal past both. A no-op while the range is visible.
  private static let settleDelays: [Duration] = [
    .zero, .milliseconds(100), .milliseconds(300), .milliseconds(700), .milliseconds(1200),
  ]

  /// The source text (the document), whose offsets the text view mirrors 1:1.
  private let text: () -> String
  private let textView: () -> NSTextView?
  /// Told the range right before it is selected, so selection-driven UI can skip it.
  private let willSelect: (NSRange) -> Void
  private var generation = 0

  init(
    text: @escaping () -> String,
    textView: @escaping () -> NSTextView?,
    willSelect: @escaping (NSRange) -> Void
  ) {
    self.text = text
    self.textView = textView
    self.willSelect = willSelect
  }

  nonisolated deinit {}

  /// `takesFocus` makes the text view first responder; without it the
  /// selection shows in its inactive color and focus stays where it is.
  func reveal(_ selection: EditorSelection, takesFocus: Bool) {
    generation += 1
    attempt(selection, takesFocus: takesFocus, generation: generation, retry: 0)
  }

  private func attempt(_ selection: EditorSelection, takesFocus: Bool, generation: Int, retry: Int) {
    guard generation == self.generation else { return }
    switch apply(selection, takesFocus: takesFocus) {
    case .selected(let range):
      settleScroll(to: range, generation: generation)
      return
    case .outOfRange:
      return
    case .notReady:
      break
    }
    guard retry + 1 < Self.retryDelays.count else {
      Self.logger.warning("Gave up selecting \(String(describing: selection)): the editor never became ready")
      return
    }
    let delay = Self.retryDelays[retry + 1]
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      self?.attempt(selection, takesFocus: takesFocus, generation: generation, retry: retry + 1)
    }
  }

  private enum Outcome {
    case notReady
    case outOfRange
    case selected(NSRange)
  }

  private func apply(_ selection: EditorSelection, takesFocus: Bool) -> Outcome {
    let source = text()
    guard let textView = textView(), let window = textView.window,
      (textView.string as NSString).length == (source as NSString).length
    else { return .notReady }
    guard let range = selection.range(in: source) else {
      Self.logger.warning("Selection \(String(describing: selection)) lies past the end of the file")
      return .outOfRange
    }
    willSelect(range)
    if takesFocus { window.makeFirstResponder(textView) }
    textView.setSelectedRange(range)
    Self.scroll(textView, to: range)
    if range.length > 0 { textView.showFindIndicator(for: range) }
    Self.logger.debug("Selected \(range) for \(String(describing: selection))")
    return .selected(range)
  }

  private func settleScroll(to range: NSRange, generation: Int) {
    for delay in Self.settleDelays {
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: delay)
        guard let self, generation == self.generation, let textView = self.textView(),
          textView.selectedRange() == range
        else { return }
        Self.scroll(textView, to: range)
      }
    }
  }

  /// `scrollRangeToVisible` routes through the TextKit 1 layout manager a
  /// TextKit 2 view lacks, so it misses off-screen text. Lay out up to the
  /// range and scroll the clip view to its first line fragment instead,
  /// leaving it a little below the top, like the engine's own find does.
  private static func scroll(_ textView: NSTextView, to range: NSRange) {
    guard let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager,
      let scrollView = textView.enclosingScrollView,
      let documentView = scrollView.documentView
    else {
      textView.scrollRangeToVisible(range)
      return
    }
    let start = contentManager.documentRange.location
    guard let location = contentManager.location(start, offsetBy: range.location) else { return }
    if let leading = NSTextRange(location: start, end: location) {
      layoutManager.ensureLayout(for: leading)
    }
    var fragmentFrame: NSRect?
    layoutManager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
      fragmentFrame = fragment.layoutFragmentFrame
      return false
    }
    guard var frame = fragmentFrame else { return }
    frame.origin.x += textView.textContainerOrigin.x
    frame.origin.y += textView.textContainerOrigin.y
    let clipView = scrollView.contentView
    let target = textView.convert(frame, to: clipView)
    let insetTop = scrollView.contentInsets.top
    let visibleTop = clipView.bounds.minY + insetTop
    guard target.minY < visibleTop || target.maxY > clipView.bounds.maxY else { return }
    let maxY = max(documentView.frame.height - clipView.bounds.height, -insetTop)
    let y = min(max(target.minY - insetTop - clipView.bounds.height * 0.2, -insetTop), maxY)
    clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: y))
    scrollView.reflectScrolledClipView(clipView)
  }
}
