import Carbon.HIToolbox
import GhosttyKit

/// Types text into a live terminal surface without taking focus. The text goes
/// in as a paste (bracketed when the TUI enabled it), then a separate Return key
/// submits it: a `\r` inside the paste would land as a literal newline.
@MainActor
enum TerminalInjector {
  /// Gap between the paste and the Return, so the TUI has consumed the paste
  /// before the submit arrives.
  static let submitDelay: Duration = .milliseconds(80)

  static func paste(_ text: String, into surface: GhosttySurfaceView) {
    surface.sendText(text)
  }

  /// Synthesizes a Return press and release.
  static func submit(_ surface: GhosttySurfaceView) {
    guard let handle = surface.surface else { return }
    for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
      var key = ghostty_input_key_s()
      key.action = action
      key.mods = GHOSTTY_MODS_NONE
      key.consumed_mods = GHOSTTY_MODS_NONE
      key.keycode = UInt32(kVK_Return)
      key.text = nil
      key.unshifted_codepoint = 0x0D
      key.composing = false
      _ = ghostty_surface_key(handle, key)
    }
  }
}
