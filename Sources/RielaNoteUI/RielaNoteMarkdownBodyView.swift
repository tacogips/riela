import Foundation
import SwiftUI

public struct RielaNoteMarkdownBodyView: View {
  private let markdown: String

  public init(markdown: String) {
    self.markdown = markdown
  }

  public var body: some View {
    // Parse lazily and via the memo cache: the parse is deferred out of `init`
    // so a view built but never rendered (e.g. a collapsed comment group) never
    // parses, and an unchanged body re-render is served from the cache.
    let blocks = RielaNoteMarkdownBlockCache.shared.blocks(for: markdown)
    LazyVStack(alignment: .leading, spacing: 12) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func blockView(_ block: RielaNoteMarkdownBlock) -> some View {
    switch block.kind {
    case .heading(let level):
      Text(block.inlineAttributedText)
        .font(level <= 1 ? .title2 : .headline)
        .fontWeight(.semibold)
    case .code:
      Text(block.text)
        .font(.body.monospaced())
        .padding(10)
        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    case .list:
      Text(block.inlineAttributedText)
        .font(.body)
        .lineSpacing(5)
    case .quote:
      Text(block.inlineAttributedText)
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(.secondary.opacity(0.35))
            .frame(width: 3)
        }
    case .rule:
      Divider()
    case .paragraph:
      Text(block.inlineAttributedText)
        .font(.body)
        .lineSpacing(5)
    }
  }
}

/// Process-wide memo cache for parsed markdown blocks, keyed on the raw markdown
/// string. A given body is parsed at most once regardless of how many view
/// instances request it, so identical re-renders skip the parse entirely.
final class RielaNoteMarkdownBlockCache: @unchecked Sendable {
  static let shared = RielaNoteMarkdownBlockCache()

  private let lock = NSLock()
  private var entries: [String: [RielaNoteMarkdownBlock]] = [:]
  private var insertionOrder: [String] = []
  private let capacity: Int

  /// Number of actual `RielaNoteMarkdownBlock.parse` invocations (cache misses).
  /// Exposed for tests that assert an unchanged body does not re-parse.
  private(set) var parseCount = 0

  init(capacity: Int = 64) {
    self.capacity = capacity
  }

  func blocks(for markdown: String) -> [RielaNoteMarkdownBlock] {
    lock.lock()
    defer { lock.unlock() }
    if let cached = entries[markdown] {
      return cached
    }
    let parsed = RielaNoteMarkdownBlock.parse(markdown)
    parseCount += 1
    entries[markdown] = parsed
    insertionOrder.append(markdown)
    if insertionOrder.count > capacity {
      let evicted = insertionOrder.removeFirst()
      entries[evicted] = nil
    }
    return parsed
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    entries.removeAll()
    insertionOrder.removeAll()
    parseCount = 0
  }
}

struct RielaNoteMarkdownBlock: Equatable {
  enum Kind: Equatable {
    case heading(level: Int)
    case paragraph
    case code
    case list
    case quote
    case rule
  }

  var kind: Kind
  var text: String

  var inlineAttributedText: AttributedString {
    (try? AttributedString(
      markdown: text,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
  }

  static func parse(_ markdown: String) -> [RielaNoteMarkdownBlock] {
    var blocks: [RielaNoteMarkdownBlock] = []
    var paragraph: [String] = []
    var code: [String] = []
    var codeFence: MarkdownCodeFence?

    func flushParagraph() {
      guard !paragraph.isEmpty else {
        return
      }
      let text = paragraph.joined(separator: "\n")
      let kind = paragraphKind(for: text)
      blocks.append(RielaNoteMarkdownBlock(kind: kind, text: displayText(text, for: kind)))
      paragraph.removeAll()
    }

    for rawLine in markdown.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if let activeFence = codeFence {
        if activeFence.isClosed(by: rawLine) {
          blocks.append(RielaNoteMarkdownBlock(kind: .code, text: code.joined(separator: "\n")))
          code.removeAll()
          codeFence = nil
          continue
        }
        code.append(rawLine)
        continue
      }
      if let openingFence = MarkdownCodeFence(openingLine: rawLine) {
        flushParagraph()
        codeFence = openingFence
        continue
      }
      if line.isEmpty {
        flushParagraph()
        continue
      }
      if let heading = headingBlock(from: rawLine) {
        flushParagraph()
        blocks.append(heading)
        continue
      }
      if isRule(line) {
        flushParagraph()
        blocks.append(RielaNoteMarkdownBlock(kind: .rule, text: ""))
        continue
      }
      paragraph.append(rawLine)
    }
    if codeFence != nil {
      blocks.append(RielaNoteMarkdownBlock(kind: .code, text: code.joined(separator: "\n")))
    }
    flushParagraph()
    return blocks.isEmpty ? [RielaNoteMarkdownBlock(kind: .paragraph, text: "")] : blocks
  }

  private static func headingBlock(from line: String) -> RielaNoteMarkdownBlock? {
    guard leadingSpaceCount(in: line) <= 3 else {
      return nil
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var count = 0
    for character in trimmed {
      guard character == "#" else {
        break
      }
      count += 1
    }
    guard (1...6).contains(count), trimmed.dropFirst(count).first?.isWhitespace == true else {
      return nil
    }
    return RielaNoteMarkdownBlock(
      kind: .heading(level: count),
      text: stripClosingATXHashes(String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces))
    )
  }

  private static func paragraphKind(for text: String) -> Kind {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix(">") {
      return .quote
    }
    if trimmed.range(of: #"^([-+*]|\d+[.)])\s+"#, options: .regularExpression) != nil {
      return .list
    }
    return .paragraph
  }

  private static func isRule(_ line: String) -> Bool {
    line.range(of: #"^([-*_])\s*(\1\s*){2,}$"#, options: .regularExpression) != nil
  }

  private static func displayText(_ text: String, for kind: Kind) -> String {
    switch kind {
    case .quote:
      return text.components(separatedBy: .newlines)
        .map {
          $0.replacingOccurrences(of: #"^\s{0,3}>\s?"#, with: "", options: .regularExpression)
        }
        .joined(separator: "\n")
    case .list:
      return text.components(separatedBy: .newlines)
        .map {
          $0.replacingOccurrences(of: #"^\s{0,3}([-+*]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        }
        .joined(separator: "\n")
    default:
      return text
    }
  }

  private static func stripClosingATXHashes(_ text: String) -> String {
    text.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
  }

  private static func leadingSpaceCount(in line: String) -> Int {
    var count = 0
    for character in line {
      guard character == " " else {
        break
      }
      count += 1
    }
    return count
  }
}

private struct MarkdownCodeFence {
  var marker: Character
  var count: Int

  init?(openingLine: String) {
    guard Self.leadingSpaceCount(in: openingLine) <= 3 else {
      return nil
    }
    let trimmed = openingLine.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first, first == "`" || first == "~" else {
      return nil
    }
    let markerCount = trimmed.prefix { $0 == first }.count
    guard markerCount >= 3 else {
      return nil
    }
    marker = first
    count = markerCount
  }

  func isClosed(by line: String) -> Bool {
    guard Self.leadingSpaceCount(in: line) <= 3 else {
      return false
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let markerCount = trimmed.prefix { $0 == marker }.count
    guard markerCount >= count else {
      return false
    }
    return trimmed.dropFirst(markerCount).trimmingCharacters(in: .whitespaces).isEmpty
  }

  private static func leadingSpaceCount(in line: String) -> Int {
    var count = 0
    for character in line {
      guard character == " " else {
        break
      }
      count += 1
    }
    return count
  }
}
