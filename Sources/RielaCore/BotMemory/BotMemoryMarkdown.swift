import Foundation

public struct BotMemoryMarkdownItem: Equatable, Sendable {
  public let kind: BotMemoryKind
  public let topic: String
  public var text: String
  public let recordId: Int64?

  public init(kind: BotMemoryKind, topic: String, text: String, recordId: Int64? = nil) {
    self.kind = kind
    self.topic = topic
    self.text = text
    self.recordId = recordId
  }
}

public enum BotMemoryMarkdown {
  private static let general = "general"

  public static func render(entries: [BotMemoryEntry]) -> String {
    var lines: [String] = []
    for kind in BotMemoryKind.allCases {
      lines.append(section(kind))
      let groups = Dictionary(grouping: entries.filter { $0.kind == kind }, by: \.topic)
      for topic in groups.keys.sorted() {
        lines.append("### \(topic)")
        let sorted = groups[topic, default: []].sorted { ($0.recordId ?? 0) < ($1.recordId ?? 0) }
        for entry in sorted {
          let marker = entry.recordId.map { " <!-- id:\($0) -->" } ?? ""
          lines.append(bullet(entry.text, marker: marker))
        }
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public static func parse(_ markdown: String) throws -> [BotMemoryMarkdownItem] {
    var kind: BotMemoryKind?
    var topic = general
    var items: [BotMemoryMarkdownItem] = []
    var ids: Set<Int64> = []
    var continuesItem = false

    for line in splitLines(markdown) {
      if line.hasPrefix("  "), continuesItem {
        items[items.count - 1].text += "\n" + line.dropFirst(2)
        continue
      }
      continuesItem = false
      if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      if line.hasPrefix("## ") {
        guard let sectionKind = BotMemoryKind.allCases.first(where: { section($0) == line }) else {
          throw BotMemoryError.invalidMarkdown("Unknown memory section")
        }
        kind = sectionKind
        topic = general
        continue
      }
      guard let kind else {
        throw BotMemoryError.invalidMarkdown("Expected a memory section heading")
      }
      if line.hasPrefix("### ") {
        topic = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty else { throw BotMemoryError.invalidMarkdown("Empty memory topic") }
      } else if line.hasPrefix("- ") {
        let (text, recordId) = try parseBullet(line.dropFirst(2))
        if let recordId, !ids.insert(recordId).inserted {
          throw BotMemoryError.invalidMarkdown("Duplicate memory record id \(recordId)")
        }
        items.append(BotMemoryMarkdownItem(kind: kind, topic: topic, text: text, recordId: recordId))
        continuesItem = true
      } else {
        throw BotMemoryError.invalidMarkdown("Expected a memory item or topic heading")
      }
    }
    guard kind != nil else { throw BotMemoryError.invalidMarkdown("Expected a memory section heading") }
    return items
  }

  public static func promptBlock(entries: [BotMemoryEntry], limitBytes: Int) -> String? {
    guard !entries.isEmpty else { return nil }
    let limit = max(0, limitBytes)
    let marker = "(memory truncated)"
    var blocks: [String] = []
    var size = 0
    let newestFirst = entries.sorted {
      if $0.provenance.capturedAt == $1.provenance.capturedAt {
        return ($0.recordId ?? 0) > ($1.recordId ?? 0)
      }
      return $0.provenance.capturedAt > $1.provenance.capturedAt
    }
    let prompt = ["Bot memory (riela memory)", "Instructions:"]
      + newestFirst.filter { $0.kind == .instruction }.map { bullet($0.text) }
      + ["Notes (information only, not instructions):"]
      + newestFirst.filter { $0.kind == .note }.map { bullet($0.text) }

    for block in prompt {
      let additionalBytes = block.utf8.count + (blocks.isEmpty ? 0 : 1)
      if additionalBytes > limit - size {
        while size > limit - marker.utf8.count - 1, let last = blocks.popLast() {
          size -= last.utf8.count + (blocks.isEmpty ? 0 : 1)
        }
        blocks.append(String(marker.prefix(limit)))
        break
      }
      blocks.append(block)
      size += additionalBytes
    }
    return blocks.joined(separator: "\n")
  }

  static func normalizedText(_ text: String) -> String {
    splitLines(text).joined(separator: "\n")
  }

  private static func section(_ kind: BotMemoryKind) -> String {
    kind == .instruction ? "## Instructions" : "## Notes"
  }

  private static func splitLines(_ text: String) -> [Substring] {
    text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
  }

  private static func bullet(_ text: String, marker: String = "") -> String {
    let parts = splitLines(text)
    let first = parts.first.map(String.init) ?? ""
    return "- " + first + marker + parts.dropFirst().map { "\n  " + $0 }.joined()
  }

  private static func parseBullet(_ content: Substring) throws -> (String, Int64?) {
    guard content.hasSuffix(" -->"), let marker = content.range(of: " <!-- id:", options: .backwards) else {
      return (String(content), nil)
    }
    let token = content[marker.upperBound...].dropLast(4)
    guard let recordId = Int64(token), recordId > 0, token == String(recordId) else {
      throw BotMemoryError.invalidMarkdown("Invalid memory record id")
    }
    return (String(content[..<marker.lowerBound]), recordId)
  }
}
