import Foundation

/// A line-by-line diff of two texts, laid out both unified (one column of
/// context / removed / added lines) and side by side (old | new rows, a change
/// block's removals paired with its additions).
nonisolated struct LineDiff: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case context
    case removed
    case added
  }

  /// A unified line: its index into the old and/or new line array.
  struct Line: Equatable, Sendable {
    let kind: Kind
    let oldIndex: Int?
    let newIndex: Int?
    /// Where the line sits in the new text: its own index, or for a removed
    /// line the index of the new line that follows it.
    let newPosition: Int
  }

  /// A side-by-side row; a nil side is padding opposite an unpaired change.
  struct Row: Equatable, Sendable {
    let old: Line?
    let new: Line?
  }

  /// Unified layout.
  let lines: [Line]
  /// Side-by-side layout.
  let rows: [Row]
  /// Indices into `lines` where a change block starts.
  let unifiedHunkStarts: [Int]
  /// Indices into `rows` where a change block starts.
  let sideBySideHunkStarts: [Int]
  let addedCount: Int
  let removedCount: Int

  var hasChanges: Bool { addedCount > 0 || removedCount > 0 }

  init(old: [String], new: [String]) {
    let difference = new.difference(from: old)
    var removedOffsets = Set<Int>()
    var insertedOffsets = Set<Int>()
    for change in difference {
      switch change {
      case .remove(let offset, _, _): removedOffsets.insert(offset)
      case .insert(let offset, _, _): insertedOffsets.insert(offset)
      }
    }
    var lines: [Line] = []
    lines.reserveCapacity(max(old.count, new.count))
    var oldIndex = 0
    var newIndex = 0
    while oldIndex < old.count || newIndex < new.count {
      if oldIndex < old.count, removedOffsets.contains(oldIndex) {
        lines.append(Line(kind: .removed, oldIndex: oldIndex, newIndex: nil, newPosition: newIndex))
        oldIndex += 1
      } else if newIndex < new.count, insertedOffsets.contains(newIndex) {
        lines.append(Line(kind: .added, oldIndex: nil, newIndex: newIndex, newPosition: newIndex))
        newIndex += 1
      } else {
        lines.append(Line(kind: .context, oldIndex: oldIndex, newIndex: newIndex, newPosition: newIndex))
        oldIndex += 1
        newIndex += 1
      }
    }
    self.lines = lines
    self.unifiedHunkStarts = Self.hunkStarts(lines.map(\.kind))
    self.rows = Self.pairedRows(lines)
    self.sideBySideHunkStarts = Self.hunkStarts(rows.map { ($0.old ?? $0.new)?.kind ?? .context })
    self.addedCount = insertedOffsets.count
    self.removedCount = removedOffsets.count
  }

  /// Splits text into lines; a trailing newline does not add an empty line.
  static func splitLines(_ text: String) -> [String] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  /// Pairs each change block's removals with its additions, row by row.
  private static func pairedRows(_ lines: [Line]) -> [Row] {
    var rows: [Row] = []
    rows.reserveCapacity(lines.count)
    var removed: [Line] = []
    var added: [Line] = []
    func flush() {
      for offset in 0..<max(removed.count, added.count) {
        rows.append(
          Row(old: offset < removed.count ? removed[offset] : nil, new: offset < added.count ? added[offset] : nil))
      }
      removed.removeAll()
      added.removeAll()
    }
    for line in lines {
      switch line.kind {
      case .removed: removed.append(line)
      case .added: added.append(line)
      case .context:
        flush()
        rows.append(Row(old: line, new: line))
      }
    }
    flush()
    return rows
  }

  private static func hunkStarts(_ kinds: [Kind]) -> [Int] {
    var starts: [Int] = []
    var previous = Kind.context
    for (index, kind) in kinds.enumerated() {
      if kind != .context, previous == .context { starts.append(index) }
      previous = kind
    }
    return starts
  }
}
