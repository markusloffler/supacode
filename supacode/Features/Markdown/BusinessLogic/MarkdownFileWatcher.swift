import Dispatch
import Foundation
import SupacodeSettingsShared

/// Watches one file for changes. Agents and editors save atomically (write a
/// temp file, rename over the original), which retires the watched inode, so a
/// delete or rename re-arms on the path after a short delay.
@MainActor
final class MarkdownFileWatcher {
  private static let logger = SupaLogger("MarkdownFileWatcher")
  /// Re-arm attempts after the inode went away, so an atomic replace that lands
  /// slightly later is still picked up before the file counts as deleted.
  private static let rearmDelays: [Duration] = [.milliseconds(50), .milliseconds(200), .milliseconds(800)]

  private let fileURL: URL
  private let onChange: @MainActor () -> Void
  private var source: (any DispatchSourceFileSystemObject)?
  private var rearmTask: Task<Void, Never>?

  init(fileURL: URL, onChange: @escaping @MainActor () -> Void) {
    self.fileURL = fileURL
    self.onChange = onChange
  }

  nonisolated deinit {}

  /// Starts watching; returns false when the file cannot be opened.
  @discardableResult
  func start() -> Bool {
    stopSource()
    let descriptor = open(fileURL.path(percentEncoded: false), O_EVTONLY)
    guard descriptor >= 0 else { return false }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .extend, .delete, .rename, .attrib],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        self?.handle(source.data)
      }
    }
    source.setCancelHandler {
      close(descriptor)
    }
    self.source = source
    source.resume()
    return true
  }

  func stop() {
    rearmTask?.cancel()
    rearmTask = nil
    stopSource()
  }

  private func stopSource() {
    source?.cancel()
    source = nil
  }

  private func handle(_ events: DispatchSource.FileSystemEvent) {
    guard events.contains(.delete) || events.contains(.rename) else {
      onChange()
      return
    }
    // The watched inode is gone; follow the path to its replacement.
    stopSource()
    rearmTask?.cancel()
    rearmTask = Task { [weak self] in
      for delay in Self.rearmDelays {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, let self else { return }
        if self.start() {
          self.onChange()
          return
        }
      }
      guard !Task.isCancelled, let self else { return }
      Self.logger.info("Watched file vanished: \(self.fileURL.lastPathComponent)")
      self.onChange()
    }
  }
}
