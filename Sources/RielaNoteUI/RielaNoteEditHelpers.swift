import Foundation
import SwiftUI
import UniformTypeIdentifiers

public let rielaNoteMarkdownContentType =
  UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText

public struct RielaNoteMarkdownFileDocument: FileDocument {
  public static var readableContentTypes: [UTType] {
    [rielaNoteMarkdownContentType]
  }

  public var markdown: String

  public init(markdown: String) {
    self.markdown = markdown
  }

  public init(configuration: ReadConfiguration) throws {
    let data = configuration.file.regularFileContents ?? Data()
    markdown = String(data: data, encoding: .utf8) ?? ""
  }

  public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(markdown.utf8))
  }
}

public func rielaNoteApplyingRewrite(
  draft: String,
  range: NSRange,
  replacement: String
) -> String? {
  guard range.location >= 0,
        range.length >= 0,
        let swiftRange = Range(range, in: draft) else {
    return nil
  }
  var updated = draft
  updated.replaceSubrange(swiftRange, with: replacement)
  return updated
}

public func rielaNoteRewriteRangeIsValid(_ range: NSRange, in draft: String) -> Bool {
  range.length > 0 && Range(range, in: draft) != nil
}

public func rielaNoteSelectedText(in draft: String, range: NSRange) -> String? {
  guard range.length > 0,
        let swiftRange = Range(range, in: draft) else {
    return nil
  }
  return String(draft[swiftRange])
}

public func rielaNoteRewriteResultIsFresh(
  currentDraft: String,
  submittedDraft: String,
  submittedRange: NSRange?,
  submittedSelectedText: String?
) -> Bool {
  guard currentDraft == submittedDraft else {
    return false
  }
  guard let submittedRange else {
    return true
  }
  return rielaNoteSelectedText(in: currentDraft, range: submittedRange) == submittedSelectedText
}

public func rielaNoteExportFilename(title: String?, noteId: String) -> String {
  let source = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    ? title ?? ""
    : noteId
  let scalars = source.lowercased().unicodeScalars.map { scalar -> Character in
    CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
  }
  let slug = String(scalars)
    .split(separator: "-")
    .prefix(8)
    .joined(separator: "-")
  return "\(slug.isEmpty ? noteId : slug).md"
}

public func rielaNoteDisplayedMarkdown(
  noteMarkdown: String,
  draftMarkdown: String,
  isEditing: Bool
) -> String {
  isEditing ? draftMarkdown : noteMarkdown
}
