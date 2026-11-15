import Darwin
import Foundation

/// Writes OSC signals to the Supacode terminal the CLI runs in. Unlike the
/// control socket this needs only the terminal device, which a sandboxed agent
/// may write (srt allows its own tty) but whose socket it must not reach.
nonisolated enum TerminalSignal {
  enum Failure: Error, CustomStringConvertible {
    case notInSupacode
    case noTerminal
    case writeFailed(path: String, errno: Int32)

    var description: String {
      switch self {
      case .notInSupacode:
        "Not running inside a Supacode terminal ($SUPACODE_SURFACE_ID is not set)."
      case .noTerminal:
        "Could not find the terminal this command runs in."
      case .writeFailed(let path, let code):
        "Could not write to \(path): \(String(cString: strerror(code)))."
      }
    }
  }

  /// `supacode show` request; parsed app-side by `ShowFileOSC`, keep in sync.
  static func showFile(path: String, from: String?, to: String?) -> String {
    var metadata = "kind=show;path=\(Data(path.utf8).base64EncodedString())"
    if let from { metadata += ";from=\(from)" }
    if let to { metadata += ";to=\(to)" }
    return "\u{1B}]3008;start=supacode;\(metadata)\u{1B}\\"
  }

  /// Sends `sequence` to the outermost controlling terminal among this process and
  /// its ancestors: the Supacode surface (or the zmx pty behind it). The nearest one
  /// can be a pty the agent made for its tools, which would swallow the sequence.
  static func send(_ sequence: String) throws {
    guard ProcessInfo.processInfo.environment["SUPACODE_SURFACE_ID"]?.isEmpty == false else {
      throw Failure.notInSupacode
    }
    guard let path = terminalPath() else { throw Failure.noTerminal }
    let fd = open(path, O_WRONLY | O_NOCTTY)
    guard fd >= 0 else { throw Failure.writeFailed(path: path, errno: errno) }
    defer { close(fd) }
    // One write keeps the sequence from interleaving with the agent's own output.
    let bytes = Array(sequence.utf8)
    let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard written == bytes.count else { throw Failure.writeFailed(path: path, errno: errno) }
  }

  private static func terminalPath() -> String? {
    // sysctl, not `ps`: a sandbox refuses to exec the setuid `ps`.
    var outermost: String?
    var pid = getpid()
    while pid > 1, let info = processInfo(pid) {
      let device = info.kp_eproc.e_tdev
      if device != -1, let name = devname(device, S_IFCHR) {
        let tty = String(cString: name)
        if tty != "??" { outermost = "/dev/\(tty)" }
      }
      pid = info.kp_eproc.e_ppid
    }
    return outermost
  }

  private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
  }
}
