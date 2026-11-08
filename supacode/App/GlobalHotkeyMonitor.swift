import AppKit
import Carbon.HIToolbox
import SupacodeSettingsShared

// Owns the process-wide Carbon hot keys: one `EventHandlerRef` for the app's
// life, at most one live `EventHotKeyRef` per `Slot` (so re-recording can't
// leak), and a callback that only forwards the pressed slot to `onFired`.
@MainActor
final class GlobalHotkeyMonitor {
  enum Slot: UInt32, CaseIterable, Sendable {
    case toggleVisibility = 1
    case jumpToLatestUnread = 2
  }

  // Fired on the main actor with the slot whose chord was pressed. The scene
  // installs it (it needs SwiftUI's `openWindow`); the monitor owns no policy.
  var onFired: (@MainActor (Slot) -> Void)?

  private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
  private var eventHandler: EventHandlerRef?
  // False when `InstallEventHandler` failed: presses would never be delivered,
  // so registration must refuse rather than report a phantom success.
  private var isHandlerInstalled = false

  private static let logger = SupaLogger("GlobalHotkey")
  // Identifies our hot keys in the shared application event target.
  private static let hotKeySignature = fourCharCode("SPCD")

  init() {
    installEventHandler()
  }

  // Registers `override` as the chord for `slot`, replacing any prior one. A nil or
  // disabled override just clears it. Returns false when Carbon refuses the
  // registration (e.g. the chord is already claimed system-wide).
  @discardableResult
  func apply(_ override: AppShortcutOverride?, for slot: Slot) -> Bool {
    unregister(slot)
    guard let override, override.isEnabled else { return true }
    guard isHandlerInstalled else {
      Self.logger.error("Refusing to register \(override.displayString): the event handler never installed.")
      return false
    }
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(override.keyCode),
      override.carbonModifierFlags,
      EventHotKeyID(signature: Self.hotKeySignature, id: slot.rawValue),
      GetApplicationEventTarget(),
      0,
      &ref
    )
    guard status == noErr, let ref else {
      Self.logger.error("RegisterEventHotKey failed with status \(status) for \(override.displayString).")
      return false
    }
    hotKeyRefs[slot] = ref
    return true
  }

  // Releases the global registration and the shared handler explicitly at
  // termination, ahead of the deinit's own backstop cleanup.
  func tearDown() {
    Slot.allCases.forEach(unregister)
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  nonisolated deinit {
    MainActor.assumeIsolated {
      hotKeyRefs.values.forEach { UnregisterEventHotKey($0) }
      if let eventHandler { RemoveEventHandler(eventHandler) }
    }
  }

  private func unregister(_ slot: Slot) {
    guard let hotKeyRef = hotKeyRefs.removeValue(forKey: slot) else { return }
    UnregisterEventHotKey(hotKeyRef)
  }

  private func installEventHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let callback: EventHandlerUPP = { _, event, userData in
      guard let userData, let event else { return OSStatus(eventNotHandledErr) }
      var pressedID = EventHotKeyID()
      let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &pressedID
      )
      guard status == noErr, pressedID.signature == GlobalHotkeyMonitor.hotKeySignature,
        let slot = GlobalHotkeyMonitor.Slot(rawValue: pressedID.id)
      else {
        return OSStatus(eventNotHandledErr)
      }
      // Carbon delivers on the main run loop, so the monitor is already isolated.
      MainActor.assumeIsolated {
        let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
        guard let onFired = monitor.onFired else {
          GlobalHotkeyMonitor.logger.error("Hotkey fired before the scene wired its sink; press dropped.")
          return
        }
        GlobalHotkeyMonitor.logger.debug("Global hotkey fired for slot \(slot).")
        onFired(slot)
      }
      return noErr
    }
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      callback,
      1,
      &spec,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
    guard status == noErr else {
      Self.logger.error("InstallEventHandler failed with status \(status); the global hotkey is inert.")
      return
    }
    isHandlerInstalled = true
  }

  private static func fourCharCode(_ string: String) -> FourCharCode {
    var code: FourCharCode = 0
    for scalar in string.unicodeScalars.prefix(4) {
      code = (code << 8) + FourCharCode(scalar.value & 0xFF)
    }
    return code
  }
}
