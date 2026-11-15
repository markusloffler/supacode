import Foundation

/// Loads the bundled markdown for the skills installed into coding agent configs.
public nonisolated enum CLISkillContent {
  static let cliSkillName = "supacode-cli"
  static let deeplinksSkillName = "supacode-deeplinks"
  static let showMeSkillName = "show-me"

  /// Every generated skill, in install order. Install, update and uninstall cover them all.
  static let skillNames = [cliSkillName, deeplinksSkillName, showMeSkillName]

  /// SKILL.md content for the CLI skill.
  static func cliSkill() throws -> String {
    try cliSkillCache.get()
  }

  /// SKILL.md content for the deeplinks skill.
  static func deeplinksSkill() throws -> String {
    try deeplinksSkillCache.get()
  }

  /// SKILL.md content for the show-me skill (`supacode show`).
  static func showMeSkill() throws -> String {
    try showMeSkillCache.get()
  }

  // The bundled markdown is immutable for the process lifetime; read it once.
  private static let cliSkillCache = Result { try bundled(cliSkillName) }
  private static let deeplinksSkillCache = Result { try bundled(deeplinksSkillName) }
  private static let showMeSkillCache = Result { try bundled(showMeSkillName) }

  /// The bundled markdown is missing from the app bundle (packaging bug).
  struct MissingResourceError: Error, LocalizedError {
    let skill: String

    var errorDescription: String? {
      "The bundled \(skill) skill is missing from the app bundle. Reinstall Supacode to repair it."
    }
  }

  /// Bundled markdown files surfaced as links in Developer settings.
  public static var cliSkillFileURL: URL? { skillURL(cliSkillName) }

  public static var deeplinksSkillFileURL: URL? { skillURL(deeplinksSkillName) }

  private static func skillURL(_ skill: String) -> URL? {
    Bundle.module.url(forResource: skill, withExtension: "md", subdirectory: "Skills")
  }

  private static func bundled(_ skill: String) throws -> String {
    guard let url = skillURL(skill) else { throw MissingResourceError(skill: skill) }
    return try String(contentsOf: url, encoding: .utf8)
  }
}
