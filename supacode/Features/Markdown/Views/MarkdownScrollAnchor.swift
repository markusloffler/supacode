import AppKit

/// Keeps roughly the same text at the top of the viewport across a re-layout
/// (the read/edit toggle). Anchors on the character index of the top visible
/// line, which read mode preserves 1:1.
@MainActor
enum MarkdownScrollAnchor {
  struct Anchor: Equatable {
    /// UTF-16 offset of the first character of the top visible line.
    let characterIndex: Int
    /// How far that line's top sits above (positive) the viewport's top.
    let overhang: CGFloat
  }

  static func capture(in textView: NSTextView) -> Anchor? {
    guard let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else { return nil }
    let top = textView.visibleRect.minY - textView.textContainerOrigin.y
    guard
      let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 1, y: max(top, 0)))
    else { return nil }
    let fragmentStart = contentManager.offset(
      from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
    let frame = fragment.layoutFragmentFrame
    let line =
      fragment.textLineFragments.last { frame.minY + $0.typographicBounds.minY <= top }
      ?? fragment.textLineFragments.first
    let lineOffset = line?.characterRange.location ?? 0
    let lineTop = frame.minY + (line?.typographicBounds.minY ?? 0)
    return Anchor(characterIndex: fragmentStart + lineOffset, overhang: top - lineTop)
  }

  static func restore(_ anchor: Anchor, in textView: NSTextView) {
    guard let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else { return }
    let start = contentManager.documentRange.location
    guard let location = contentManager.location(start, offsetBy: anchor.characterIndex),
      let leading = NSTextRange(location: start, end: location)
    else { return }
    // TextKit 2 lays out lazily; frames above the anchor must be real.
    layoutManager.ensureLayout(for: leading)
    guard let fragment = layoutManager.textLayoutFragment(for: location) else { return }
    let offsetInFragment = contentManager.offset(from: fragment.rangeInElement.location, to: location)
    let frame = fragment.layoutFragmentFrame
    let line =
      fragment.textLineFragments.last { $0.characterRange.location <= offsetInFragment }
      ?? fragment.textLineFragments.first
    let lineTop = frame.minY + (line?.typographicBounds.minY ?? 0)
    let target = lineTop + anchor.overhang + textView.textContainerOrigin.y
    textView.scroll(NSPoint(x: textView.visibleRect.minX, y: max(target, 0)))
  }
}
