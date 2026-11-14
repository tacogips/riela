import Foundation
import RielaCore

func sessionListOptions(from variables: JSONObject, codexHome: String?) -> CodexSessionListOptions {
  CodexSessionListOptions(
    codexHome: codexHome,
    source: codexJSONString(variables["source"]).flatMap(CodexSessionSource.init(rawValue:)),
    cwd: codexJSONString(variables["cwd"]),
    branch: codexJSONString(variables["branch"]),
    limit: codexJSONInt(variables["limit"]) ?? 50,
    offset: codexJSONInt(variables["offset"]) ?? 0,
    sortBy: codexJSONString(variables["sortBy"]) ?? "createdAt",
    sortOrder: codexJSONString(variables["sortOrder"]) ?? "desc"
  )
}

func transcriptSearchOptions(from variables: JSONObject) -> CodexSessionTranscriptSearchOptions {
  CodexSessionTranscriptSearchOptions(
    caseSensitive: codexJSONBool(variables["caseSensitive"]) ?? false,
    role: codexJSONString(variables["role"]) ?? "both",
    maxBytes: codexJSONInt(variables["maxBytes"]).map { max(0, $0) },
    maxEvents: codexJSONInt(variables["maxEvents"]).map { max(0, $0) },
    maxSessions: codexJSONInt(variables["maxSessions"]).map { max(0, $0) },
    timeoutMs: codexJSONInt(variables["timeoutMs"]).map { max(0, $0) },
    limit: max(0, codexJSONInt(variables["limit"]) ?? 50),
    offset: max(0, codexJSONInt(variables["offset"]) ?? 0)
  )
}

private func rebuildFileIndex(codexHome: String?) throws -> CodexFileChangeIndex {
  let lines = discoverRolloutPaths(codexHome: codexHome).flatMap { path in
    (try? CodexRolloutReader.readRollout(path: path)) ?? []
  }
  return CodexFileChangeIndex.rebuild(from: lines)
}

private struct PersistentChangedFile: Codable {
  var path: String
  var operation: String
  var changeCount: Int
  var lastModified: String
}

private struct PersistentSessionFileIndexEntry: Codable {
  var sessionId: String
  var files: [PersistentChangedFile]
  var indexedAt: String
}

private struct PersistentFileChangeIndex: Codable {
  var sessions: [PersistentSessionFileIndexEntry]
  var updatedAt: String
}

private func persistentFileIndexURL(configDir: String) -> URL {
  URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("file-changes-index.json")
}

func rebuildPersistentFileIndex(configDir: String, codexHome: String?) throws -> JSONObject {
  let indexedAt = ISO8601DateFormatter().string(from: Date())
  let entries = discoverRolloutPaths(codexHome: codexHome).compactMap { path -> PersistentSessionFileIndexEntry? in
    guard let lines = try? CodexRolloutReader.readRollout(path: path) else {
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

func findPersistentSessionsByFile(path: String, configDir: String, codexHome: String?) throws -> JSONObject {
  let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !target.isEmpty else {
    throw CodexGraphQLError.missingVariable("path")
  }
  let url = persistentFileIndexURL(configDir: configDir)
  if !FileManager.default.isReadableFile(atPath: url.path) {
    _ = try rebuildPersistentFileIndex(configDir: configDir, codexHome: codexHome)
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
    (codexJSONString(lhs["lastModified"]) ?? "") > (codexJSONString(rhs["lastModified"]) ?? "")
  }
  return [
    "path": .string(target),
    "sessions": .array(sessions.map(JSONValue.object))
  ]
}

private func rolloutSessionId(lines: [CodexRolloutLine], path: String) -> String {
  for line in lines {
    if let payload = fileChangeObject(line.payload), let meta = fileChangeObject(payload["meta"]), let id = fileChangeString(meta["id"]) {
      return id
    }
  }
  let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  return name.hasPrefix("rollout-") ? String(name.dropFirst("rollout-".count)) : name
}

private func changedFilesSummary(from lines: [CodexRolloutLine]) -> [PersistentChangedFile] {
  var files: [String: PersistentChangedFile] = [:]
  for line in lines {
    for change in CodexFileChanges.extract(from: line) {
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

private func changedFilesSummary(changes: [CodexFileChange], timestamp: String) -> [PersistentChangedFile] {
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

private func fileChangeIndex(for session: CodexSession) throws -> CodexFileChangeIndex {
  let index = try CodexFileChangeIndex.rebuild(from: CodexRolloutReader.readRollout(path: session.rolloutPath))
  if !index.listChangedFiles().isEmpty {
    return index
  }
  let raw = (try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""
  return CodexFileChangeIndex(changes: parseRawPatchFileChanges(raw))
}

private struct FileChangeDetailDTO {
  var path: String
  var timestamp: String
  var operation: String
  var source: String
  var previousPath: String?
  var command: String?
  var patch: String?
}

func fileChangeSummaryJSON(for session: CodexSession) throws -> JSONObject {
  let lines = try CodexRolloutReader.readRollout(path: session.rolloutPath)
  let timestamp = isoString(session.updatedAt)
  let parsedFiles = changedFilesSummary(from: lines)
  let files = parsedFiles.isEmpty ? changedFilesSummary(changes: parseRawPatchFileChanges((try? String(contentsOfFile: session.rolloutPath, encoding: .utf8)) ?? ""), timestamp: timestamp) : parsedFiles
  return [
    "sessionId": .string(session.id),
    "files": .array(files.map(persistentChangedFileJSON)),
    "totalFiles": .number(Double(files.count))
  ]
}

func filePatchHistoryJSON(for session: CodexSession) throws -> JSONObject {
  let lines = try CodexRolloutReader.readRollout(path: session.rolloutPath)
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
      grouped[previousPath, default: []].append(
        FileChangeDetailDTO(
          path: previousPath,
          timestamp: detail.timestamp,
          operation: "deleted",
          source: detail.source,
          previousPath: detail.previousPath,
          command: detail.command,
          patch: detail.patch
        )
      )
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
    partial + (codexJSONInt(file["changeCount"]) ?? 0)
  }
  return [
    "sessionId": .string(session.id),
    "files": .array(files.map(JSONValue.object)),
    "totalFiles": .number(Double(files.count)),
    "totalChanges": .number(Double(totalChanges))
  ]
}

private func persistentChangedFileJSON(_ file: PersistentChangedFile) -> JSONValue {
  .object([
    "path": .string(file.path),
    "operation": .string(file.operation),
    "changeCount": .number(Double(file.changeCount)),
    "lastModified": .string(file.lastModified)
  ])
}

private func fileChangeDetails(from lines: [CodexRolloutLine]) -> [FileChangeDetailDTO] {
  lines.flatMap { line in
    CodexFileChanges.extract(from: line).map { change in
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

private func fileChangeDetailJSON(_ detail: FileChangeDetailDTO) -> JSONObject {
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

private func parseRawPatchFileChanges(_ text: String) -> [CodexFileChange] {
  text.split(separator: "\n").compactMap { rawLine in
    let line = String(rawLine)
    if let range = line.range(of: "*** Add File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CodexFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .created, source: .applyPatch, patch: text)
    }
    if let range = line.range(of: "*** Delete File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CodexFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .deleted, source: .applyPatch, patch: text)
    }
    if let range = line.range(of: "*** Update File: ") {
      let path = line[range.upperBound...].split(separator: "\\").first.map(String.init) ?? ""
      return CodexFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), operation: .modified, source: .applyPatch, patch: text)
    }
    return nil
  }
}

func sessionJSON(_ session: CodexSession) -> JSONValue {
  var object: JSONObject = [
    "id": .string(session.id),
    "rolloutPath": .string(session.rolloutPath),
    "createdAt": .string(isoString(session.createdAt)),
    "updatedAt": .string(isoString(session.updatedAt)),
    "source": .string(session.source.rawValue),
    "modelProvider": session.modelProvider.map(JSONValue.string) ?? .null,
    "cwd": .string(session.cwd),
    "cliVersion": .string(session.cliVersion),
    "title": .string(session.title),
    "firstUserMessage": session.firstUserMessage.map(JSONValue.string) ?? .null,
    "archivedAt": session.archivedAt.map { .string(isoString($0)) } ?? .null,
    "forkedFromId": session.forkedFromId.map(JSONValue.string) ?? .null
  ]
  if let git = session.git {
    object["git"] = .object([
      "branch": git.branch.map(JSONValue.string) ?? .null,
      "sha": git.sha.map(JSONValue.string) ?? .null,
      "originURL": git.originURL.map(JSONValue.string) ?? .null
    ])
  } else {
    object["git"] = .null
  }
  return .object(object)
}

private func isoString(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}

func extractLegacyCommandInvocation(from document: String, variables: JSONObject) -> (commandName: String?, variables: JSONObject) {
  guard document.contains("command(") else {
    return (nil, variables)
  }
  let commandName = extractGraphQLStringArgument(named: "name", from: document, variables: variables)
  if case let .object(params)? = variables["param"] {
    return (commandName, params)
  }
  if case let .object(params)? = variables["params"] {
    return (commandName, params)
  }
  if let params = extractInlineGraphQLParams(from: document) {
    return (commandName, params)
  }
  return (commandName, variables)
}

private func extractGraphQLStringArgument(named argumentName: String, from document: String, variables: JSONObject) -> String? {
  let escapedName = NSRegularExpression.escapedPattern(for: argumentName)
  if let literal = firstRegexCapture(in: document, pattern: #"\b"# + escapedName + #"\s*:\s*"([^"]+)""#) {
    return literal
  }
  guard let variableName = firstRegexCapture(in: document, pattern: #"\b"# + escapedName + #"\s*:\s*\$([A-Za-z_][A-Za-z0-9_]*)"#) else {
    return nil
  }
  return codexJSONString(variables[variableName])
}

func isPingDocument(_ document: String) -> Bool {
  let stripped = document
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return stripped == "query { ping }" || stripped == "{ ping }"
}

private func extractInlineGraphQLParams(from document: String) -> JSONObject? {
  guard let paramsRange = document.range(of: "params") else {
    return nil
  }
  guard let colon = document[paramsRange.upperBound...].firstIndex(of: ":") else {
    return nil
  }
  guard let open = document[colon...].firstIndex(of: "{") else {
    return nil
  }
  guard let close = matchingBrace(in: document, open: open) else {
    return nil
  }
  let literal = String(document[open...close])
  let jsonText = quoteGraphQLObjectKeys(literal)
  guard
    let data = jsonText.data(using: .utf8),
    let value = try? JSONDecoder().decode(JSONValue.self, from: data),
    case let .object(object) = value
  else {
    return nil
  }
  return object
}

private func matchingBrace(in text: String, open: String.Index) -> String.Index? {
  var depth = 0
  var inString = false
  var escaped = false
  var index = open
  while index < text.endIndex {
    let character = text[index]
    if inString {
      if escaped {
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        inString = false
      }
    } else if character == "\"" {
      inString = true
    } else if character == "{" {
      depth += 1
    } else if character == "}" {
      depth -= 1
      if depth == 0 {
        return index
      }
    }
    index = text.index(after: index)
  }
  return nil
}

private func quoteGraphQLObjectKeys(_ literal: String) -> String {
  literal.replacingOccurrences(
    of: #"([,{]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#,
    with: #"$1"$2":"#,
    options: .regularExpression
  )
}

private func firstRegexCapture(in text: String, pattern: String) -> String? {
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return nil
  }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else {
    return nil
  }
  return String(text[capture])
}

func shorthandOperation(for command: String) -> String {
  if command == "session.watch" {
    return "subscription"
  }
  return mutationCommandNames.contains(command) ? "mutation" : "query"
}

func escapeGraphQLString(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
}

private let mutationCommandNames: Set<String> = [
  "session.run",
  "session.resume",
  "session.fork",
  "group.create",
  "group.add",
  "group.remove",
  "group.pause",
  "group.resume",
  "group.delete",
  "group.run",
  "queue.create",
  "queue.add",
  "queue.pause",
  "queue.resume",
  "queue.delete",
  "queue.update",
  "queue.remove",
  "queue.move",
  "queue.mode",
  "queue.run",
  "bookmark.add",
  "bookmark.delete",
  "token.create",
  "token.revoke",
  "token.rotate",
  "files.rebuild"
]

func rolloutLineJSON(_ line: CodexRolloutLine) -> JSONValue {
  .object([
    "timestamp": .string(line.timestamp),
    "type": .string(line.type),
    "payload": line.payload
  ])
}

func toolVersionsJSON(variables: JSONObject) -> JSONObject {
  let codex = probeToolVersion(executableName(from: variables), arguments: ["--version"])
  let includeGit = codexJSONBool(variables["includeGit"]) ?? true
  return [
    "version": .string("swift"),
    "codex": .object(codex),
    "git": includeGit ? .object(probeToolVersion(codexJSONString(variables["gitBinary"]) ?? "git", arguments: ["--version"])) : .null
  ]
}

private func probeToolVersion(_ executable: String, arguments: [String]) -> JSONObject {
  let process = Process()
  process.executableURL = resolveExecutableURL(executable)
  process.arguments = arguments
  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  do {
    try process.run()
    process.waitUntilExit()
    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return [
      "available": .bool(process.terminationStatus == 0),
      "version": .string(out.trimmingCharacters(in: .whitespacesAndNewlines)),
      "exitCode": .number(Double(process.terminationStatus)),
      "stderr": .string(err.trimmingCharacters(in: .whitespacesAndNewlines))
    ]
  } catch {
    return [
      "available": .bool(false),
      "version": .null,
      "error": .string(String(describing: error))
    ]
  }
}

private func resolveExecutableURL(_ executable: String) -> URL {
  if executable.contains("/") {
    return URL(fileURLWithPath: executable)
  }
  let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
  for directory in environmentPath.split(separator: ":").map(String.init) {
    let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(executable)
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
  }
  return URL(fileURLWithPath: executable)
}

private func processExecutionJSON(process: CodexProcessRecord, result: CodexProcessExecution) -> JSONObject {
  [
    "processId": .string(process.id),
    "pid": .number(Double(process.pid)),
    "command": .string(process.command),
    "stdout": .string(result.stdout),
    "stderr": .string(result.stderr),
    "exitCode": .number(Double(result.exitCode)),
    "arguments": .array(process.arguments.map(JSONValue.string))
  ]
}

func processHandleJSON(_ process: CodexProcessRecord) -> JSONObject {
  [
    "processId": .string(process.id),
    "pid": .number(Double(process.pid)),
    "command": .string(process.command),
    "status": .string(process.status.rawValue),
    "arguments": .array(process.arguments.map(JSONValue.string))
  ]
}

func sessionExecutionJSON(process: CodexProcessRecord, result: CodexProcessExecution) -> JSONObject {
  let lines = result.stdout.split(separator: "\n").compactMap { CodexRolloutReader.parseRolloutLine(String($0)) }
  var object = processExecutionJSON(process: process, result: result)
  object["sessionId"] = extractSessionId(from: lines).map(JSONValue.string) ?? .null
  object["lines"] = .array(lines.map(rolloutLineJSON))
  return object
}

private func extractSessionId(from lines: [CodexRolloutLine]) -> String? {
  for line in lines {
    guard let payload = fileChangeObject(line.payload) else {
      continue
    }
    if let sessionId = fileChangeString(payload["session_id"]) ?? fileChangeString(payload["sessionId"]) {
      return sessionId
    }
    if let meta = fileChangeObject(payload["meta"]), let id = fileChangeString(meta["id"]) {
      return id
    }
  }
  return nil
}

func jsonValue<Value: Encodable>(_ value: Value?) throws -> JSONValue {
  guard let value else {
    return .null
  }
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

func requiredString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = codexJSONString(object[key]), !value.isEmpty else {
    throw CodexGraphQLError.missingVariable(key)
  }
  return value
}

func requiredString(_ object: JSONObject, _ key: String, fallback: String) throws -> String {
  if let value = codexJSONString(object[key]), !value.isEmpty {
    return value
  }
  if let value = codexJSONString(object[fallback]), !value.isEmpty {
    return value
  }
  throw CodexGraphQLError.missingVariable(key)
}

func requiredNonBlankString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = codexJSONString(object[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    throw CodexGraphQLError.missingVariable(key)
  }
  return value
}

private func resolveQueueId(_ idOrName: String, configDir: String) throws -> String {
  try CodexQueuePersistence.findQueue(idOrName, configDir: configDir)?.id ?? idOrName
}

func resolveExistingQueueId(_ idOrName: String, configDir: String) throws -> String {
  guard let queue = try CodexQueuePersistence.findQueue(idOrName, configDir: configDir) else {
    throw CodexGraphQLError.missingVariable("Queue not found")
  }
  return queue.id
}

private func resolveGroupId(_ idOrName: String, configDir: String) throws -> String {
  try CodexGroupPersistence.findGroup(idOrName, configDir: configDir)?.id ?? idOrName
}

func resolveExistingGroupId(_ idOrName: String, configDir: String) throws -> String {
  guard let group = try CodexGroupPersistence.findGroup(idOrName, configDir: configDir) else {
    throw CodexGraphQLError.missingVariable("Group not found")
  }
  return group.id
}

func defaultCodexAgentConfigDir() -> String {
  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/codex-agent", isDirectory: true).path
}
