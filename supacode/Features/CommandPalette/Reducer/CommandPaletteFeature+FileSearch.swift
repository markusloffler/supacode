import Foundation

/// A file row's ranking fields, built once per listing off the main actor so
/// each keystroke scores plain strings in the background, not palette items.
nonisolated struct ProjectFileCandidate: CommandPaletteScorable, Equatable, Sendable {
  private static let idPrefix = "file:"

  /// Root-relative path.
  let path: String
  /// `file:` plus the absolute path; also the recency key.
  let id: String
  /// The file name, what a query hits first (VS Code Quick Open style).
  let title: String
  /// The containing directory, `nil` at the root.
  let subtitle: String?
  var priorityTier: Int { CommandPaletteItem.defaultPriorityTier }

  init(path: String, root: URL) {
    let components = path.split(separator: "/")
    let directory = components.dropLast().joined(separator: "/")
    self.path = path
    self.id = Self.idPrefix + root.appending(path: path).path(percentEncoded: false)
    self.title = components.last.map(String.init) ?? path
    self.subtitle = directory.isEmpty ? nil : directory
  }

  static func isFileID(_ id: String) -> Bool {
    id.hasPrefix(idPrefix)
  }
}

extension CommandPaletteFeature {
  /// The file listing behind `.fileSearch`, kept across presentations so a
  /// re-open of the same project shows the previous list while it refreshes.
  nonisolated struct ProjectFiles: Equatable, Sendable {
    var root: URL
    var files: [ProjectFileCandidate] = []
    var isLoading = true
  }

  /// How many opened files keep their recency (the empty-query "recent" ordering).
  nonisolated static let recentProjectFileLimit = 100
  /// The file list renders eagerly, so a query never shows more than this.
  nonisolated static let projectFileResultLimit = 200

  @concurrent nonisolated static func makeCandidates(paths: [String], root: URL) async -> [ProjectFileCandidate] {
    paths.map { ProjectFileCandidate(path: $0, root: root) }
  }

  /// One row per candidate, in candidate order, so ranked indices map straight back.
  static func projectFileItems(from projectFiles: ProjectFiles) -> [CommandPaletteItem] {
    projectFiles.files.map { file in
      CommandPaletteItem(
        id: file.id,
        title: file.title,
        subtitle: file.subtitle,
        kind: .openProjectFile(projectFiles.root.appending(path: file.path), root: projectFiles.root)
      )
    }
  }

  /// Ranks `files` off the main actor; `nil` when a newer keystroke cancelled it.
  @concurrent nonisolated static func rankProjectFiles(
    _ files: [ProjectFileCandidate],
    query: String,
    recencyByID: [CommandPaletteItem.ID: TimeInterval],
    now: Date
  ) async -> [Int]? {
    rankedProjectFileIndices(files, query: query, recencyByID: recencyByID, now: now) { Task.isCancelled }
  }

  /// Indices into `files`, capped at `projectFileResultLimit`. An empty query lists
  /// recently opened files first (most recent on top), then the rest in path order.
  nonisolated static func rankedProjectFileIndices<Item: CommandPaletteScorable>(
    _ files: [Item],
    query: String,
    recencyByID: [CommandPaletteItem.ID: TimeInterval],
    now: Date,
    isCancelled: () -> Bool = { false }
  ) -> [Int]? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      let recent = files.indices.filter { recencyByID[files[$0].id] != nil }
        .sorted { (recencyByID[files[$0].id] ?? 0) > (recencyByID[files[$1].id] ?? 0) }
      let rest = files.indices.lazy.filter { recencyByID[files[$0].id] == nil }
      return Array((recent + rest.prefix(projectFileResultLimit)).prefix(projectFileResultLimit))
    }
    let scorer = CommandPaletteFuzzyScorer<Item>(query: trimmed, recencyByID: recencyByID, now: now)
    return scorer.rankedIndices(from: files, isCancelled: isCancelled).map { Array($0.prefix(projectFileResultLimit)) }
  }
}
