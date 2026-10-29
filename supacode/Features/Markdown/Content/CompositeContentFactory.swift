import Foundation

/// Dispatches content requests by kind, so the terminal builder stays
/// terminal-only.
enum CompositeContentFactory {
  static func make(terminal: LayoutContentFactory, markdown: MarkdownContentBuilder) -> LayoutContentFactory {
    LayoutContentFactory { request in
      switch request.content {
      case .markdown(let state):
        markdown.make(request, state: state)
      case .terminal:
        terminal.make(request)
      }
    }
  }
}
