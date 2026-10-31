import AppKit

/// Confirmation for a sandbox restart: shows the extended launcher command line with
/// the agent's additions highlighted. Restart is the default button (Return), Abort
/// answers Escape.
@MainActor
enum SandboxRestartDialog {
  static func confirm(_ request: SandboxRestart.Request, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
    let alert = NSAlert()
    alert.messageText = "Restart with a wider sandbox?"
    alert.informativeText =
      "The agent asks to restart with this command line. Supacode exits the session and runs it, "
      + "resuming the conversation. Highlighted parts are new."
    alert.addButton(withTitle: "Restart")
    let abort = alert.addButton(withTitle: "Abort")
    abort.keyEquivalent = "\u{1b}"
    alert.accessoryView = commandView(for: request)
    let handle: (NSApplication.ModalResponse) -> Void = { completion($0 == .alertFirstButtonReturn) }
    if let window {
      alert.beginSheetModal(for: window, completionHandler: handle)
    } else {
      handle(alert.runModal())
    }
  }

  /// Alert accessory width; the command box fills it.
  private static let commandWidth: CGFloat = 640
  /// Inner padding between the box border and the command text.
  private static let boxPadding: CGFloat = 10
  /// Indent of every option line after the launcher (and of its wrapped continuation).
  private static let optionIndent: CGFloat = 16

  private static func commandView(for request: SandboxRestart.Request) -> NSView {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let indented = NSMutableParagraphStyle()
    indented.firstLineHeadIndent = Self.optionIndent
    indented.headIndent = Self.optionIndent
    let text = NSMutableAttributedString()
    // One option per line, each a paragraph; lines after the launcher are indented.
    for (index, line) in SandboxRestart.displayLines(of: request).enumerated() {
      let paragraph = index == 0 ? NSParagraphStyle.default : indented
      let plain: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
      ]
      // The text-selection background stays readable on the alert's grey in light and dark mode.
      var added = plain
      added[.backgroundColor] = NSColor.selectedTextBackgroundColor
      if index > 0 { text.append(NSAttributedString(string: "\n", attributes: plain)) }
      for (position, token) in line.enumerated() {
        if position > 0 { text.append(NSAttributedString(string: " ", attributes: plain)) }
        text.append(NSAttributedString(string: token.text, attributes: token.isAddition ? added : plain))
      }
    }
    let textWidth = Self.commandWidth - 2 * Self.boxPadding
    let field = NSTextField(labelWithAttributedString: text)
    field.isSelectable = true
    // Without this, the field editor that a click activates drops the font and highlighting.
    field.allowsEditingTextAttributes = true
    field.lineBreakMode = .byCharWrapping
    field.maximumNumberOfLines = 0
    field.preferredMaxLayoutWidth = textWidth
    let textHeight = field.fittingSize.height
    field.frame = NSRect(x: Self.boxPadding, y: Self.boxPadding, width: textWidth, height: textHeight)

    // A plain layer-bordered container with explicit frames: NSAlert keeps the accessory's
    // frame as given, whereas an NSBox collapsed its content to its default size.
    let box = NSView(
      frame: NSRect(x: 0, y: 0, width: Self.commandWidth, height: textHeight + 2 * Self.boxPadding))
    box.wantsLayer = true
    box.layer?.borderWidth = 1
    box.layer?.cornerRadius = 6
    box.layer?.borderColor = NSColor.separatorColor.cgColor
    box.addSubview(field)
    return box
  }
}
