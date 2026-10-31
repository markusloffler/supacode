import Foundation

/// Pure parsing for the sandbox-restart handshake with the `sclaude` / `scopilot`
/// launchers (ai-sandbox). On a sandbox block the agent prints the extended launcher
/// command line framed by `frameBegin` / `frameEnd`, followed by a restart marker
/// carrying a fresh nonce. Supacode asks the user to confirm, exits the agent, and runs
/// the framed command line — never a copy carried by the marker itself.
///
/// The markers are part of the contract with the launchers' system prompt
/// (`build_restart_guidance` in ai-sandbox's `sandbox-common.zsh`); change both together.
nonisolated enum SandboxRestart {
  static let frameBegin = "⟦sandbox-cmd⟧"
  static let frameEnd = "⟦/sandbox-cmd⟧"
  /// Splits the frame into the original command line and the flags the agent appended,
  /// so the confirmation dialog can highlight the additions.
  static let additionsSeparator = "⟦+⟧"
  /// Cheap pre-check before the full restart-marker regex runs.
  static let restartMarkerPrefix = "⟦supacode-sandbox-restart:"
  /// Launchers whose command lines may be injected. Anything else is refused.
  static let launchers: Set<String> = ["sclaude", "scopilot"]
  /// Upper bound on an injected command line; a longer frame is treated as garbage.
  static let maxCommandLength = 4096
  /// Sent to the restarted session so it picks the task back up.
  static let continuePrompt = "'Restart complete. Continue'"

  struct Request: Equatable, Sendable {
    let nonce: String
    /// The launch command line as the session started it.
    let base: String
    /// Flags the agent appended; empty when the frame carried no `additionsSeparator`.
    let additions: String

    var command: String { additions.isEmpty ? base : "\(base) \(additions)" }
  }

  /// Finds the LAST restart marker in `text` and the nearest complete command frame
  /// before it. Returns nil when there is no marker, no frame before it, or the framed
  /// command fails validation.
  static func request(in text: String) -> Request? {
    let marker = /⟦supacode-sandbox-restart:([A-Za-z0-9]{6,64})⟧/
    guard let match = text.matches(of: marker).last else { return nil }
    let before = text[..<match.range.lowerBound]
    guard let end = before.range(of: frameEnd, options: .backwards),
      let begin = before[..<end.lowerBound].range(of: frameBegin, options: .backwards)
    else { return nil }
    let body = before[begin.upperBound..<end.lowerBound]
    let parts = body.split(separator: additionsSeparator, maxSplits: 1, omittingEmptySubsequences: false)
    let base = normalized(parts[0])
    let agentAdditions = parts.count > 1 ? normalized(parts[1]) : ""
    guard isValid(base), let launcher = base.split(separator: " ").first else { return nil }
    let additions = [agentAdditions, promptArgument(launcher: String(launcher))]
      .filter { !$0.isEmpty }.joined(separator: " ")
    let request = Request(nonce: String(match.output.1), base: base, additions: additions)
    guard isValid(request.command) else { return nil }
    return request
  }

  /// The `continuePrompt` as the launcher's CLI takes an initial interactive prompt:
  /// claude as a trailing positional argument, copilot through `-i`.
  static func promptArgument(launcher: String) -> String {
    launcher == "scopilot" ? "-i \(continuePrompt)" : continuePrompt
  }

  /// One command-line token in the confirmation dialog; `isAddition` marks the ones the
  /// restart appended, which the dialog highlights.
  struct DisplayToken: Equatable {
    let text: String
    let isAddition: Bool
  }

  /// Splits a command line into display lines, one per option: the launcher, then each
  /// flag with its values, and each quoted argument on its own line. Every token keeps
  /// whether it was appended (`isAddition`) so the dialog can highlight it.
  static func displayLines(of request: Request) -> [[DisplayToken]] {
    let tokens =
      tokenize(request.base).map { DisplayToken(text: $0, isAddition: false) }
      + tokenize(request.additions).map { DisplayToken(text: $0, isAddition: true) }
    var lines: [[DisplayToken]] = []
    for entry in tokens {
      let isFlag = entry.text.hasPrefix("-")
      let isQuoted = entry.text.hasPrefix("'") || entry.text.hasPrefix("\"")
      // A quoted value right after a lone flag belongs to it (`-i 'prompt'`).
      let followsLoneFlag = lines.last.map { $0.count == 1 && $0[0].text.hasPrefix("-") } ?? false
      if lines.isEmpty || isFlag || (isQuoted && !followsLoneFlag) {
        lines.append([entry])
      } else {
        lines[lines.count - 1].append(entry)
      }
    }
    return lines
  }

  /// Whitespace-separated tokens, keeping single- or double-quoted runs (quotes
  /// included) together. Display only; the command runs exactly as framed.
  static func tokenize(_ command: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var quote: Character?
    for char in command {
      if let open = quote {
        current.append(char)
        if char == open { quote = nil }
      } else if char.isWhitespace {
        if !current.isEmpty { tokens.append(current) }
        current = ""
      } else {
        if char == "'" || char == "\"" { quote = char }
        current.append(char)
      }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
  }

  /// Turns rendered frame text back into command-line text: drops the markdown
  /// emphasis the agent may have used for the additions (bold, inline code) in case it
  /// reached the screen unrendered, and collapses the TUI's line wrapping,
  /// indentation and box borders (`│` framing a wrapped block) into single spaces.
  ///
  /// The TUI hard-wraps a token longer than the remaining line mid-word, so a line break
  /// is not always a token boundary. A break inside a path is undone when only the
  /// joined spelling exists on disk (see `continuesPath`).
  static func normalized(
    _ text: Substring,
    pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> String {
    let stripped = text.replacing("**", with: "").replacing("`", with: "")
    var result = ""
    for line in stripped.split(whereSeparator: \.isNewline) {
      let tokens = line.split(whereSeparator: { $0.isWhitespace || isBoxDrawing($0) }).joined(separator: " ")
      guard !tokens.isEmpty else { continue }
      if result.isEmpty {
        result = tokens
      } else if continuesPath(result, with: tokens, pathExists: pathExists) {
        result += tokens
      } else {
        result += " " + tokens
      }
    }
    return result
  }

  /// Whether `next` continues a path that the wrap cut at the end of `text`: the last
  /// token is an absolute or home path that does not exist, while gluing on the first
  /// token of `next` names an existing path or the prefix of an existing entry (a
  /// path wrapped over more than two lines).
  static func continuesPath(_ text: String, with next: String, pathExists: (String) -> Bool) -> Bool {
    guard let head = text.split(separator: " ").last, head.hasPrefix("/") || head.hasPrefix("~/"),
      let tail = next.split(separator: " ").first, !tail.hasPrefix("-")
    else { return false }
    let expand = { (path: String) in (path as NSString).expandingTildeInPath }
    guard !pathExists(expand(String(head))) else { return false }
    let joined = expand(String(head + tail))
    if pathExists(joined) { return true }
    let parent = (joined as NSString).deletingLastPathComponent
    let prefix = (joined as NSString).lastPathComponent
    guard !prefix.isEmpty, let entries = try? FileManager.default.contentsOfDirectory(atPath: parent) else {
      return false
    }
    return entries.contains { $0.hasPrefix(prefix) }
  }

  /// Box Drawing block (U+2500–U+257F), which TUIs use for borders and never
  /// belongs to a command line.
  static func isBoxDrawing(_ char: Character) -> Bool {
    char.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) }
  }

  /// A launcher invocation of sane length without control characters.
  static func isValid(_ command: String) -> Bool {
    guard !command.isEmpty, command.count <= maxCommandLength,
      !command.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
      let launcher = command.split(separator: " ").first
    else { return false }
    return launchers.contains(String(launcher))
  }
}
