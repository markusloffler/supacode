import AppKit
import SwiftUI

/// The plain-text `NSTextView` behind the code editor. Edits flow into the
/// document; a reload from disk (a new `reloadGeneration`) flows back.
struct CodeTextView: NSViewRepresentable {
  let model: CodeEditorModel
  let reloadGeneration: Int
  let softWrap: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(model: model)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false

    let textView = FocusReportingTextView(usingTextLayoutManager: true)
    textView.isRichText = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.textContainerInset = NSSize(width: 6, height: 8)
    textView.isVerticallyResizable = true
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.autoresizingMask = [.width]
    textView.typingAttributes = [.font: Coordinator.font, .foregroundColor: NSColor.textColor]
    textView.delegate = context.coordinator
    textView.onFocusChange = { [weak model] in model?.editorFocusChanged($0) }
    textView.onAppearanceChange = { [weak model] in model?.highlighter.textChanged(immediately: true) }
    scrollView.documentView = textView

    model.scrollView = scrollView
    model.textView = textView
    context.coordinator.load(into: textView, generation: reloadGeneration)
    Coordinator.applySoftWrap(softWrap, to: scrollView, textView: textView)
    context.coordinator.softWrap = softWrap
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    let coordinator = context.coordinator
    if coordinator.generation != reloadGeneration {
      coordinator.load(into: textView, generation: reloadGeneration)
    }
    if coordinator.softWrap != softWrap {
      coordinator.softWrap = softWrap
      Coordinator.applySoftWrap(softWrap, to: scrollView, textView: textView)
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private let model: CodeEditorModel
    /// The document generation the text view shows.
    var generation = -1
    var softWrap = false

    init(model: CodeEditorModel) {
      self.model = model
    }

    nonisolated deinit {}

    /// Replaces the text view's content with the document's, keeping the caret.
    func load(into textView: NSTextView, generation: Int) {
      self.generation = generation
      let selection = textView.selectedRange()
      textView.string = model.document.text
      textView.font = Self.font
      textView.undoManager?.removeAllActions()
      let length = (textView.string as NSString).length
      textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
      model.highlighter.textChanged(immediately: true)
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
      model.promptEdit.buildContextMenu(menu, selection: view.selectedRange())
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      model.document.text = textView.string
      model.highlighter.textChanged()
    }

    static func applySoftWrap(_ wrap: Bool, to scrollView: NSScrollView, textView: NSTextView) {
      guard let container = textView.textContainer else { return }
      scrollView.hasHorizontalScroller = !wrap
      textView.isHorizontallyResizable = !wrap
      container.widthTracksTextView = wrap
      if wrap {
        container.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
      } else {
        container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
      }
    }
  }
}

/// Reports first-responder and appearance changes to the editor model.
private final class FocusReportingTextView: NSTextView {
  var onFocusChange: ((Bool) -> Void)?
  var onAppearanceChange: (() -> Void)?

  nonisolated deinit {}

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onFocusChange?(true) }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { onFocusChange?(false) }
    return resigned
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onAppearanceChange?()
  }
}
