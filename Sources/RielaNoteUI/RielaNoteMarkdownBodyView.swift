import SwiftUI

public struct RielaNoteMarkdownBodyView: View {
  private let blocks: [RielaNoteMarkdownBlock]

  public init(markdown: String) {
    blocks = RielaNoteMarkdownBlock.parse(markdown)
  }

  public var body: some View {
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
    var isInCode = false

    func flushParagraph() {
      guard !paragraph.isEmpty else {
        return
      }
      let text = paragraph.joined(separator: "\n")
      blocks.append(RielaNoteMarkdownBlock(kind: paragraphKind(for: text), text: text))
      paragraph.removeAll()
    }

    for rawLine in markdown.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") {
        if isInCode {
          blocks.append(RielaNoteMarkdownBlock(kind: .code, text: code.joined(separator: "\n")))
          code.removeAll()
          isInCode = false
        } else {
          flushParagraph()
          isInCode = true
        }
        continue
      }
      if isInCode {
        code.append(rawLine)
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
    if isInCode {
      blocks.append(RielaNoteMarkdownBlock(kind: .code, text: code.joined(separator: "\n")))
    }
    flushParagraph()
    return blocks.isEmpty ? [RielaNoteMarkdownBlock(kind: .paragraph, text: "")] : blocks
  }

  private static func headingBlock(from line: String) -> RielaNoteMarkdownBlock? {
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
      text: String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
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
}
