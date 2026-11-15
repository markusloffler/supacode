import ArgumentParser
import Foundation

struct ShowCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Open a file in the Supacode editor and select a range in it.",
    discussion: """
      Opens the file the way the file explorer does and selects --from through --to. \
      Works only inside a Supacode terminal and for a file of that terminal's worktree. \
      The request travels through the terminal, not the control socket, so it also \
      works from a sandboxed agent. Positions are 1-based LINE or LINE:COLUMN; the \
      end column is inclusive and a position without a column spans the whole line.
      """
  )

  @Argument(help: "The file to show. A relative path resolves against the current directory.")
  var file: String

  @Option(help: "Selection start: LINE or LINE:COLUMN.")
  var from: String?

  @Option(help: "Selection end: LINE or LINE:COLUMN. Defaults to --from.")
  var to: String?

  func validate() throws {
    if to != nil, from == nil {
      throw ValidationError("--to needs --from.")
    }
    for (name, value) in [("--from", from), ("--to", to)] {
      guard let value else { continue }
      guard Self.isValidPosition(value) else {
        throw ValidationError("\(name) must be LINE or LINE:COLUMN with positive numbers, got '\(value)'.")
      }
    }
  }

  func run() throws {
    let path = Self.absolutePath(file)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw ValidationError("No such file: \(path)")
    }
    try TerminalSignal.send(TerminalSignal.showFile(path: path, from: from, to: to))
  }

  static func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let base = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    return URL(filePath: expanded, relativeTo: base).standardizedFileURL.path(percentEncoded: false)
  }

  static func isValidPosition(_ value: String) -> Bool {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count) else { return false }
    return parts.allSatisfy { part in Int(part).map { $0 >= 1 } ?? false }
  }
}
