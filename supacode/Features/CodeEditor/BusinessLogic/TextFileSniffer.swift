import Foundation

/// Decides by content whether a file opens in the code editor: a regular file
/// within the size limit whose leading bytes are UTF-8 text without NULs.
nonisolated enum TextFileSniffer {
  /// Larger files keep opening in the project's editor.
  static let maxFileSize = 2 * 1024 * 1024
  static let sampleSize = 8192

  static func isEditableText(_ url: URL) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      (values.fileSize ?? 0) <= maxFileSize,
      let handle = try? FileHandle(forReadingFrom: url)
    else { return false }
    defer { try? handle.close() }
    guard let sample = try? handle.read(upToCount: sampleSize) else { return true }
    return isText(sample, truncated: sample.count == sampleSize)
  }

  /// `truncated` tolerates a multi-byte character cut off by the sample end.
  static func isText(_ sample: Data, truncated: Bool) -> Bool {
    guard !sample.contains(0) else { return false }
    let tolerance = truncated ? min(3, sample.count) : 0
    return (0...tolerance).contains { String(data: sample.dropLast($0), encoding: .utf8) != nil }
  }
}
