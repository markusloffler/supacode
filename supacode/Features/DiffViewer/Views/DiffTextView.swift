import AppKit

/// Shared look of the diff text views.
nonisolated enum DiffTextStyle {
  nonisolated(unsafe) static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  static let verticalInset: CGFloat = 4
  static let gutterPadding: CGFloat = 8
}

/// A read-only, selectable diff column: one `NSTextView` (TextKit 1, no
/// wrapping, so side-by-side columns stay row-aligned) that paints each line's
/// change tint and its number and +/− marker in a gutter left of the text.
final class DiffTextView: NSTextView {
  /// What the text shows, line by line.
  var column: DiffTextColumn? {
    didSet { updateGutterWidth() }
  }
  var onFocus: (() -> Void)?
  private var gutterWidth: CGFloat = 0

  nonisolated deinit {}

  override var textContainerOrigin: NSPoint {
    NSPoint(x: gutterWidth, y: DiffTextStyle.verticalInset)
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onFocus?() }
    return became
  }

  /// Replaces the shown column, keeping the scroll position.
  func show(_ column: DiffTextColumn) {
    self.column = column
    textStorage?.setAttributedString(column.text)
    setSelectedRange(NSRange(location: 0, length: 0))
    needsDisplay = true
  }

  /// The y offset of text line `index` in view coordinates.
  func yOffset(ofLine index: Int) -> CGFloat? {
    guard let column, let layoutManager, let textContainer, index < column.lineStarts.count else { return nil }
    let location = column.lineStarts[index]
    guard location < (textStorage?.length ?? 0) else { return nil }
    let glyphs = layoutManager.glyphRange(
      forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
    return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).minY + textContainerOrigin.y
  }

  override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    guard let column, let layoutManager, let textContainer else { return }
    let origin = textContainerOrigin
    let containerRect = rect.offsetBy(dx: -origin.x, dy: -origin.y)
    let glyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
    layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { [self] fragment, _, _, glyphRange, _ in
      let location = layoutManager.characterIndexForGlyph(at: glyphRange.location)
      drawLine(column.lineIndex(containing: location), fragment: fragment, column: column)
    }
    // A trailing empty line has no fragment of its own.
    let extra = layoutManager.extraLineFragmentRect
    if !extra.isEmpty, let last = column.lines.indices.last {
      drawLine(last, fragment: extra, column: column)
    }
  }

  private func drawLine(_ index: Int, fragment: NSRect, column: DiffTextColumn) {
    let lineRect = NSRect(x: 0, y: fragment.minY + textContainerOrigin.y, width: bounds.width, height: fragment.height)
    let line = column.lines[index]
    if let tint = Self.tint(for: line) {
      tint.setFill()
      lineRect.fill()
    }
    guard let line else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: DiffTextStyle.font, .foregroundColor: NSColor.secondaryLabelColor,
    ]
    if let number = column.number(at: index) {
      let text = "\(number)" as NSString
      let size = text.size(withAttributes: attributes)
      text.draw(
        at: NSPoint(x: gutterWidth - DiffTextStyle.gutterPadding * 2 - Self.digitWidth - size.width, y: lineRect.minY),
        withAttributes: attributes)
    }
    let marker: (String, NSColor)? =
      switch line.kind {
      case .context: nil
      case .removed: ("−", .systemRed)
      case .added: ("+", .systemGreen)
      }
    if let (symbol, color) = marker {
      (symbol as NSString).draw(
        at: NSPoint(x: gutterWidth - DiffTextStyle.gutterPadding - Self.digitWidth, y: lineRect.minY),
        withAttributes: [.font: DiffTextStyle.font, .foregroundColor: color])
    }
  }

  private static func tint(for line: LineDiff.Line?) -> NSColor? {
    guard let line else { return NSColor.secondaryLabelColor.withAlphaComponent(0.06) }
    switch line.kind {
    case .context: return nil
    case .removed: return NSColor.systemRed.withAlphaComponent(0.14)
    case .added: return NSColor.systemGreen.withAlphaComponent(0.24)
    }
  }

  private static let digitWidth = ("0" as NSString).size(withAttributes: [.font: DiffTextStyle.font]).width

  /// Room for the widest line number, the marker, and padding around both.
  private func updateGutterWidth() {
    let digits = CGFloat(String(column?.lineStarts.count ?? 1).count)
    gutterWidth = DiffTextStyle.gutterPadding * 3 + Self.digitWidth * (digits + 1)
    // The origin override places the text; the inset only makes the view's
    // fitted width include the gutter (it counts on both sides).
    textContainerInset = NSSize(width: gutterWidth / 2, height: DiffTextStyle.verticalInset)
  }
}

/// One scroll view per column, side by side with synced vertical scrolling.
final class DiffTextPaneView: NSView {
  private(set) var textViews: [DiffTextView] = []
  private var scrollViews: [NSScrollView] = []
  private var dividers: [NSBox] = []
  private var scrollObservers: [any NSObjectProtocol] = []
  private var isSyncing = false

  nonisolated deinit {}

  /// Shows `columns`, reusing the text views (and scroll position) when the
  /// column count is unchanged, as on a reload.
  func show(_ columns: [DiffTextColumn], configure: (DiffTextView) -> Void) {
    if columns.count != textViews.count {
      rebuild(count: columns.count, configure: configure)
    }
    for (textView, column) in zip(textViews, columns) {
      textView.show(column)
    }
  }

  /// Scrolls text line `index` to a fifth from the top.
  func scrollToLine(_ index: Int) {
    guard let textView = textViews.first, let scrollView = scrollViews.first,
      let y = textView.yOffset(ofLine: index)
    else { return }
    let clip = scrollView.contentView
    let maxY = max(0, textView.frame.height - clip.bounds.height)
    let target = min(max(0, y - clip.bounds.height * 0.2), maxY)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: target))
    }
    scrollView.reflectScrolledClipView(clip)
  }

  override func layout() {
    super.layout()
    guard !scrollViews.isEmpty else { return }
    let dividerWidth: CGFloat = 1
    let count = CGFloat(scrollViews.count)
    let width = (bounds.width - dividerWidth * (count - 1)) / count
    for (index, scrollView) in scrollViews.enumerated() {
      let x = CGFloat(index) * (width + dividerWidth)
      scrollView.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
      if index > 0 {
        dividers[index - 1].frame = NSRect(x: x - dividerWidth, y: 0, width: dividerWidth, height: bounds.height)
      }
    }
  }

  private func rebuild(count: Int, configure: (DiffTextView) -> Void) {
    for observer in scrollObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    scrollObservers = []
    subviews.forEach { $0.removeFromSuperview() }
    scrollViews = []
    textViews = []
    dividers = []
    for index in 0..<count {
      if index > 0 {
        let divider = NSBox()
        divider.boxType = .separator
        addSubview(divider)
        dividers.append(divider)
      }
      let (scrollView, textView) = Self.makeColumn()
      configure(textView)
      addSubview(scrollView)
      scrollViews.append(scrollView)
      textViews.append(textView)
    }
    if count > 1 { syncScrolling() }
    needsLayout = true
  }

  /// Mirrors one column's vertical scroll position onto the others.
  private func syncScrolling() {
    for scrollView in scrollViews {
      let clip = scrollView.contentView
      clip.postsBoundsChangedNotifications = true
      scrollObservers.append(
        NotificationCenter.default.addObserver(
          forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.follow(clip) }
        })
    }
  }

  private func follow(_ source: NSClipView) {
    guard !isSyncing else { return }
    isSyncing = true
    defer { isSyncing = false }
    for scrollView in scrollViews where scrollView.contentView !== source {
      let clip = scrollView.contentView
      guard clip.bounds.minY != source.bounds.minY else { continue }
      clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: source.bounds.minY))
      scrollView.reflectScrolledClipView(clip)
    }
  }

  private static func makeColumn() -> (NSScrollView, DiffTextView) {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false

    let textView = DiffTextView(usingTextLayoutManager: false)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.usesFindBar = true
    textView.drawsBackground = false
    textView.font = DiffTextStyle.font
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: 0, height: DiffTextStyle.verticalInset)
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.layoutManager?.allowsNonContiguousLayout = true
    scrollView.documentView = textView
    return (scrollView, textView)
  }
}
