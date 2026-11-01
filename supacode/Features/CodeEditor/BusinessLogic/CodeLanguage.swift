import Foundation

/// Maps a file name to a highlight.js language. Only mapped files are
/// highlighted: an unknown language would make highlight.js auto-detect,
/// which tries every grammar and is far too slow for whole files.
nonisolated enum CodeLanguage {
  static func highlightName(forFileName fileName: String) -> String? {
    if let name = byFileName[fileName] { return name }
    let ext = (fileName as NSString).pathExtension.lowercased()
    return ext.isEmpty ? nil : byExtension[ext]
  }

  private static let byFileName: [String: String] = [
    "Makefile": "makefile", "GNUmakefile": "makefile", "makefile": "makefile",
    "Dockerfile": "dockerfile", "Containerfile": "dockerfile",
    "CMakeLists.txt": "cmake",
    "Gemfile": "ruby", "Rakefile": "ruby", "Podfile": "ruby", "Fastfile": "ruby", "Brewfile": "ruby",
    "Appfile": "ruby", "Matchfile": "ruby",
    ".bashrc": "bash", ".bash_profile": "bash", ".zshrc": "bash", ".zprofile": "bash", ".profile": "bash",
    ".envrc": "bash", ".gitconfig": "ini", ".editorconfig": "ini",
  ]

  private static let byExtension: [String: String] = [
    "swift": "swift",
    "py": "python", "pyi": "python",
    "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
    "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
    "json": "json", "jsonc": "json", "json5": "json", "resolved": "json",
    "yml": "yaml", "yaml": "yaml",
    "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini",
    "xml": "xml", "html": "xml", "htm": "xml", "svg": "xml", "plist": "xml", "xib": "xml",
    "storyboard": "xml", "entitlements": "xml", "xcscheme": "xml", "vue": "xml",
    "css": "css", "scss": "scss", "less": "less",
    "sh": "bash", "bash": "bash", "zsh": "bash", "command": "bash",
    "rb": "ruby", "rake": "ruby", "gemspec": "ruby",
    "go": "go", "rs": "rust", "java": "java", "kt": "kotlin", "kts": "kotlin",
    "c": "c", "h": "c",
    "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
    "m": "objectivec", "mm": "objectivec",
    "cs": "csharp", "php": "php", "sql": "sql", "lua": "lua", "pl": "perl", "pm": "perl",
    "r": "r", "scala": "scala", "dart": "dart", "ex": "elixir", "exs": "elixir", "erl": "erlang",
    "hs": "haskell", "clj": "clojure", "groovy": "groovy", "gradle": "groovy",
    "mk": "makefile", "dockerfile": "dockerfile", "cmake": "cmake",
    "diff": "diff", "patch": "diff", "properties": "properties", "proto": "protobuf",
    "graphql": "graphql", "gql": "graphql", "tex": "latex", "vim": "vim", "nginx": "nginx",
  ]
}
