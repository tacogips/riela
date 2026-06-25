import Foundation
import RielaCore

public enum CursorCLIFileChangeSource: String, Equatable, Codable, Sendable {
  case applyPatch = "apply_patch"
  case shell
  case execCommand = "exec_command"
  case localShell = "local_shell"
}

public enum CursorCLIFileOperation: String, Equatable, Codable, Sendable {
  case created
  case modified
  case deleted
  case moved
}

public struct CursorCLIFileChange: Equatable, Codable, Sendable {
  public var path: String
  public var operation: CursorCLIFileOperation
  public var source: CursorCLIFileChangeSource
  public var previousPath: String?
  public var command: String?
  public var patch: String?

  public init(path: String, operation: CursorCLIFileOperation, source: CursorCLIFileChangeSource, previousPath: String? = nil, command: String? = nil, patch: String? = nil) {
    self.path = path
    self.operation = operation
    self.source = source
    self.previousPath = previousPath
    self.command = command
    self.patch = patch
  }
}

public enum CursorCLIFileChanges {
  public static func extract(from lines: [CursorCLIRolloutLine]) -> [CursorCLIFileChange] {
    var pending: [String: [CursorCLIFileChange]] = [:]
    var changes: [CursorCLIFileChange] = []
    for line in lines {
      guard let payload = cursorOperationFileChangeObject(line.payload) else {
        continue
      }
      if let callId = cursorOperationFileChangeString(payload["call_id"]) ?? cursorOperationFileChangeString(payload["callId"]) ?? cursorOperationFileChangeString(payload["id"]) {
        if isToolResultPayload(payload) {
          if isSuccessfulToolResult(payload), let pendingChanges = pending.removeValue(forKey: callId) {
            changes.append(contentsOf: pendingChanges)
          } else {
            pending.removeValue(forKey: callId)
          }
          changes.append(contentsOf: extractDirectChanges(from: payload))
          continue
        }
        if isToolInvocationPayload(payload) {
          let invocationChanges = extractDirectChanges(from: payload)
          if !invocationChanges.isEmpty {
            pending[callId] = invocationChanges
            continue
          }
        }
      }
      changes.append(contentsOf: extract(from: line))
    }
    return changes
  }

  public static func extract(from line: CursorCLIRolloutLine) -> [CursorCLIFileChange] {
    guard let payload = cursorOperationFileChangeObject(line.payload) else {
      return []
    }
    if let exitCode = cursorOperationNumberValue(payload["exit_code"]), exitCode != 0 {
      return []
    }
    if let changes = fileChangeArray(payload["file_changes"]) {
      return changes
    }
    if let commandChanges = commandLikeFileChanges(payload: payload), !commandChanges.isEmpty {
      return commandChanges
    }
    if let patch = cursorOperationFileChangeString(payload["patch"]) ?? cursorOperationFileChangeString(payload["aggregated_output"]) {
      return parsePatchFileChanges(patch)
    }
    return []
  }
}

func isToolInvocationPayload(_ payload: JSONObject) -> Bool {
  guard let type = cursorOperationFileChangeString(payload["type"]) else {
    return false
  }
  return ["function_call", "local_shell_call", "custom_tool_call", "ExecCommandBegin"].contains(type)
}

func isToolResultPayload(_ payload: JSONObject) -> Bool {
  guard let type = cursorOperationFileChangeString(payload["type"]) else {
    return false
  }
  return ["function_call_output", "custom_tool_call_output", "local_shell_call_output", "ExecCommandEnd"].contains(type)
}

func isSuccessfulToolResult(_ payload: JSONObject) -> Bool {
  if cursorOperationBoolValue(payload["is_error"]) == true || cursorOperationBoolValue(payload["isError"]) == true {
    return false
  }
  if let exitCode = cursorOperationNumberValue(payload["exit_code"]) ?? cursorOperationNumberValue(payload["exitCode"]) {
    return exitCode == 0
  }
  if let status = cursorOperationFileChangeString(payload["status"])?.lowercased() {
    return isSuccessfulToolStatus(status)
  }
  if let output = cursorOperationFileChangeObject(payload["output"]) ?? cursorOperationFileChangeString(payload["output"]).flatMap(parseFileChangeArguments) {
    if cursorOperationBoolValue(output["is_error"]) == true || cursorOperationBoolValue(output["isError"]) == true {
      return false
    }
    if let metadata = cursorOperationFileChangeObject(output["metadata"]) {
      if cursorOperationBoolValue(metadata["is_error"]) == true || cursorOperationBoolValue(metadata["isError"]) == true {
        return false
      }
      if let exitCode = cursorOperationNumberValue(metadata["exit_code"]) ?? cursorOperationNumberValue(metadata["exitCode"]), exitCode != 0 {
        return false
      }
      if let status = cursorOperationFileChangeString(metadata["status"])?.lowercased() {
        return isSuccessfulToolStatus(status)
      }
    }
    if let exitCode = cursorOperationNumberValue(output["exit_code"]) ?? cursorOperationNumberValue(output["exitCode"]), exitCode != 0 {
      return false
    }
    if let status = cursorOperationFileChangeString(output["status"])?.lowercased() {
      return isSuccessfulToolStatus(status)
    }
  }
  return true
}

func isSuccessfulToolStatus(_ status: String) -> Bool {
  ["completed", "success", "succeeded", "ok"].contains(status)
}

func extractDirectChanges(from payload: JSONObject) -> [CursorCLIFileChange] {
  if let changes = fileChangeArray(payload["file_changes"]) {
    return changes
  }
  if let commandChanges = commandLikeFileChanges(payload: payload), !commandChanges.isEmpty {
    return commandChanges
  }
  if let patch = cursorOperationFileChangeString(payload["patch"]) ?? cursorOperationFileChangeString(payload["aggregated_output"]) ?? cursorOperationFileChangeString(payload["output"]) {
    return parsePatchFileChanges(patch)
  }
  return []
}

func commandLikeFileChanges(payload: JSONObject) -> [CursorCLIFileChange]? {
  let type = cursorOperationFileChangeString(payload["type"])
  guard ["function_call", "local_shell_call", "custom_tool_call", "ExecCommandBegin"].contains(type) else {
    return nil
  }
  if let patch = cursorOperationFileChangeString(payload["patch"]) ?? cursorOperationFileChangeString(payload["input"]) {
    let changes = parsePatchFileChanges(patch)
    if !changes.isEmpty {
      return changes
    }
  }
  let argumentObject = cursorOperationFileChangeObject(payload["arguments"]) ?? cursorOperationFileChangeString(payload["arguments"]).flatMap(parseFileChangeArguments)
  let command = cursorOperationFileChangeString(argumentObject?["command"])
    ?? cursorOperationFileChangeString(argumentObject?["cmd"])
    ?? cursorOperationFileChangeString(argumentObject?["script"])
    ?? cursorOperationStringArrayValue(argumentObject?["command"]).map { $0.joined(separator: " ") }
    ?? cursorOperationStringArrayValue(payload["command"]).map { $0.joined(separator: " ") }
  guard let command else {
    return nil
  }
  return parseShellFileChanges(command)
}

func parsePatchFileChanges(_ patch: String) -> [CursorCLIFileChange] {
  var pendingUpdatePath: String?
  var pendingUpdateIndex: Int?
  var changes: [CursorCLIFileChange] = []
  for rawLine in patch.split(separator: "\n") {
    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
    if line.hasPrefix("*** Add File: ") {
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      changes.append(CursorCLIFileChange(path: String(line.dropFirst("*** Add File: ".count)), operation: .created, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Delete File: ") {
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      changes.append(CursorCLIFileChange(path: String(line.dropFirst("*** Delete File: ".count)), operation: .deleted, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Update File: ") {
      pendingUpdatePath = String(line.dropFirst("*** Update File: ".count))
      pendingUpdateIndex = changes.count
      changes.append(CursorCLIFileChange(path: pendingUpdatePath ?? "", operation: .modified, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Move to: "), let from = pendingUpdatePath {
      let to = String(line.dropFirst("*** Move to: ".count))
      if let pendingUpdateIndex {
        changes[pendingUpdateIndex] = CursorCLIFileChange(path: to, operation: .modified, source: .applyPatch, previousPath: from, patch: patch)
      } else {
        changes.append(CursorCLIFileChange(path: to, operation: .modified, source: .applyPatch, previousPath: from, patch: patch))
      }
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      continue
    }
  }
  return changes
}

func parseFileChangeArguments(_ text: String) -> JSONObject? {
  guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data), case let .object(object) = value else {
    return nil
  }
  return object
}

func parseShellFileChanges(_ command: String) -> [CursorCLIFileChange] {
  if command.contains("*** Begin Patch") || command.contains("*** Add File:") || command.contains("*** Update File:") || command.contains("*** Delete File:") {
    let changes = parsePatchFileChanges(command)
    if !changes.isEmpty {
      return changes.map { change in
        var annotated = change
        annotated.command = command
        return annotated
      }
    }
  }
  if let inner = unwrapBashLoginCommand(command) {
    return parseShellFileChanges(inner).map { change in
      var annotated = change
      annotated.command = annotated.command ?? command
      return annotated
    }
  }
  var changes: [CursorCLIFileChange] = []
  let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
  guard !tokens.isEmpty else {
    return []
  }
  if tokens.prefix(2) == ["git", "mv"], tokens.count >= 4 {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[3]), operation: .moved, source: .shell, previousPath: cleanShellPath(tokens[2])))
  } else if tokens.prefix(2) == ["git", "rm"], tokens.count >= 3 {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[2]), operation: .deleted, source: .shell))
  } else if tokens[0] == "mv", tokens.count >= 3 {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[2]), operation: .moved, source: .shell, previousPath: cleanShellPath(tokens[1])))
  } else if tokens[0] == "cp", tokens.count >= 3 {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[2]), operation: .created, source: .shell))
  } else if tokens[0] == "rm", tokens.count >= 2 {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[1]), operation: .deleted, source: .shell))
  } else if tokens[0] == "touch", tokens.count >= 2 {
    for path in tokens.dropFirst() {
      changes.append(CursorCLIFileChange(path: cleanShellPath(path), operation: .created, source: .shell))
    }
  } else if ["sed", "perl"].contains(tokens[0]), tokens.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }), let path = tokens.last {
    changes.append(CursorCLIFileChange(path: cleanShellPath(path), operation: .modified, source: .shell))
  } else if tokens[0] == "tee", tokens.count >= 2 {
    let paths = tokens.dropFirst().filter { !$0.hasPrefix("-") && $0 != ">" && $0 != ">>" }
    for path in paths {
      changes.append(CursorCLIFileChange(path: cleanShellPath(path), operation: tokens.contains("-a") ? .modified : .created, source: .shell))
    }
  }
  for (index, token) in tokens.enumerated() where [">", ">>"].contains(token) && index + 1 < tokens.count {
    changes.append(CursorCLIFileChange(path: cleanShellPath(tokens[index + 1]), operation: token == ">" ? .created : .modified, source: .shell))
  }
  return changes.map { change in
    var annotated = change
    annotated.command = command
    return annotated
  }
}

func unwrapBashLoginCommand(_ command: String) -> String? {
  let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
  for prefix in ["bash -lc ", "sh -lc ", "zsh -lc "] where trimmed.hasPrefix(prefix) {
    return stripShellQuotes(String(trimmed.dropFirst(prefix.count)))
  }
  return nil
}

func cleanShellPath(_ path: String) -> String {
  stripShellQuotes(path).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`; "))
}

func stripShellQuotes(_ text: String) -> String {
  var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  let isSingleQuoted = value.hasPrefix("'") && value.hasSuffix("'")
  let isDoubleQuoted = value.hasPrefix("\"") && value.hasSuffix("\"")
  if isSingleQuoted || isDoubleQuoted {
    value = String(value.dropFirst().dropLast())
  }
  return value
}

public struct CursorCLIFileChangeIndex: Equatable, Sendable {
  private var changes: [CursorCLIFileChange] = []

  public init(changes: [CursorCLIFileChange] = []) {
    self.changes = changes
  }

  public static func rebuild(from lines: [CursorCLIRolloutLine]) -> CursorCLIFileChangeIndex {
    CursorCLIFileChangeIndex(changes: CursorCLIFileChanges.extract(from: lines))
  }

  public func listChangedFiles() -> [String] {
    Array(Set(changes.flatMap { change in
      [change.path, change.previousPath].compactMap { $0 }
    })).sorted()
  }

  public func patches(for path: String) -> [CursorCLIFileChange] {
    changes.filter { $0.path == path || $0.previousPath == path }
  }

  public func find(_ path: String) -> CursorCLIFileChange? {
    patches(for: path).last
  }

  public func fileHistories() -> [JSONObject] {
    listChangedFiles().map { path in
      let history = patches(for: path)
      return [
        "path": .string(path),
        "changeCount": .number(Double(history.count)),
        "changes": .array(history.map { change in
          var object: JSONObject = [
            "path": .string(change.path),
            "operation": .string(change.operation.rawValue),
            "source": .string(change.source.rawValue),
            "previousPath": change.previousPath.map(JSONValue.string) ?? .null
          ]
          if let command = change.command {
            object["command"] = .string(command)
          }
          if let patch = change.patch {
            object["patch"] = .string(patch)
          }
          return .object(object)
        })
      ]
    }
  }
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

func rebuildPersistentFileIndex(configDir: String, cursorCLIHome: String?) throws -> JSONObject {
  let indexedAt = ISO8601DateFormatter().string(from: Date())
  let entries = discoverRolloutPaths(cursorCLIHome: cursorCLIHome).compactMap { path -> PersistentSessionFileIndexEntry? in
    guard let lines = try? CursorCLIRolloutReader.readRollout(path: path) else {
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

func findPersistentSessionsByFile(path: String, configDir: String, cursorCLIHome: String?) throws -> JSONObject {
  let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !target.isEmpty else {
    throw CursorCLIGraphQLError.missingVariable("path")
  }
  let url = persistentFileIndexURL(configDir: configDir)
  if !FileManager.default.isReadableFile(atPath: url.path) {
    _ = try rebuildPersistentFileIndex(configDir: configDir, cursorCLIHome: cursorCLIHome)
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
    (cursorOperationStringValue(lhs["lastModified"]) ?? "") > (cursorOperationStringValue(rhs["lastModified"]) ?? "")
  }
  return [
    "path": .string(target),
    "sessions": .array(sessions.map(JSONValue.object))
  ]
}

func rolloutSessionId(lines: [CursorCLIRolloutLine], path: String) -> String {
  for line in lines {
    if let payload = cursorOperationFileChangeObject(line.payload), let meta = cursorOperationFileChangeObject(payload["meta"]), let id = cursorOperationFileChangeString(meta["id"]) {
      return id
    }
  }
  let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  return name.hasPrefix("rollout-") ? String(name.dropFirst("rollout-".count)) : name
}

func changedFilesSummary(from lines: [CursorCLIRolloutLine]) -> [PersistentChangedFile] {
  var files: [String: PersistentChangedFile] = [:]
  for line in lines {
    for change in CursorCLIFileChanges.extract(from: line) {
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

func changedFilesSummary(changes: [CursorCLIFileChange], timestamp: String) -> [PersistentChangedFile] {
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

func fileChangeIndex(for session: CursorCLISession) throws -> CursorCLIFileChangeIndex {
  let index = try CursorCLIFileChangeIndex.rebuild(from: CursorCLIRolloutReader.readRollout(path: session.rolloutPath))
  if !index.listChangedFiles().isEmpty {
    return index
  }
  let raw = (try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""
  return CursorCLIFileChangeIndex(changes: parseRawPatchFileChanges(raw))
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

func fileChangeSummaryJSON(for session: CursorCLISession) throws -> JSONObject {
  let lines = try CursorCLIRolloutReader.readRollout(path: session.rolloutPath)
  let timestamp = cursorOperationISOString(session.updatedAt)
  let parsedFiles = changedFilesSummary(from: lines)
  let files = parsedFiles.isEmpty ? changedFilesSummary(changes: parseRawPatchFileChanges((try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""), timestamp: timestamp) : parsedFiles
  return [
    "sessionId": .string(session.id),
    "files": .array(files.map(persistentChangedFileJSON)),
    "totalFiles": .number(Double(files.count))
  ]
}

func filePatchHistoryJSON(for session: CursorCLISession) throws -> JSONObject {
  let lines = try CursorCLIRolloutReader.readRollout(path: session.rolloutPath)
  let timestamp = cursorOperationISOString(session.updatedAt)
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
    partial + (cursorOperationIntValue(file["changeCount"]) ?? 0)
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

func fileChangeDetails(from lines: [CursorCLIRolloutLine]) -> [FileChangeDetailDTO] {
  lines.flatMap { line in
    CursorCLIFileChanges.extract(from: line).map { change in
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

func parseRawPatchFileChanges(_ text: String) -> [CursorCLIFileChange] {
  text.split(separator: "\n").compactMap { rawLine in
    let line = String(rawLine)
    if let range = line.range(of: "*** Add File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CursorCLIFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .created, source: .applyPatch, patch: text)
    }
    if let range = line.range(of: "*** Delete File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CursorCLIFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .deleted, source: .applyPatch, patch: text)
    }
    if let range = line.range(of: "*** Update File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CursorCLIFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .modified, source: .applyPatch, patch: text)
    }
    return nil
  }
}
