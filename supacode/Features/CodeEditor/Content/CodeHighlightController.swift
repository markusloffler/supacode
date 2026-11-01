import AppKit
import Dependencies
import SupacodeSettingsShared

/// Re-colours a text view after edits: debounced, highlighted off the main
/// thread, and applied only if no edit landed in between.
@MainActor
final class CodeHighlightController {
  private static let logger = SupaLogger("CodeEditor")
  static let debounce: Duration = .milliseconds(200)

  private let language: String?
  weak var textView: NSTextView?
  private var task: Task<Void, Never>?
  /// Bumped per edit, so a stale result is dropped.
  private var generation = 0
  @Dependency(\.continuousClock) private var clock

  init(language: String?) {
    self.language = language
  }

  nonisolated deinit {}

  /// The text changed; `immediately` skips the debounce (load, reload, appearance flip).
  func textChanged(immediately: Bool = false) {
    generation += 1
    task?.cancel()
    guard let textView else { return }
    let code = textView.string
    guard let language, (code as NSString).length <= CodeSyntaxHighlighter.maxLength else {
      Self.applyPlain(to: textView)
      return
    }
    let isDark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let expected = generation
    task = Task { [weak self, clock] in
      if !immediately {
        try? await clock.sleep(for: Self.debounce)
      }
      guard !Task.isCancelled else { return }
      let runs = await Task.detached(priority: .userInitiated) {
        CodeSyntaxHighlighter.runs(code: code, language: language, dark: isDark)
      }.value
      guard !Task.isCancelled, let self, self.generation == expected, let textView = self.textView else { return }
      guard let runs else {
        Self.logger.debug("highlight.js failed for language \(language); showing plain text")
        Self.applyPlain(to: textView)
        return
      }
      Self.apply(runs, to: textView)
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  private static func apply(_ runs: CodeSyntaxHighlighter.Runs, to textView: NSTextView) {
    guard let storage = textView.textStorage else { return }
    let length = storage.length
    storage.beginEditing()
    for run in runs.runs where NSMaxRange(run.range) <= length {
      storage.addAttribute(.foregroundColor, value: run.color, range: run.range)
    }
    storage.endEditing()
  }

  private static func applyPlain(to textView: NSTextView) {
    guard let storage = textView.textStorage else { return }
    storage.addAttribute(
      .foregroundColor, value: NSColor.textColor, range: NSRange(location: 0, length: storage.length))
  }
}
