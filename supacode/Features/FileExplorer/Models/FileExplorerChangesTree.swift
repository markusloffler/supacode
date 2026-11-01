import Foundation

extension FileExplorerFeature.TreeState {
  /// The same tree narrowed to uncommitted changes, for the Changes inspector.
  /// Built purely from the git status snapshot (which lists every changed file,
  /// untracked ones included), so it never waits on lazy directory listings.
  /// Every directory is expanded unless the user collapsed it in this view.
  /// Gone-from-disk deletions stay out of the listings so the outline renders
  /// them as tombstones, exactly like the full tree.
  /// `flat` lists every changed file directly under the root, named by its
  /// root-relative path; deletions are listed too, as there is no parent row
  /// to hang a tombstone on.
  nonisolated func changesOnly(flat: Bool = false) -> Self {
    if flat { return flatChanges() }
    var entriesByDirectory: [String: Set<FileExplorerEntry>] = [Self.rootPath: []]
    for (path, status) in gitStatus.statuses where status.hasVisibleChange {
      let parent = FileExplorerFeature.parentDirectory(of: path)
      Self.registerDirectory(parent, in: &entriesByDirectory)
      let isGoneFromDisk = !status.isUntracked && (status.index == .deleted || status.worktree == .deleted)
      if !isGoneFromDisk {
        entriesByDirectory[parent, default: []].insert(Self.entry(for: path, isDirectory: false))
      }
    }

    var tree = Self(root: root)
    tree.gitStatus = gitStatus
    tree.selectedPath = selectedPath
    tree.collapsedChanges = collapsedChanges
    for (directory, entries) in entriesByDirectory {
      let sorted = entries.sorted { lhs, rhs in
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
      let listing = FileExplorerListing(entries: sorted, totalCount: sorted.count, modificationDate: nil)
      tree.directories[directory] = FileExplorerFeature.DirectoryNode(
        status: .loaded(listing),
        requestedLimit: sorted.count
      )
    }
    tree.expanded = Set(entriesByDirectory.keys)
      .subtracting([Self.rootPath])
      .subtracting(collapsedChanges)
    return tree
  }

  /// Every changed file as a root entry named by its full relative path, which
  /// `childPath(of: rootPath, name:)` maps back to the real path.
  private nonisolated func flatChanges() -> Self {
    let sorted = gitStatus.statuses
      .filter { $0.value.hasVisibleChange }
      .keys
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      .map { FileExplorerEntry(name: $0, isDirectory: false, isSymbolicLink: false) }
    var tree = Self(root: root)
    tree.gitStatus = gitStatus
    tree.selectedPath = selectedPath
    tree.collapsedChanges = collapsedChanges
    let listing = FileExplorerListing(entries: sorted, totalCount: sorted.count, modificationDate: nil)
    tree.directories[Self.rootPath] = FileExplorerFeature.DirectoryNode(
      status: .loaded(listing),
      requestedLimit: sorted.count
    )
    return tree
  }

  /// Adds `directory` and its missing ancestors, each listed in its parent.
  /// Stops at the first already-known directory (the root is always known).
  private nonisolated static func registerDirectory(
    _ directory: String,
    in entriesByDirectory: inout [String: Set<FileExplorerEntry>]
  ) {
    guard entriesByDirectory[directory] == nil else { return }
    entriesByDirectory[directory] = []
    var current = directory
    while current != rootPath {
      let parent = FileExplorerFeature.parentDirectory(of: current)
      // Check before inserting: the insert itself registers the parent.
      let isParentKnown = entriesByDirectory[parent] != nil
      entriesByDirectory[parent, default: []].insert(entry(for: current, isDirectory: true))
      guard !isParentKnown else { return }
      current = parent
    }
  }

  private nonisolated static func entry(for path: String, isDirectory: Bool) -> FileExplorerEntry {
    FileExplorerEntry(name: (path as NSString).lastPathComponent, isDirectory: isDirectory, isSymbolicLink: false)
  }
}
