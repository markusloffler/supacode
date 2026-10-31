import AppKit
import GhosttyKit
import Sharing
import SupacodeSettingsShared

/// Drives the sandbox-restart handshake for one worktree's surfaces (see
/// `SandboxRestart`): when an agent's turn ends with a restart marker on screen, asks
/// the user to confirm the framed command line (`SandboxRestartDialog`). On Restart it
/// exits the agent with `/exit`, waits for the shell to report the launcher finished,
/// then runs the command line.
@MainActor
final class SandboxRestartInjector {
  private static let logger = SupaLogger("SandboxRestart")
  /// Lets the TUI finish drawing the turn's last message before the screen is read.
  static let readDelay: Duration = .milliseconds(300)
  /// Lets the shell draw its prompt before the command line is typed.
  static let pasteDelay: Duration = .milliseconds(200)
  /// Gives up on a launcher that never reports finishing (no shell integration, or
  /// `/exit` did not take); nothing is typed then.
  static let exitTimeout: Duration = .seconds(15)

  @Shared(.settingsFile) private var settingsFile: SettingsFile
  private let liveSurface: (UUID) -> GhosttySurfaceView?
  private let clock: any Clock<Duration>
  /// Nonces already handled. A resumed session redraws its history, marker included,
  /// so each marker must prompt at most once.
  private var handledNonces: Set<String> = []
  /// Surfaces with an open confirmation dialog.
  private var confirming: Set<UUID> = []
  /// Command line waiting for its surface's launcher to exit, with the timeout task.
  private var pending: [UUID: (command: String, timeout: Task<Void, Never>)] = [:]

  init(clock: any Clock<Duration>, liveSurface: @escaping (UUID) -> GhosttySurfaceView?) {
    self.clock = clock
    self.liveSurface = liveSurface
  }

  nonisolated deinit {}

  /// Called for every agent `idle` signal. Cheap unless the viewport shows a marker.
  func agentBecameIdle(surfaceID: UUID) {
    guard settingsFile.global.sandboxRestartInjectionEnabled, !isBusy(surfaceID) else { return }
    Task { [weak self] in
      try? await self?.clock.sleep(for: Self.readDelay)
      self?.scan(surfaceID: surfaceID)
    }
  }

  /// Called when the surface's shell reports a command finished.
  func commandFinished(surfaceID: UUID) {
    guard let entry = pending.removeValue(forKey: surfaceID) else { return }
    entry.timeout.cancel()
    Task { [weak self] in
      try? await self?.clock.sleep(for: Self.pasteDelay)
      self?.run(entry.command, surfaceID: surfaceID)
    }
  }

  private func isBusy(_ surfaceID: UUID) -> Bool {
    confirming.contains(surfaceID) || pending[surfaceID] != nil
  }

  private func scan(surfaceID: UUID) {
    guard !isBusy(surfaceID), let surface = liveSurface(surfaceID),
      surface.readText(GHOSTTY_POINT_VIEWPORT)?.contains(SandboxRestart.restartMarkerPrefix) == true
    else { return }
    guard let text = surface.readText(GHOSTTY_POINT_SCREEN),
      let request = SandboxRestart.request(in: text)
    else {
      Self.logger.warning("Restart marker on surface \(surfaceID) without a valid command frame; ignoring.")
      return
    }
    guard handledNonces.insert(request.nonce).inserted else {
      Self.logger.debug("Restart marker \(request.nonce) already handled; ignoring.")
      return
    }
    Self.logger.info("Restart marker \(request.nonce) on surface \(surfaceID); asking for confirmation.")
    confirming.insert(surfaceID)
    SandboxRestartDialog.confirm(request, in: surface.window) { [weak self] restart in
      guard let self else { return }
      self.confirming.remove(surfaceID)
      guard restart else {
        Self.logger.info("[USER] Aborted sandbox restart \(request.nonce).")
        return
      }
      Self.logger.info("[USER] Confirmed sandbox restart \(request.nonce).")
      self.exitAgent(surfaceID: surfaceID, command: request.command)
    }
  }

  private func exitAgent(surfaceID: UUID, command: String) {
    guard let surface = liveSurface(surfaceID) else {
      Self.logger.warning("Surface \(surfaceID) gone before the agent could be exited.")
      return
    }
    let clock = clock
    let timeout = Task { [weak self] in
      guard (try? await clock.sleep(for: Self.exitTimeout)) != nil else { return }
      guard let self, self.pending.removeValue(forKey: surfaceID) != nil else { return }
      Self.logger.warning("Launcher on surface \(surfaceID) did not exit in time; command not run.")
    }
    pending[surfaceID] = (command, timeout)
    type("/exit", into: surface)
  }

  private func run(_ command: String, surfaceID: UUID) {
    guard let surface = liveSurface(surfaceID) else {
      Self.logger.warning("Surface \(surfaceID) gone before the restart command could be run.")
      return
    }
    Self.logger.info("Running restart command (\(command.count) chars) in surface \(surfaceID).")
    type(command, into: surface)
  }

  /// Pastes `text`, then submits it with a separate Return once the paste has landed.
  private func type(_ text: String, into surface: GhosttySurfaceView) {
    TerminalInjector.paste(text, into: surface)
    let clock = clock
    Task {
      try? await clock.sleep(for: TerminalInjector.submitDelay)
      TerminalInjector.submit(surface)
    }
  }
}
