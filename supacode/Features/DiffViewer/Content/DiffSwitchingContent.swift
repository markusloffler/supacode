import AppKit
import SwiftUI

/// Wraps an editor or viewer tab (Markdown, code, Quick Look) so it can show
/// the file's uncommitted changes instead. The diff mode is one app-wide
/// setting, toggled from the docked toolbar, so it stays on while other files
/// open. Everything else forwards to the wrapped content.
@MainActor
final class DiffSwitchingContent: TabContent {
  let inner: any TabContent
  let diffModel: DiffViewerModel
  private let diffToolbar: EditorDiffToolbar
  private let onClick: () -> Void
  private var container: DiffSwitchHostingView?

  init(inner: any TabContent, diffModel: DiffViewerModel, onClick: @escaping () -> Void) {
    self.inner = inner
    self.diffModel = diffModel
    self.onClick = onClick
    self.diffToolbar = EditorDiffToolbar(model: diffModel)
  }

  nonisolated deinit {}

  /// The wrapped content when `content` is a diff switch, else `content`.
  static func unwrapped(_ content: (any TabContent)?) -> (any TabContent)? {
    (content as? DiffSwitchingContent)?.inner ?? content
  }

  var id: ContentID { inner.id }

  var kind: ContentKind { inner.kind }

  var renderer: NSView? { container }

  var isBusy: Bool { inner.isBusy }

  var isHibernatable: Bool { inner.isHibernatable }

  var chrome: (any TabChrome)? { inner.chrome }

  var toolbar: (any TabContentToolbar)? { diffToolbar }

  func startSession(at geometry: ContentGeometry) {
    inner.startSession(at: geometry)
    guard container == nil else { return }
    container = DiffSwitchHostingView(
      rootView: DiffSwitchView(editor: inner.renderer, diffModel: diffModel),
      onClick: onClick
    )
  }

  func hibernate() {
    inner.hibernate()
    dropContainer()
  }

  func tearDown() {
    inner.tearDown()
    dropContainer()
  }

  func snapshot() -> ContentSnapshot {
    inner.snapshot()
  }

  private func dropContainer() {
    diffModel.deactivate()
    container = nil
  }
}

/// The docked bar of a diff-switchable tab.
@MainActor
final class EditorDiffToolbar: TabContentToolbar {
  private let model: DiffViewerModel

  init(model: DiffViewerModel) {
    self.model = model
  }

  nonisolated deinit {}

  var view: AnyView? { AnyView(EditorDiffToolbarView(model: model)) }
}
