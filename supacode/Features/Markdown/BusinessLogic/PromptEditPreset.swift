import Foundation

/// A one-click Prompt Edit request: a short button label for a detailed prompt.
/// The set depends on the file (prose or code); a diff selection keeps it, with
/// Explain and Review aimed at the change, plus Revert.
struct PromptEditPreset: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case prose, code
  }

  let label: String
  let prompt: String

  var id: String { label }

  /// File extensions treated as prose; anything else with an extension is code.
  static let proseExtensions: Set<String> = ["", "md", "markdown", "mdown", "txt", "text"]

  static func kind(of selection: PromptEditSelection) -> Kind {
    let ext = URL(filePath: selection.relativePath).pathExtension.lowercased()
    return proseExtensions.contains(ext) ? .prose : .code
  }

  static func presets(for selection: PromptEditSelection) -> [PromptEditPreset] {
    let base: [PromptEditPreset] =
      switch kind(of: selection) {
      case .prose: prose
      case .code: code
      }
    // MARK: Diff viewer
    guard let diff = selection.diff else { return base }
    let presets = base.map { diffVariants[$0.label] ?? $0 } + [revert]
    // Removed lines are no longer in the file, so only asking about them or
    // restoring them makes sense.
    return diff.removedOnly ? presets.filter { removedOnlyLabels.contains($0.label) } : presets
  }

  /// The preset's prompt, with the field's text appended as a note when typed.
  static func instruction(_ preset: PromptEditPreset, note: String) -> String {
    let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return note.isEmpty ? preset.prompt : "\(preset.prompt) Additional note: \(note)"
  }

  private static let review = PromptEditPreset(
    label: "Review",
    prompt: "Review the selection and list problems and possible improvements. Do not change the file."
  )

  static let prose: [PromptEditPreset] = [
    PromptEditPreset(
      label: "Explain",
      prompt: "Explain what the selection means. Answer in the terminal and do not change the file."
    ),
    PromptEditPreset(label: "Shorten", prompt: "Shorten the selection while keeping its main meaning."),
    PromptEditPreset(
      label: "Improve",
      prompt: "Improve the clarity, wording and structure of the selection without changing its meaning."
    ),
    PromptEditPreset(label: "Fix", prompt: "Fix typos, grammar and factual errors in the selection."),
    PromptEditPreset(label: "Simplify", prompt: "Rewrite the selection in simpler terms, keeping its meaning."),
    PromptEditPreset(label: "Expand", prompt: "Elaborate on the selection with more detail and examples where helpful."),
    review,
  ]

  static let code: [PromptEditPreset] = [
    PromptEditPreset(
      label: "Explain",
      prompt: "Explain what the selected code does and how it works. Answer in the terminal and do not change the file."
    ),
    PromptEditPreset(label: "Fix", prompt: "Fix bugs in the selected code."),
    PromptEditPreset(label: "Simplify", prompt: "Simplify the selected code without changing its behaviour."),
    review,
    PromptEditPreset(label: "Document", prompt: "Add concise documentation comments to the selected code."),
    PromptEditPreset(
      label: "Tests",
      prompt: "Write unit tests covering the selected code, following the project's existing test conventions."
    ),
  ]

  // MARK: Diff viewer
  /// Replacements, by label, for presets that should address the change.
  private static let diffVariants: [String: PromptEditPreset] = [
    "Explain": PromptEditPreset(
      label: "Explain",
      prompt: "Explain the selected change: what it does and why it might have been made. "
        + "Answer in the terminal and do not change the file."
    ),
    "Review": PromptEditPreset(
      label: "Review",
      prompt: "Review the selected change for bugs, regressions and style issues. Do not change the file."
    ),
  ]

  private static let revert = PromptEditPreset(
    label: "Revert",
    prompt: "Revert the selected change so these lines match HEAD again, leaving other changes untouched."
  )

  private static let removedOnlyLabels: Set<String> = ["Explain", "Review", "Revert"]
}
