import Dependencies
import Foundation
import Observation
import SupacodeSettingsShared

/// Byte-faithful text codec: the editor works on LF-only text, while the file
/// keeps its original line endings and UTF-8 BOM.
nonisolated struct MarkdownTextCodec: Equatable, Sendable {
  var usesCRLF = false
  var hasBOM = false

  private static let bom = Data([0xEF, 0xBB, 0xBF])

  /// Decodes UTF-8 file bytes, recording the conventions to restore on save.
  /// Nil when the bytes are not valid UTF-8.
  static func decode(_ data: Data) -> (text: String, codec: MarkdownTextCodec)? {
    var codec = MarkdownTextCodec()
    var body = data
    if body.starts(with: bom) {
      codec.hasBOM = true
      body = body.dropFirst(bom.count)
    }
    guard let raw = String(data: body, encoding: .utf8) else { return nil }
    codec.usesCRLF = raw.contains("\r\n")
    return (codec.usesCRLF ? raw.replacing("\r\n", with: "\n") : raw, codec)
  }

  func encode(_ text: String) -> Data {
    let body = Data((usesCRLF ? text.replacing("\n", with: "\r\n") : text).utf8)
    return hasBOM ? Self.bom + body : body
  }
}

/// What a change on disk means for the open buffer.
nonisolated enum MarkdownDiskReconciliation: Equatable, Sendable {
  /// Disk matches what we last saved (our own write, or a touch).
  case ignore
  /// The buffer is clean: take the disk version silently.
  case reload(String)
  /// The buffer has unsaved edits that the disk version would overwrite.
  case conflict(String)
  /// The file is gone.
  case deleted

  static func decide(disk: String?, saved: String, isDirty: Bool) -> Self {
    guard let disk else { return .deleted }
    guard disk != saved else { return .ignore }
    return isDirty ? .conflict(disk) : .reload(disk)
  }
}

/// One Markdown file open in the editor: the buffer, debounced autosave, and
/// reconciliation with external writers (coding agents edit the same file).
@MainActor
@Observable
final class MarkdownDocument {
  /// A disk-side change the user has to decide on.
  enum DiskIssue: Equatable {
    case changedOnDisk(String)
    case deleted
  }

  private static let logger = SupaLogger("MarkdownDocument")
  static let autosaveDelay: Duration = .seconds(1)

  let fileURL: URL
  /// The editor buffer, LF-only.
  var text: String {
    didSet {
      guard text != oldValue else { return }
      refreshDirty()
      scheduleAutosave()
    }
  }
  /// What the file held after our last load or save.
  private(set) var savedText: String {
    didSet { refreshDirty() }
  }
  /// Stored, not derived: the tab chrome observes it, and a derived value would
  /// re-render the tab on every keystroke.
  private(set) var isDirty = false
  private(set) var diskIssue: DiskIssue?
  /// Set when the file could not be read at all (missing, not UTF-8).
  private(set) var loadError: String?
  private(set) var saveError: String?
  /// Bumped when the buffer is replaced from disk, so the view can tell a
  /// reload apart from typing.
  private(set) var reloadGeneration = 0

  @ObservationIgnored private var codec = MarkdownTextCodec()
  @ObservationIgnored private var autosaveTask: Task<Void, Never>?
  @ObservationIgnored private var watcher: MarkdownFileWatcher?
  @ObservationIgnored @Dependency(\.continuousClock) private var clock

  /// Unsaved edits that closing would lose: a pending disk conflict or a failed
  /// save blocks the save-on-close.
  var hasUnsavableChanges: Bool {
    isDirty && (diskIssue != nil || saveError != nil)
  }

  init(fileURL: URL) {
    self.fileURL = fileURL
    let loaded = Self.read(fileURL)
    switch loaded {
    case .success(let decoded):
      text = decoded.text
      savedText = decoded.text
      codec = decoded.codec
    case .failure(let error):
      text = ""
      savedText = ""
      loadError = error.message
      Self.logger.warning("Failed to load \(fileURL.lastPathComponent): \(error.message)")
    }
  }

  nonisolated deinit {}

  func startWatching() {
    guard watcher == nil else { return }
    let watcher = MarkdownFileWatcher(fileURL: fileURL) { [weak self] in
      self?.reconcileWithDisk()
    }
    if !watcher.start() {
      Self.logger.info("Cannot watch \(fileURL.lastPathComponent) yet; it does not exist.")
    }
    self.watcher = watcher
  }

  /// Saves pending edits (unless a disk conflict is unresolved) and stops
  /// watching.
  func close() {
    autosaveTask?.cancel()
    autosaveTask = nil
    if isDirty, diskIssue == nil, loadError == nil {
      save()
    }
    watcher?.stop()
    watcher = nil
  }

  /// Writes the buffer atomically. A write into a deleted file recreates it.
  @discardableResult
  func save() -> Bool {
    autosaveTask?.cancel()
    autosaveTask = nil
    guard loadError == nil else { return false }
    guard isDirty || diskIssue == .deleted else { return true }
    do {
      try codec.encode(text).write(to: fileURL, options: .atomic)
      savedText = text
      saveError = nil
      if diskIssue != nil {
        diskIssue = nil
        // The watcher lost the inode when the file went away.
        watcher?.start()
      }
      Self.logger.debug("Saved \(fileURL.lastPathComponent)")
      return true
    } catch {
      saveError = error.localizedDescription
      Self.logger.error("Failed to save \(fileURL.lastPathComponent): \(error.localizedDescription)")
      return false
    }
  }

  /// Takes the disk version, dropping unsaved edits.
  func reloadFromDisk() {
    switch Self.read(fileURL) {
    case .success(let decoded):
      codec = decoded.codec
      applyDiskText(decoded.text)
    case .failure:
      diskIssue = .deleted
    }
  }

  /// Keeps the buffer and overwrites the disk version with it.
  func keepBufferOverDisk() {
    guard case .changedOnDisk(let disk) = diskIssue else { return }
    savedText = disk
    diskIssue = nil
    save()
  }

  private func refreshDirty() {
    let dirty = text != savedText
    if dirty != isDirty { isDirty = dirty }
  }

  private func scheduleAutosave() {
    autosaveTask?.cancel()
    // Never write over an unresolved disk change or an unreadable file.
    guard diskIssue == nil, loadError == nil else { return }
    autosaveTask = Task { [weak self, clock] in
      try? await clock.sleep(for: Self.autosaveDelay)
      guard !Task.isCancelled else { return }
      self?.save()
    }
  }

  private func reconcileWithDisk() {
    let disk: String?
    switch Self.read(fileURL) {
    case .success(let decoded):
      disk = decoded.text
      codec = decoded.codec
    case .failure:
      disk = nil
    }
    switch MarkdownDiskReconciliation.decide(disk: disk, saved: savedText, isDirty: isDirty) {
    case .ignore:
      return
    case .reload(let text):
      Self.logger.debug("Reloaded \(fileURL.lastPathComponent) after an external change")
      applyDiskText(text)
    case .conflict(let text):
      Self.logger.info("External change to \(fileURL.lastPathComponent) conflicts with unsaved edits")
      autosaveTask?.cancel()
      diskIssue = .changedOnDisk(text)
    case .deleted:
      Self.logger.info("\(fileURL.lastPathComponent) was deleted on disk")
      autosaveTask?.cancel()
      diskIssue = .deleted
    }
  }

  private func applyDiskText(_ disk: String) {
    autosaveTask?.cancel()
    savedText = disk
    diskIssue = nil
    loadError = nil
    reloadGeneration += 1
    text = disk
    // `text`'s didSet scheduled a no-op save; drop it.
    autosaveTask?.cancel()
    autosaveTask = nil
  }

  private struct ReadError: Error {
    let message: String
  }

  private static func read(_ url: URL) -> Result<(text: String, codec: MarkdownTextCodec), ReadError> {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      return .failure(ReadError(message: error.localizedDescription))
    }
    guard let decoded = MarkdownTextCodec.decode(data) else {
      return .failure(ReadError(message: "The file is not valid UTF-8 text."))
    }
    return .success(decoded)
  }
}
