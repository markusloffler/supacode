import AppKit
import QuickLookUI
import SupacodeSettingsShared
import SwiftUI

/// Read-only Quick Look preview for files neither the Markdown nor the code
/// editor takes (images, PDFs, archives, packages). It shares the editors'
/// content kind and persisted state (a relative path), so routing, the shared
/// editor pane and layout restore treat it alike; the builder picks it by file
/// type. The preview refreshes when the file changes on disk.
@MainActor
final class QuickLookContent: TabContent {
  private static let logger = SupaLogger("QuickLook")

  let id: ContentID
  let kind: ContentKind = .markdown
  private let state: MarkdownContentState
  private let fileURL: URL
  private let quickLookChrome: QuickLookTabChrome
  private var previewView: QLPreviewView?
  private var watcher: MarkdownFileWatcher?

  init(id: ContentID, state: MarkdownContentState, fileURL: URL) {
    self.id = id
    self.state = state
    self.fileURL = fileURL
    self.quickLookChrome = QuickLookTabChrome(fileName: state.fileName)
  }

  nonisolated deinit {}

  var renderer: NSView? { previewView }

  var chrome: (any TabChrome)? { quickLookChrome }

  func startSession(at geometry: ContentGeometry) {
    guard previewView == nil else { return }
    Self.logger.debug("Previewing \(state.relativePath)")
    guard let view = QLPreviewView(frame: .zero, style: .normal) else {
      Self.logger.error("Could not create a Quick Look view for \(state.relativePath)")
      return
    }
    view.autostarts = true
    view.shouldCloseWithWindow = false
    view.previewItem = fileURL as NSURL
    previewView = view
    let watcher = MarkdownFileWatcher(fileURL: fileURL) { [weak self] in
      self?.refresh()
    }
    watcher.start()
    self.watcher = watcher
  }

  func hibernate() {
    tearDown()
  }

  func tearDown() {
    watcher?.stop()
    watcher = nil
    previewView?.close()
    previewView = nil
  }

  func snapshot() -> ContentSnapshot {
    ContentSnapshot(id: id, state: .markdown(state))
  }

  private func refresh() {
    Self.logger.debug("File changed on disk, refreshing preview of \(state.relativePath)")
    // Reassign rather than `refreshPreviewItem()`: an atomic save replaces the
    // inode, and Quick Look caches the old one.
    previewView?.previewItem = fileURL as NSURL
  }
}

/// Tab chrome for a Quick Look preview: the file name as title.
@MainActor
final class QuickLookTabChrome: TabChrome {
  private let fileName: String

  init(fileName: String) {
    self.fileName = fileName
  }

  nonisolated deinit {}

  var accessory: AnyView? { nil }

  var isWorking: Bool { false }

  var progress: TerminalTabProgressDisplay? { nil }

  var isReadOnly: Bool { false }

  var reportedTitle: String? { fileName }
}
