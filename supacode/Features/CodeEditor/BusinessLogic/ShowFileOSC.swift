import Foundation
import SupacodeSettingsShared

/// OSC 3008 wire format for `supacode show`: the CLI writes it to the agent's
/// terminal instead of the control socket, so it also works from a sandboxed agent
/// that may write its tty but must not reach the socket.
///
/// Shape: `OSC 3008 ; start=supacode ; kind=show ; path=<base64> [; from=<pos> [; to=<pos>]] ST`,
/// `pos` being `LINE` or `LINE:COLUMN`. The path is standard base64 (no `;`), so any
/// file name is framing-safe. The emitter lives in `supacode-cli/Helpers/TerminalSignal.swift`,
/// which cannot link this target; keep the two in sync.
///
/// Unauthenticated like every terminal signal: anything that can write to the
/// terminal can send one. The receiver therefore only opens a file inside the
/// receiving surface's own local worktree.
nonisolated enum ShowFileOSC {
  static let contextID = "supacode"
  static let kind = "show"

  struct Request: Equatable, Sendable {
    let path: URL
    let selection: EditorSelection?
  }

  /// Cheap routing check, on the parsed `kind` field rather than a substring.
  static func isShowMetadata(_ metadata: String) -> Bool {
    AgentPresenceOSC.parseFields(metadata)?["kind"] == Substring(kind)
  }

  /// nil for anything but a well-formed request carrying an absolute path.
  static func parse(id: String, metadata: String) -> Request? {
    guard id == contextID, let fields = AgentPresenceOSC.parseFields(metadata),
      fields["kind"] == Substring(kind),
      let encoded = fields["path"], let data = Data(base64Encoded: String(encoded)),
      let path = String(data: data, encoding: .utf8), path.hasPrefix("/")
    else { return nil }
    let url = URL(filePath: path, directoryHint: .notDirectory)
    guard let from = fields["from"].map(String.init) else {
      guard fields["to"] == nil else { return nil }
      return Request(path: url, selection: nil)
    }
    guard let selection = EditorSelection(from: from, to: fields["to"].map(String.init)) else { return nil }
    return Request(path: url, selection: selection)
  }
}
