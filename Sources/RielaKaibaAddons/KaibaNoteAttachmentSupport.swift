import Foundation
import RielaAddonSupport
import RielaCore

struct NoteAttachmentData {
  var data: Data
  var mediaType: String
  var filename: String?
}

enum SourceAttachmentInput {
  case inline(NoteAttachmentData)
  case localFile(url: URL, mediaType: String, filename: String?)
}

func noteAttachmentData(
  context: NoteAddonContext,
  input: WorkflowAddonExecutionInput
) throws -> NoteAttachmentData {
  let field = context.string("attachmentField", "attachment")
  let projected = field.flatMap { input.attachments[$0] }
    ?? (input.attachments.count == 1 ? input.attachments.values.first : nil)
  if let projected {
    let data: Data
    if let contentBase64 = projected.contentBase64,
       let decoded = Data(base64Encoded: contentBase64) {
      data = decoded
    } else if let contentText = projected.contentText {
      data = Data(contentText.utf8)
    } else {
      throw noteAddonInvalidInput("\(input.addon.name) attachment has no inline content")
    }
    try validateNoteAddonAttachmentSize(
      data.count,
      maxBytes: context.maxAttachmentBytes,
      label: "attachment"
    )
    return NoteAttachmentData(
      data: data,
      mediaType: projected.mediaType,
      filename: projected.filename
    )
  }
  if let filePath = context.string("filePath", "path", "localPath") {
    let url = try localFileReferenceURL(filePath, context: context)
    return NoteAttachmentData(
      data: try boundedLocalFileData(url: url, context: context),
      mediaType: context.string("mediaType", "contentType") ?? "application/octet-stream",
      filename: context.string("filename", "fileName") ?? url.lastPathComponent
    )
  }
  let text = try context.requiredString(
    "contentText",
    "text",
    "body",
    fieldName: "attachment content"
  )
  try validateNoteAddonAttachmentSize(
    Data(text.utf8).count,
    maxBytes: context.maxAttachmentBytes,
    label: "attachment content"
  )
  return NoteAttachmentData(
    data: Data(text.utf8),
    mediaType: context.string("mediaType", "contentType") ?? "text/plain",
    filename: context.string("filename", "fileName")
  )
}

func sourceAttachmentInput(ref: String, context: NoteAddonContext) throws -> SourceAttachmentInput? {
  if let attachment = context.input.attachments[ref] {
    return .inline(try noteAttachmentData(
      attachment,
      addonName: context.input.addon.name,
      maxBytes: context.maxAttachmentBytes
    ))
  }
  guard isLocalFileReference(ref) else {
    return nil
  }
  let url = try localFileReferenceURL(ref, context: context)
  guard FileManager.default.fileExists(atPath: url.path) else {
    return nil
  }
  _ = try localFileSize(url: url, context: context)
  return .localFile(
    url: url,
    mediaType: mediaType(for: url),
    filename: url.lastPathComponent
  )
}

func boundedLocalFileData(url: URL, context: NoteAddonContext) throws -> Data {
  _ = try localFileSize(url: url, context: context)
  let data = try Data(contentsOf: url)
  try validateNoteAddonAttachmentSize(
    data.count,
    maxBytes: context.maxAttachmentBytes,
    label: url.path
  )
  return data
}

private func noteAttachmentData(
  _ attachment: WorkflowAddonAttachmentValue,
  addonName: String,
  maxBytes: Int
) throws -> NoteAttachmentData {
  if let contentBase64 = attachment.contentBase64,
     let decoded = Data(base64Encoded: contentBase64) {
    try validateNoteAddonAttachmentSize(decoded.count, maxBytes: maxBytes, label: "attachment")
    return NoteAttachmentData(
      data: decoded,
      mediaType: attachment.mediaType,
      filename: attachment.filename
    )
  }
  if let contentText = attachment.contentText {
    let data = Data(contentText.utf8)
    try validateNoteAddonAttachmentSize(data.count, maxBytes: maxBytes, label: "attachment")
    return NoteAttachmentData(
      data: data,
      mediaType: attachment.mediaType,
      filename: attachment.filename
    )
  }
  throw noteAddonInvalidInput("\(addonName) attachment has no inline content")
}

private func isLocalFileReference(_ ref: String) -> Bool {
  if ref.hasPrefix("s3://") || ref.hasPrefix("http://") || ref.hasPrefix("https://") {
    return false
  }
  return ref.hasPrefix("file://")
    || ref.hasPrefix("/")
    || ref.hasPrefix("./")
    || ref.hasPrefix("../")
}

private func fileReferenceURL(_ ref: String, relativeTo root: URL) -> URL {
  if ref.hasPrefix("file://"), let url = URL(string: ref), url.isFileURL {
    return url.standardizedFileURL
  }
  if ref.hasPrefix("/") {
    return URL(fileURLWithPath: ref).standardizedFileURL
  }
  return URL(fileURLWithPath: ref, relativeTo: root).standardizedFileURL
}

func localFileReferenceURL(_ ref: String, context: NoteAddonContext) throws -> URL {
  let resolvedRoot = context.localFileRoot.resolvingSymlinksInPath().standardizedFileURL
  let resolvedURL = fileReferenceURL(ref, relativeTo: context.localFileRoot)
    .resolvingSymlinksInPath()
    .standardizedFileURL
  guard context.allowsLocalFileReferencesOutsideRoot
    || isDescendant(resolvedURL, of: resolvedRoot) else {
    throw noteAddonInvalidInput(
      "\(context.input.addon.name) local file reference is outside allowed root: \(ref)"
    )
  }
  return resolvedURL
}

private func isDescendant(_ url: URL, of root: URL) -> Bool {
  let path = url.standardizedFileURL.path
  let rootPath = root.standardizedFileURL.path
  return path == rootPath
    || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
}

func localFileSize(url: URL, context: NoteAddonContext) throws -> Int {
  let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
  guard values.isRegularFile == true else {
    throw noteAddonInvalidInput(
      "\(context.input.addon.name) local file reference is not a regular file: \(url.path)"
    )
  }
  let size = values.fileSize ?? 0
  try validateNoteAddonAttachmentSize(
    size,
    maxBytes: context.maxAttachmentBytes,
    label: url.path
  )
  return size
}

private func validateNoteAddonAttachmentSize(_ size: Int, maxBytes: Int, label: String) throws {
  guard size <= maxBytes else {
    throw noteAddonInvalidInput("note attachment \(label) is \(size) bytes; max \(maxBytes)")
  }
}

private func mediaType(for url: URL) -> String {
  switch url.pathExtension.lowercased() {
  case "pdf":
    return "application/pdf"
  case "png":
    return "image/png"
  case "jpg", "jpeg":
    return "image/jpeg"
  case "webp":
    return "image/webp"
  case "txt", "md":
    return "text/plain"
  default:
    return "application/octet-stream"
  }
}
