import Foundation
import SupacodeSettingsShared

private nonisolated let pathResolverLogger = SupaLogger("TerminalPath")

/// Turns the word or selection under a terminal right-click into files on disk:
/// a literal path (absolute, `~`, or relative to the shell's cwd or the
/// worktree root), else a filename search across the worktree's git files.
nonisolated enum TerminalPathResolver {
  /// Beyond this a submenu stops being a useful picker.
  static let maxMatches = 10
  /// A right-click must never hang on a huge or wedged repository.
  static let searchTimeoutMilliseconds = 500

  /// Strips what terminal output wraps around a path: quotes, brackets,
  /// trailing punctuation, `file://`, and `:line[:column]` / `#L12` suffixes.
  /// Nil for multi-line selections, URLs, and anything without a letter.
  static func candidate(from raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(where: \.isNewline) else { return nil }
    if text.hasPrefix("file://") {
      text = URL(string: text)?.path(percentEncoded: false) ?? text
    } else if text.contains("://") {
      return nil
    }
    let leading: Set<Character> = ["(", "[", "<", "{", "'", "\"", "`"]
    let trailing: Set<Character> = [")", "]", ">", "}", "'", "\"", "`", ",", ";", ":", ".", "!", "?"]
    while let first = text.first, leading.contains(first) { text.removeFirst() }
    while let last = text.last, trailing.contains(last) { text.removeLast() }
    text = text.replacing(/(:\d+)+$/, with: "").replacing(/#L\d+(-L?\d+)?$/, with: "")
    guard text.contains(where: \.isLetter) else { return nil }
    return text
  }

  /// Existing files for the candidate, best match first. `listFiles` returns the
  /// worktree's files relative to its root and only runs when no literal path hits.
  static func resolve(
    _ candidate: String,
    workingDirectory: URL?,
    worktreeRoot: URL,
    fileManager: FileManager = .default,
    listFiles: (URL) -> [String] = { Self.worktreeFiles(root: $0) }
  ) -> [URL] {
    // `a/…` / `b/…` are git diff prefixes, not directories.
    var variants = [candidate]
    if candidate.hasPrefix("a/") || candidate.hasPrefix("b/") {
      variants.append(String(candidate.dropFirst(2)))
    }
    for variant in variants {
      if let url = literalMatch(variant, workingDirectory: workingDirectory, worktreeRoot: worktreeRoot, fileManager) {
        return [url]
      }
    }
    // Only filename-shaped words are worth a repository search.
    guard let needle = variants.last, needle.contains(".") || needle.contains("/") else { return [] }
    let trimmedNeedle = needle.hasPrefix("./") ? String(needle.dropFirst(2)) : needle
    let cwdPrefix = workingDirectory.flatMap { relativePath(of: $0, under: worktreeRoot) }.map { $0 + "/" }
    let matches = listFiles(worktreeRoot)
      .filter { $0 == trimmedNeedle || $0.hasSuffix("/" + trimmedNeedle) }
      .sorted { lhs, rhs in
        let lhsInCwd = cwdPrefix.map { lhs.hasPrefix($0) } ?? false
        let rhsInCwd = cwdPrefix.map { rhs.hasPrefix($0) } ?? false
        if lhsInCwd != rhsInCwd { return lhsInCwd }
        let lhsDepth = lhs.count(where: { $0 == "/" })
        let rhsDepth = rhs.count(where: { $0 == "/" })
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
      }
      .prefix(maxMatches)
    return matches.map { worktreeRoot.appending(path: $0) }
  }

  /// The path relative to `root`, or nil when it lies outside it.
  static func relativePath(of url: URL, under root: URL) -> String? {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    var rootPath = root.standardizedFileURL.path(percentEncoded: false)
    if !rootPath.hasSuffix("/") { rootPath += "/" }
    guard path.hasPrefix(rootPath) else { return nil }
    let relative = String(path.dropFirst(rootPath.count))
    return relative.hasSuffix("/") ? String(relative.dropLast()) : relative
  }

  private static func literalMatch(
    _ path: String,
    workingDirectory: URL?,
    worktreeRoot: URL,
    _ fileManager: FileManager
  ) -> URL? {
    let expanded = path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
    let bases: [URL] =
      expanded.hasPrefix("/")
      ? [URL(filePath: expanded)]
      : [workingDirectory, worktreeRoot].compactMap(\.self).map {
        $0.appending(path: expanded)
      }
    return bases.first { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }?.standardizedFileURL
  }

  /// Tracked plus untracked-but-not-ignored files, relative to the root.
  /// Synchronous because a context menu is built synchronously; bounded by
  /// `timeoutMilliseconds` so a slow repository only costs the search, not the menu.
  /// Empty when `root` is not a git work tree.
  static func worktreeFiles(root: URL, timeoutMilliseconds: Int = searchTimeoutMilliseconds) -> [String] {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = [
      "git", "-C", root.path(percentEncoded: false), "ls-files", "-z", "--cached", "--others", "--exclude-standard",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      pathResolverLogger.warning("git ls-files failed to launch: \(error.localizedDescription)")
      return []
    }
    let timeout = DispatchWorkItem { [process] in
      if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(
      deadline: .now() + .milliseconds(timeoutMilliseconds),
      execute: timeout
    )
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    guard process.terminationStatus == 0 else {
      pathResolverLogger.debug("git ls-files exited \(process.terminationStatus) in \(root.lastPathComponent).")
      return []
    }
    guard let listing = String(bytes: data, encoding: .utf8) else { return [] }
    return listing.split(separator: "\0").map(String.init)
  }
}
