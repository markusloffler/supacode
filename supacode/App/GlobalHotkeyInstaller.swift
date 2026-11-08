import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

// Installs the hotkey sink from the main window's scene, where `openWindow` is
// reachable, and never clears it so a chord can reopen a closed window.
struct GlobalHotkeyInstaller: View {
  let monitor: GlobalHotkeyMonitor
  let store: StoreOf<AppFeature>
  @Environment(\.openWindow) private var openWindow

  private static let logger = SupaLogger("GlobalHotkey")

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onAppear {
        monitor.onFired = { slot in
          switch slot {
          case .toggleVisibility: toggleVisibility()
          case .jumpToLatestUnread: jumpToLatestUnread()
          }
        }
      }
  }

  private func toggleVisibility() {
    let app = NSApplication.shared
    let hasVisibleMain =
      app.mainWindowCandidate().map {
        $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace
      } ?? false
    switch GlobalHotkeyToggle.resolve(isActive: app.isActive, hasVisibleMain: hasVisibleMain) {
    case .hide:
      Self.logger.info("[USER] Global hotkey: hide Supacode")
      app.hide(nil)
    case .show:
      Self.logger.info("[USER] Global hotkey: show Supacode")
      surfaceMainWindow()
    }
  }

  // Always surfaces (never hides), then jumps; the reducer no-ops when nothing is unread.
  private func jumpToLatestUnread() {
    Self.logger.info("[USER] Global hotkey: jump to latest unread")
    surfaceMainWindow()
    store.send(.jumpToLatestUnread)
  }

  private func surfaceMainWindow() {
    openWindow(id: WindowID.main)
    NSApplication.shared.surfaceMainWindow()
  }
}
