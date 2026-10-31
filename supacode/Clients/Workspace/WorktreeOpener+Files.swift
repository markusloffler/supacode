import AppKit
import SupacodeSettingsShared

private nonisolated let fileOpenerLogger = SupaLogger("FileOpener")

extension WorktreeOpener {
  /// Opens `fileURL` in `action` when it is an installed file-capable editor,
  /// otherwise in the system default application. `nil` means opened.
  static func openFile(_ fileURL: URL, action: OpenWorktreeAction?) async -> OpenActionError? {
    if let action, action.canOpenFiles {
      // An explicitly picked editor that vanished must surface, not silently
      // fall back to a different app.
      guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.bundleIdentifier)
      else { return .appNotFound(action) }
      return await withCheckedContinuation { continuation in
        NSWorkspace.shared.open(
          [fileURL],
          withApplicationAt: appURL,
          configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
          continuation.resume(returning: error.map { .openFailed(action, $0) })
        }
      }
    }
    return await withCheckedContinuation { continuation in
      NSWorkspace.shared.open(fileURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        continuation.resume(
          returning: error.map {
            OpenActionError(
              title: "Unable to open \(fileURL.lastPathComponent)",
              message: $0.localizedDescription
            )
          }
        )
      }
    }
  }

  /// `code <root> <file>`: opens (or reuses) the editor window for `root` and
  /// opens the file in it. Falls back to `openFile` when the editor has no such
  /// CLI or the CLI is missing from the app bundle.
  static func openFileInProject(_ fileURL: URL, root: URL, action: OpenWorktreeAction?) async -> OpenActionError? {
    guard let action,
      let invocation = action.projectFileOpenInvocation(
        rootPath: root.path(percentEncoded: false),
        filePath: fileURL.path(percentEncoded: false)
      ),
      let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.bundleIdentifier),
      let resolved = processInvocation(executable: invocation.executable, appURL: appURL)
    else {
      fileOpenerLogger.debug("openFileInProject: no project CLI for \(action?.title ?? "default app"), opening file.")
      return await openFile(fileURL, action: action)
    }
    let process = Process()
    process.executableURL = resolved.executableURL
    process.arguments = resolved.argumentPrefix + invocation.arguments
    do {
      try process.run()
      fileOpenerLogger.debug("openFileInProject: \(fileURL.lastPathComponent) in \(action.title) at \(root.path).")
      return nil
    } catch {
      return .openFailed(action, error)
    }
  }
}
