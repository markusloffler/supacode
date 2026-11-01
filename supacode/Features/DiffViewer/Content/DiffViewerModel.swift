import AppKit
import Dependencies
import Observation
import Sharing
import SupacodeSettingsShared

/// Loads a file's HEAD and working-tree texts, diffs and colours them off the
/// main thread, and reloads whenever the file changes on disk. Offers Prompt
/// Edit on a selection in its text views.
@MainActor
@Observable
final class DiffViewerModel: PromptEditSource {
  private static let logger = SupaLogger("DiffViewer")

  /// A computed diff, ready to show in either layout.
  struct Document: Sendable {
    let diff: LineDiff
    /// The committed lines, plain; quoted by Prompt Edit.
    let oldTexts: [String]
    let newLineCount: Int
    let unified: DiffTextColumn
    let oldColumn: DiffTextColumn
    let newColumn: DiffTextColumn
    /// HEAD lacks the file (new or untracked).
    let isNewFile: Bool
    /// The working-tree file is gone.
    let isDeleted: Bool
  }

  enum Phase {
    case loading
    case loaded(Document)
    case failed(String)
  }

  let contentID: ContentID
  let worktreeID: Worktree.ID
  let relativePath: String
  private(set) var phase: Phase = .loading
  /// Side by side or unified; mirrors the app-wide setting, re-read on activate.
  private(set) var sideBySide = true
  var promptEditStatus: PromptEditStatus?

  @ObservationIgnored let promptEditTargets: () -> [PromptEditTarget]
  @ObservationIgnored let send: (MarkdownAction) -> Void
  /// The text views, set by the representable while mounted.
  @ObservationIgnored weak var pane: DiffTextPaneView?
  /// The column last focused; where Prompt Edit reads the selection.
  @ObservationIgnored weak var activeTextView: DiffTextView?
  @ObservationIgnored let promptEdit = PromptEditController()
  @ObservationIgnored private let fileURL: URL
  @ObservationIgnored private let worktreeRoot: URL
  @ObservationIgnored private var watcher: MarkdownFileWatcher?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var isDark = false
  @ObservationIgnored private var isActive = false
  @ObservationIgnored private var currentHunk: Int?
  @ObservationIgnored @Shared(.diffViewerSideBySide) private var storedSideBySide: Bool
  @ObservationIgnored @Dependency(GitClientDependency.self) private var gitClient

  init(
    contentID: ContentID,
    worktreeID: Worktree.ID,
    relativePath: String,
    worktreeRoot: URL,
    promptEditTargets: @escaping () -> [PromptEditTarget],
    send: @escaping (MarkdownAction) -> Void
  ) {
    self.contentID = contentID
    self.worktreeID = worktreeID
    self.relativePath = relativePath
    self.worktreeRoot = worktreeRoot
    self.fileURL = worktreeRoot.appending(path: relativePath, directoryHint: .notDirectory)
    self.promptEditTargets = promptEditTargets
    self.send = send
    promptEdit.host = self
  }

  nonisolated deinit {}

  var fileName: String {
    (relativePath as NSString).lastPathComponent
  }

  func activate() {
    guard !isActive else { return }
    isActive = true
    sideBySide = storedSideBySide
    let watcher = MarkdownFileWatcher(fileURL: fileURL) { [weak self] in
      Self.logger.debug("File changed on disk, reloading diff")
      self?.reload()
    }
    watcher.start()
    self.watcher = watcher
    promptEdit.activate()
    reload()
  }

  func deactivate() {
    isActive = false
    watcher?.stop()
    watcher = nil
    loadTask?.cancel()
    loadTask = nil
    promptEdit.deactivate()
  }

  /// Flips the layout here and app-wide.
  func toggleLayout() {
    sideBySide.toggle()
    Self.logger.info("[USER] Switched diffs to \(sideBySide ? "side by side" : "unified")")
    $storedSideBySide.withLock { [sideBySide] in $0 = sideBySide }
  }

  /// Change-block start lines for the layout; empty until loaded.
  func hunkStarts() -> [Int] {
    guard case .loaded(let document) = phase else { return [] }
    return sideBySide ? document.diff.sideBySideHunkStarts : document.diff.unifiedHunkStarts
  }

  /// Scrolls to the next (`+1`) or previous (`-1`) change, wrapping around.
  func step(_ direction: Int) {
    let starts = hunkStarts()
    guard !starts.isEmpty else { return }
    let count = starts.count
    let next = currentHunk.map { ($0 + direction + count) % count } ?? (direction > 0 ? 0 : count - 1)
    currentHunk = next
    Self.logger.info("[USER] Jumped to change \(next + 1) of \(count) in \(relativePath)")
    pane?.scrollToLine(starts[next])
  }

  /// The view's colour scheme; re-colours on a flip.
  func setDark(_ dark: Bool) {
    guard dark != isDark else { return }
    isDark = dark
    if isActive { reload() }
  }

  /// Re-reads both sides; also picks up a commit that moved HEAD.
  func reload() {
    loadTask?.cancel()
    let request = LoadRequest(
      relativePath: relativePath, fileURL: fileURL, worktreeRoot: worktreeRoot, dark: isDark, gitClient: gitClient)
    loadTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) { await request.load() }.value
      guard !Task.isCancelled, let self else { return }
      switch result {
      case .success(let document):
        Self.logger.debug(
          "Diffed \(self.relativePath): +\(document.diff.addedCount) -\(document.diff.removedCount)")
        self.phase = .loaded(document)
      case .failure(let error):
        Self.logger.warning("Cannot diff \(self.relativePath): \(error.message)")
        self.phase = .failed(error.message)
      }
    }
  }

  // MARK: Prompt Edit

  var textView: NSTextView? { activeTextView ?? pane?.textViews.first }

  func promptEditSelection(for range: NSRange) -> PromptEditSelection? {
    guard
      case .loaded(let document) = phase,
      let column = (textView as? DiffTextView)?.column,
      let indices = column.lineIndices(for: range)
    else { return nil }
    return DiffPromptSelection.selection(
      of: Array(column.lines[indices]),
      oldTexts: document.oldTexts,
      newLineCount: document.newLineCount,
      relativePath: relativePath
    )
  }

  /// The diff shows the file on disk, which is what the agent reads.
  func prepareForPromptEdit() {}
}

/// One off-main load: read both sides, diff, colour, lay out.
nonisolated private struct LoadRequest: Sendable {
  struct Failure: Error {
    let message: String
  }

  let relativePath: String
  let fileURL: URL
  let worktreeRoot: URL
  let dark: Bool
  let gitClient: GitClientDependency

  func load() async -> Result<DiffViewerModel.Document, Failure> {
    let headData: Data?
    do {
      headData = try await gitClient.headFileContents(relativePath, worktreeRoot)
    } catch {
      return .failure(Failure(message: "Could not read the committed version: \(error.localizedDescription)"))
    }
    let workingData = try? Data(contentsOf: fileURL)
    guard
      let oldText = String(data: headData ?? Data(), encoding: .utf8),
      let newText = String(data: workingData ?? Data(), encoding: .utf8)
    else {
      return .failure(Failure(message: "Binary files cannot be shown as a diff."))
    }
    let fileName = (relativePath as NSString).lastPathComponent
    let oldTexts = LineDiff.splitLines(oldText)
    let newTexts = LineDiff.splitLines(newText)
    let diff = LineDiff(old: oldTexts, new: newTexts)
    let font = DiffTextStyle.font
    let oldLines = DiffLineHighlighter.lines(of: oldText, fileName: fileName, dark: dark, font: font)
    let newLines = DiffLineHighlighter.lines(of: newText, fileName: fileName, dark: dark, font: font)
    func column(_ side: DiffTextColumn.Side, _ lines: [LineDiff.Line?]) -> DiffTextColumn {
      DiffTextColumn(side: side, lines: lines, oldLines: oldLines, newLines: newLines, font: font)
    }
    return .success(
      DiffViewerModel.Document(
        diff: diff,
        oldTexts: oldTexts,
        newLineCount: newTexts.count,
        unified: column(.unified, diff.lines),
        oldColumn: column(.old, diff.rows.map(\.old)),
        newColumn: column(.new, diff.rows.map(\.new)),
        isNewFile: headData == nil,
        isDeleted: workingData == nil
      )
    )
  }
}
