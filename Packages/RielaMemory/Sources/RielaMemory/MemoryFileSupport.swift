import Foundation

func uniqueDestinationURL(
  in directory: URL,
  sourceURL: URL,
  index: Int,
  preferredName: String?
) -> URL {
  let baseName = sanitizedFileName(nonEmpty(preferredName) ?? sourceURL.lastPathComponent, fallback: "file-\(index + 1)")
  let baseURL = directory.appendingPathComponent(baseName)
  guard FileManager.default.fileExists(atPath: baseURL.path) else {
    return baseURL
  }
  let extensionPart = baseURL.pathExtension
  let stem = extensionPart.isEmpty ? baseURL.lastPathComponent : String(baseURL.lastPathComponent.dropLast(extensionPart.count + 1))
  for suffix in 2...1000 {
    let candidateName = extensionPart.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(extensionPart)"
    let candidate = directory.appendingPathComponent(candidateName)
    if !FileManager.default.fileExists(atPath: candidate.path) {
      return candidate
    }
  }
  return directory.appendingPathComponent("\(UUID().uuidString)-\(baseName)")
}

func sanitizedFileName(_ value: String, fallback: String) -> String {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  let candidate = trimmed.isEmpty ? fallback : trimmed
  let invalidCharacters = CharacterSet(charactersIn: "/:\\\0")
  let parts = candidate.unicodeScalars.map { scalar -> String in
    invalidCharacters.contains(scalar) ? "-" : String(scalar)
  }
  let sanitized = parts.joined().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
  return sanitized.isEmpty ? fallback : String(sanitized.prefix(180))
}

func normalizedSourceFilePath(_ path: String) -> String {
  let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    return ""
  }
  return URL(fileURLWithPath: trimmed).standardizedFileURL.path
}

func inferredMediaType(path: String) -> String? {
  switch URL(fileURLWithPath: path).pathExtension.lowercased() {
  case "jpg", "jpeg":
    return "image/jpeg"
  case "png":
    return "image/png"
  case "gif":
    return "image/gif"
  case "webp":
    return "image/webp"
  case "mp4":
    return "video/mp4"
  case "mov":
    return "video/quicktime"
  case "mp3":
    return "audio/mpeg"
  case "m4a":
    return "audio/mp4"
  case "wav":
    return "audio/wav"
  case "pdf":
    return "application/pdf"
  case "txt":
    return "text/plain"
  case "json":
    return "application/json"
  default:
    return nil
  }
}

func normalizedMediaType(_ value: String?) -> String? {
  nonEmpty(value)?.lowercased()
}

func normalizedFileKind(provided: String?, mediaType: String?, path: String) -> String? {
  if let inferred = inferredFileKind(mediaType: mediaType, path: path), inferred != "file" {
    return inferred
  }
  let providedKind = nonEmpty(provided)?.lowercased()
  switch providedKind {
  case "photo", "picture", "screenshot":
    return "image"
  case "movie":
    return "video"
  case "voice", "sound":
    return "audio"
  case "document" where URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf":
    return "pdf"
  case let kind?:
    return kind
  case nil:
    return inferredFileKind(mediaType: mediaType, path: path)
  }
}

func inferredFileKind(mediaType: String?, path: String) -> String? {
  let resolvedMediaType = normalizedMediaType(mediaType) ?? inferredMediaType(path: path)
  guard let resolvedMediaType else {
    return nil
  }
  if resolvedMediaType.hasPrefix("image/") {
    return "image"
  }
  if resolvedMediaType.hasPrefix("video/") {
    return "video"
  }
  if resolvedMediaType.hasPrefix("audio/") {
    return "audio"
  }
  if resolvedMediaType == "application/pdf" {
    return "pdf"
  }
  if resolvedMediaType.hasPrefix("text/") {
    return "text"
  }
  return "file"
}

func fileSize(path: String) -> Int64? {
  guard let value = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else {
    return nil
  }
  return value.int64Value
}

func removeCopiedFiles(_ paths: [String]) {
  for path in paths {
    try? FileManager.default.removeItem(atPath: path)
  }
}

func removeStoredFiles(_ paths: [String]) {
  for path in paths {
    try? FileManager.default.removeItem(atPath: path)
    removeDirectoryIfEmpty(URL(fileURLWithPath: path).deletingLastPathComponent())
  }
}

func removeDirectoryIfEmpty(_ url: URL) {
  guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path), contents.isEmpty else {
    return
  }
  try? FileManager.default.removeItem(at: url)
}
