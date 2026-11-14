import Foundation
import RielaCore

func sessionListOptions(from variables: JSONObject, claudeCodeHome: String?) -> ClaudeCodeSessionListOptions {
  ClaudeCodeSessionListOptions(
    claudeCodeHome: claudeCodeHome,
    source: claudeCodeStringValue(variables["source"]).flatMap(ClaudeCodeSessionSource.init(rawValue:)),
    cwd: claudeCodeStringValue(variables["cwd"]) ?? claudeCodeStringValue(variables["projectPath"]),
    branch: claudeCodeStringValue(variables["branch"]),
    limit: claudeCodeIntValue(variables["limit"]) ?? 50,
    offset: claudeCodeIntValue(variables["offset"]) ?? 0,
    sortBy: claudeCodeStringValue(variables["sortBy"]) ?? "createdAt",
    sortOrder: claudeCodeStringValue(variables["sortOrder"]) ?? "desc"
  )
}

func transcriptSearchOptions(from variables: JSONObject) -> ClaudeCodeSessionTranscriptSearchOptions {
  ClaudeCodeSessionTranscriptSearchOptions(
    caseSensitive: claudeCodeBoolValue(variables["caseSensitive"]) ?? false,
    role: claudeCodeStringValue(variables["role"]) ?? "both",
    maxBytes: claudeCodeIntValue(variables["maxBytes"]).map { max(0, $0) },
    maxEvents: claudeCodeIntValue(variables["maxEvents"]).map { max(0, $0) },
    maxSessions: claudeCodeIntValue(variables["maxSessions"]).map { max(0, $0) },
    timeoutMs: claudeCodeIntValue(variables["timeoutMs"]).map { max(0, $0) },
    limit: max(0, claudeCodeIntValue(variables["limit"]) ?? 50),
    offset: max(0, claudeCodeIntValue(variables["offset"]) ?? 0)
  )
}

func rebuildFileIndex(claudeCodeHome: String?) throws -> ClaudeCodeFileChangeIndex {
  let lines = discoverRolloutPaths(claudeCodeHome: claudeCodeHome).flatMap { path in
    (try? ClaudeCodeRolloutReader.readRollout(path: path)) ?? []
  }
  return ClaudeCodeFileChangeIndex.rebuild(from: lines)
}

struct PersistentChangedFile: Codable {
  var path: String
  var operation: String
  var changeCount: Int
  var lastModified: String
}

struct PersistentSessionFileIndexEntry: Codable {
  var sessionId: String
  var files: [PersistentChangedFile]
  var indexedAt: String
}

struct PersistentFileChangeIndex: Codable {
  var sessions: [PersistentSessionFileIndexEntry]
  var updatedAt: String
}

func persistentFileIndexURL(configDir: String) -> URL {
  URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("file-changes-index.json")
}

func rebuildPersistentFileIndex(configDir: String, claudeCodeHome: String?) throws -> JSONObject {
  let indexedAt = ISO8601DateFormatter().string(from: Date())
  let entries = discoverRolloutPaths(claudeCodeHome: claudeCodeHome).compactMap { path -> PersistentSessionFileIndexEntry? in
    guard let lines = try? ClaudeCodeRolloutReader.readRollout(path: path) else {
      return nil
    }
    let sessionId = rolloutSessionId(lines: lines, path: path)
    let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let parsedFiles = changedFilesSummary(from: lines)
    let files = parsedFiles.isEmpty ? changedFilesSummary(changes: parseRawPatchFileChanges(raw), timestamp: indexedAt) : parsedFiles
    return PersistentSessionFileIndexEntry(sessionId: sessionId, files: files, indexedAt: indexedAt)
  }
  let index = PersistentFileChangeIndex(sessions: entries, updatedAt: indexedAt)
  let url = persistentFileIndexURL(configDir: configDir)
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let data = try JSONEncoder().encode(index)
  try data.write(to: url, options: .atomic)
  return [
    "indexedSessions": .number(Double(entries.count)),
    "indexedFiles": .number(Double(entries.reduce(0) { $0 + $1.files.count })),
    "updatedAt": .string(indexedAt)
  ]
}

func findPersistentSessionsByFile(path: String, configDir: String, claudeCodeHome: String?) throws -> JSONObject {
  let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !target.isEmpty else {
    throw ClaudeCodeGraphQLError.missingVariable("path")
  }
  let url = persistentFileIndexURL(configDir: configDir)
  if !FileManager.default.isReadableFile(atPath: url.path) {
    _ = try rebuildPersistentFileIndex(configDir: configDir, claudeCodeHome: claudeCodeHome)
  }
  let index = try JSONDecoder().decode(PersistentFileChangeIndex.self, from: Data(contentsOf: url))
  let sessions = index.sessions.flatMap { entry in
    entry.files.filter { $0.path == target }.map { file in
      [
        "sessionId": .string(entry.sessionId),
        "operation": .string(file.operation),
        "lastModified": .string(file.lastModified)
      ] as JSONObject
    }
  }.sorted { lhs, rhs in
    (claudeCodeStringValue(lhs["lastModified"]) ?? "") > (claudeCodeStringValue(rhs["lastModified"]) ?? "")
  }
  return [
    "path": .string(target),
    "sessions": .array(sessions.map(JSONValue.object))
  ]
}

func rolloutSessionId(lines: [ClaudeCodeRolloutLine], path: String) -> String {
  for line in lines {
    if let payload = fileChangeObject(line.payload), let meta = fileChangeObject(payload["meta"]), let id = fileChangeString(meta["id"]) {
      return id
    }
  }
  let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  return name.hasPrefix("rollout-") ? String(name.dropFirst("rollout-".count)) : name
}

func changedFilesSummary(from lines: [ClaudeCodeRolloutLine]) -> [PersistentChangedFile] {
  var files: [String: PersistentChangedFile] = [:]
  for line in lines {
    for change in ClaudeCodeFileChanges.extract(from: line) {
      let paths = [change.previousPath, change.path].compactMap { $0 }.filter { !$0.isEmpty }
      for path in paths {
        var file = files[path] ?? PersistentChangedFile(path: path, operation: change.operation.rawValue, changeCount: 0, lastModified: line.timestamp)
        file.operation = change.operation.rawValue
        file.changeCount += 1
        file.lastModified = max(file.lastModified, line.timestamp)
        files[path] = file
      }
    }
  }
  return files.values.sorted { $0.path < $1.path }
}

func changedFilesSummary(changes: [ClaudeCodeFileChange], timestamp: String) -> [PersistentChangedFile] {
  var files: [String: PersistentChangedFile] = [:]
  for change in changes {
    let paths = [change.previousPath, change.path].compactMap { $0 }.filter { !$0.isEmpty }
    for path in paths {
      var file = files[path] ?? PersistentChangedFile(path: path, operation: change.operation.rawValue, changeCount: 0, lastModified: timestamp)
      file.operation = change.operation.rawValue
      file.changeCount += 1
      file.lastModified = timestamp
      files[path] = file
    }
  }
  return files.values.sorted { $0.path < $1.path }
}

func fileChangeIndex(for session: ClaudeCodeSession) throws -> ClaudeCodeFileChangeIndex {
  let index = try ClaudeCodeFileChangeIndex.rebuild(from: ClaudeCodeRolloutReader.readRollout(path: session.rolloutPath))
  if !index.listChangedFiles().isEmpty {
    return index
  }
  let raw = (try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""
  return ClaudeCodeFileChangeIndex(changes: parseRawPatchFileChanges(raw))
}

struct FileChangeDetailDTO {
  var path: String
  var timestamp: String
  var operation: String
  var source: String
  var previousPath: String?
  var command: String?
  var patch: String?
}

func fileChangeSummaryJSON(for session: ClaudeCodeSession) throws -> JSONObject {
  let lines = try ClaudeCodeRolloutReader.readRollout(path: session.rolloutPath)
  let timestamp = isoString(session.updatedAt)
  let parsedFiles = changedFilesSummary(from: lines)
  let files = parsedFiles.isEmpty ? changedFilesSummary(changes: parseRawPatchFileChanges((try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""), timestamp: timestamp) : parsedFiles
  return [
    "sessionId": .string(session.id),
    "files": .array(files.map(persistentChangedFileJSON)),
    "totalFiles": .number(Double(files.count))
  ]
}

func filePatchHistoryJSON(for session: ClaudeCodeSession) throws -> JSONObject {
  let lines = try ClaudeCodeRolloutReader.readRollout(path: session.rolloutPath)
  let timestamp = isoString(session.updatedAt)
  var details = fileChangeDetails(from: lines)
  if details.isEmpty {
    details = parseRawPatchFileChanges((try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? "").map {
      FileChangeDetailDTO(path: $0.path, timestamp: timestamp, operation: $0.operation.rawValue, source: $0.source.rawValue, previousPath: $0.previousPath, command: $0.command, patch: $0.patch)
    }
  }
  var grouped: [String: [FileChangeDetailDTO]] = [:]
  for detail in details {
    grouped[detail.path, default: []].append(detail)
    if let previousPath = detail.previousPath, previousPath != detail.path {
      grouped[previousPath, default: []].append(FileChangeDetailDTO(
        path: previousPath,
        timestamp: detail.timestamp,
        operation: "deleted",
        source: detail.source,
        previousPath: detail.previousPath,
        command: detail.command,
        patch: detail.patch
      ))
    }
  }
  let files = grouped.keys.sorted().map { path -> JSONObject in
    let entries = (grouped[path] ?? []).sorted { lhs, rhs in lhs.timestamp < rhs.timestamp }
    let last = entries.last
    return [
      "path": .string(path),
      "operation": .string(last?.operation ?? "modified"),
      "changeCount": .number(Double(entries.count)),
      "lastModified": .string(last?.timestamp ?? timestamp),
      "changes": .array(entries.map { .object(fileChangeDetailJSON($0)) })
    ]
  }
  let totalChanges = files.reduce(0) { partial, file in
    partial + (claudeCodeIntValue(file["changeCount"]) ?? 0)
  }
  return [
    "sessionId": .string(session.id),
    "files": .array(files.map(JSONValue.object)),
    "totalFiles": .number(Double(files.count)),
    "totalChanges": .number(Double(totalChanges))
  ]
}

func persistentChangedFileJSON(_ file: PersistentChangedFile) -> JSONValue {
  .object([
    "path": .string(file.path),
    "operation": .string(file.operation),
    "changeCount": .number(Double(file.changeCount)),
    "lastModified": .string(file.lastModified)
  ])
}

func fileChangeDetails(from lines: [ClaudeCodeRolloutLine]) -> [FileChangeDetailDTO] {
  lines.flatMap { line in
    ClaudeCodeFileChanges.extract(from: line).map { change in
      FileChangeDetailDTO(
        path: change.path,
        timestamp: line.timestamp,
        operation: change.operation.rawValue,
        source: change.source.rawValue,
        previousPath: change.previousPath,
        command: change.command,
        patch: change.patch
      )
    }
  }
}

func fileChangeDetailJSON(_ detail: FileChangeDetailDTO) -> JSONObject {
  var object: JSONObject = [
    "path": .string(detail.path),
    "timestamp": .string(detail.timestamp),
    "operation": .string(detail.operation),
    "source": .string(detail.source),
    "previousPath": detail.previousPath.map(JSONValue.string) ?? .null
  ]
  if let command = detail.command {
    object["command"] = .string(command)
  }
  if let patch = detail.patch {
    object["patch"] = .string(patch)
  }
  return object
}

func parseRawPatchFileChanges(_ text: String) -> [ClaudeCodeFileChange] {
  text.split(separator: "\n").compactMap { rawLine in
    let line = String(rawLine)
    if let range = line.range(of: "*** Add File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return ClaudeCodeFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .created, source: .applyPatch, patch: text)
    }
    if let range = line.range(of: "*** Delete File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return ClaudeCodeFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .deleted, source: .applyPatch, patch: text)
    }
    if let range = line.range(of: "*** Update File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return ClaudeCodeFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .modified, source: .applyPatch, patch: text)
    }
    return nil
  }
}
