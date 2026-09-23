import Foundation
import KaibaClient
import RielaCore

struct KaibaDocumentImportInput {
  let title: String
  let pages: [KaibaIngestPage]
  let source: KaibaInlineAttachment
}

private let maximumDocumentImportBytes = 8 * 1024 * 1024

func documentImportInput(_ values: KaibaAddonInputs) throws -> KaibaDocumentImportInput {
  let path = try values.requiredString(["path", "filePath"], fieldName: "path")
  let sourceURL = try permittedDocumentURL(path, values: values)
  let resourceValues: URLResourceValues
  do {
    resourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
  } catch {
    throw noteAddonInvalidInput("\(values.addonName) source file does not exist")
  }
  guard resourceValues.isRegularFile == true else {
    throw noteAddonInvalidInput("\(values.addonName) source path must be a regular file")
  }
  guard let size = resourceValues.fileSize, size > 0 else {
    throw noteAddonInvalidInput("\(values.addonName) source file is empty")
  }
  guard size <= maximumDocumentImportBytes else {
    throw noteAddonInvalidInput("\(values.addonName) source file exceeds 8 MiB limit")
  }
  let bytes: Data
  do {
    bytes = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
  } catch {
    throw noteAddonInvalidInput("\(values.addonName) could not read source file")
  }
  let filename = sourceURL.lastPathComponent
  let pages = try importedPages(values: values, bytes: bytes, filename: filename)
  return .init(
    title: values.string(["title", "notebookTitle"]) ?? filename,
    pages: pages,
    source: .init(
      bytes: bytes,
      mediaType: documentMediaType(filename: filename),
      originalFilename: filename,
      role: .sourceDocument
    )
  )
}

private func permittedDocumentURL(_ path: String, values: KaibaAddonInputs) throws -> URL {
  let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
  guard let configuredRoot = values.string(["localFileRoot"]) else { return candidate }
  let root = URL(fileURLWithPath: configuredRoot).standardizedFileURL.resolvingSymlinksInPath()
  let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
  guard candidate.path == root.path || candidate.path.hasPrefix(prefix) else {
    throw noteAddonInvalidInput("\(values.addonName) source file is outside allowed root")
  }
  return candidate
}

private func importedPages(
  values: KaibaAddonInputs,
  bytes: Data,
  filename: String
) throws -> [KaibaIngestPage] {
  if values.value("pages") != nil { return try ingestPages(values.value("pages")) }
  guard let text = String(data: bytes, encoding: .utf8) else {
    throw noteAddonInvalidInput(
      "\(values.addonName) needs config.pages for a non-text document; OCR conversion must run before this HTTP-only add-on"
    )
  }
  let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !body.isEmpty else { throw noteAddonInvalidInput("\(values.addonName) source file has no importable text") }
  return [.init(bodyMarkdown: body, readOnly: true, tags: [], metaJSON: nil, noteNumber: 1)]
}

private func documentMediaType(filename: String) -> String {
  switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
  case "csv": "text/csv"
  case "md", "markdown": "text/markdown"
  case "txt": "text/plain"
  case "json": "application/json"
  case "pdf": "application/pdf"
  default: "application/octet-stream"
  }
}
