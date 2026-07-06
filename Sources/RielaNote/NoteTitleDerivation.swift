import Foundation

public enum NoteTitleDerivation {
  public static let fallbackTitleLimit = 120

  public static func title(from bodyMarkdown: String) -> String? {
    let lines = bodyMarkdown.split(separator: "\n", omittingEmptySubsequences: false)
    if let headingTitle = lines.compactMap(markdownHeadingTitle).first {
      return headingTitle
    }
    return lines.compactMap(firstLineTitle).first
  }

  public static func fallbackTitle(from bodyMarkdown: String, defaultTitle: String = "Untitled") -> String {
    title(from: bodyMarkdown) ?? defaultTitle
  }

  private static func markdownHeadingTitle(_ line: Substring) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var hashCount = 0
    for character in trimmed {
      guard character == "#" else {
        break
      }
      hashCount += 1
    }
    guard (1...6).contains(hashCount),
          trimmed.dropFirst(hashCount).first?.isWhitespace == true
    else {
      return nil
    }
    let title = trimmed.dropFirst(hashCount).trimmingCharacters(in: .whitespacesAndNewlines)
    return cappedTitle(title)
  }

  private static func firstLineTitle(_ line: Substring) -> String? {
    var title = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      return nil
    }
    title = title.replacingOccurrences(
      of: #"^\s{0,3}>\s*"#,
      with: "",
      options: .regularExpression
    )
    title = title.replacingOccurrences(
      of: #"^\s{0,3}([-+*]|\d+[.)])\s+"#,
      with: "",
      options: .regularExpression
    )
    title = title.replacingOccurrences(
      of: #"^#{1,6}\s+"#,
      with: "",
      options: .regularExpression
    )
    title = title.trimmingCharacters(in: CharacterSet(charactersIn: "#*_`[]()").union(.whitespacesAndNewlines))
    return cappedTitle(title)
  }

  private static func cappedTitle(_ title: String) -> String? {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return nil
    }
    return String(normalized.prefix(fallbackTitleLimit))
  }
}
