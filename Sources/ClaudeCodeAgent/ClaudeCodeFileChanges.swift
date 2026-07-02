import Foundation
import RielaCore

public enum ClaudeCodeFileChangeSource: String, Equatable, Codable, Sendable {
  case applyPatch = "apply_patch"
  case shell
  case execCommand = "exec_command"
  case localShell = "local_shell"
}

public enum ClaudeCodeFileOperation: String, Equatable, Codable, Sendable {
  case created
  case modified
  case deleted
  case moved
}

public struct ClaudeCodeFileChange: Equatable, Codable, Sendable {
  public var path: String
  public var operation: ClaudeCodeFileOperation
  public var source: ClaudeCodeFileChangeSource
  public var previousPath: String?
  public var command: String?
  public var patch: String?

  public init(path: String, operation: ClaudeCodeFileOperation, source: ClaudeCodeFileChangeSource, previousPath: String? = nil, command: String? = nil, patch: String? = nil) {
    self.path = path
    self.operation = operation
    self.source = source
    self.previousPath = previousPath
    self.command = command
    self.patch = patch
  }
}

public enum ClaudeCodeFileChanges {
  public static func extract(from lines: [ClaudeCodeRolloutLine]) -> [ClaudeCodeFileChange] {
    var pending: [String: [ClaudeCodeFileChange]] = [:]
    var changes: [ClaudeCodeFileChange] = []
    for line in lines {
      guard let payload = fileChangeObject(line.payload) else {
        continue
      }
      if let callId = fileChangeString(payload["call_id"]) ?? fileChangeString(payload["callId"]) ?? fileChangeString(payload["id"]) {
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

  public static func extract(from line: ClaudeCodeRolloutLine) -> [ClaudeCodeFileChange] {
    guard let payload = fileChangeObject(line.payload) else {
      return []
    }
    if let exitCode = claudeCodeNumberValue(payload["exit_code"]), exitCode != 0 {
      return []
    }
    if let changes = fileChangeArray(payload["file_changes"]) {
      return changes
    }
    if let commandChanges = commandLikeFileChanges(payload: payload), !commandChanges.isEmpty {
      return commandChanges
    }
    if let patch = fileChangeString(payload["patch"]) ?? fileChangeString(payload["aggregated_output"]) {
      return parsePatchFileChanges(patch)
    }
    return []
  }
}

func isToolInvocationPayload(_ payload: JSONObject) -> Bool {
  guard let type = fileChangeString(payload["type"]) else {
    return false
  }
  return ["function_call", "local_shell_call", "custom_tool_call", "ExecCommandBegin"].contains(type)
}

func isToolResultPayload(_ payload: JSONObject) -> Bool {
  guard let type = fileChangeString(payload["type"]) else {
    return false
  }
  return ["function_call_output", "custom_tool_call_output", "local_shell_call_output", "ExecCommandEnd"].contains(type)
}

func isSuccessfulToolResult(_ payload: JSONObject) -> Bool {
  if claudeCodeBoolValue(payload["is_error"]) == true || claudeCodeBoolValue(payload["isError"]) == true {
    return false
  }
  if let exitCode = claudeCodeNumberValue(payload["exit_code"]) ?? claudeCodeNumberValue(payload["exitCode"]) {
    return exitCode == 0
  }
  if let status = fileChangeString(payload["status"])?.lowercased() {
    return isSuccessfulToolStatus(status)
  }
  if let output = fileChangeObject(payload["output"]) ?? fileChangeString(payload["output"]).flatMap(parseFileChangeArguments) {
    if claudeCodeBoolValue(output["is_error"]) == true || claudeCodeBoolValue(output["isError"]) == true {
      return false
    }
    if let metadata = fileChangeObject(output["metadata"]) {
      if claudeCodeBoolValue(metadata["is_error"]) == true || claudeCodeBoolValue(metadata["isError"]) == true {
        return false
      }
      if let exitCode = claudeCodeNumberValue(metadata["exit_code"]) ?? claudeCodeNumberValue(metadata["exitCode"]), exitCode != 0 {
        return false
      }
      if let status = fileChangeString(metadata["status"])?.lowercased() {
        return isSuccessfulToolStatus(status)
      }
    }
    if let exitCode = claudeCodeNumberValue(output["exit_code"]) ?? claudeCodeNumberValue(output["exitCode"]), exitCode != 0 {
      return false
    }
    if let status = fileChangeString(output["status"])?.lowercased() {
      return isSuccessfulToolStatus(status)
    }
  }
  return true
}

func isSuccessfulToolStatus(_ status: String) -> Bool {
  ["completed", "success", "succeeded", "ok"].contains(status)
}

func extractDirectChanges(from payload: JSONObject) -> [ClaudeCodeFileChange] {
  if let changes = fileChangeArray(payload["file_changes"]) {
    return changes
  }
  if let commandChanges = commandLikeFileChanges(payload: payload), !commandChanges.isEmpty {
    return commandChanges
  }
  if let patch = fileChangeString(payload["patch"]) ?? fileChangeString(payload["aggregated_output"]) ?? fileChangeString(payload["output"]) {
    return parsePatchFileChanges(patch)
  }
  return []
}

func commandLikeFileChanges(payload: JSONObject) -> [ClaudeCodeFileChange]? {
  let type = fileChangeString(payload["type"])
  guard ["function_call", "local_shell_call", "custom_tool_call", "ExecCommandBegin"].contains(type) else {
    return nil
  }
  if let patch = fileChangeString(payload["patch"]) ?? fileChangeString(payload["input"]) {
    let changes = parsePatchFileChanges(patch)
    if !changes.isEmpty {
      return changes
    }
  }
  let argumentObject = fileChangeObject(payload["arguments"]) ?? fileChangeString(payload["arguments"]).flatMap(parseFileChangeArguments)
  let command = fileChangeString(argumentObject?["command"])
    ?? fileChangeString(argumentObject?["cmd"])
    ?? fileChangeString(argumentObject?["script"])
    ?? claudeCodeStringArrayValue(argumentObject?["command"]).map { $0.joined(separator: " ") }
    ?? claudeCodeStringArrayValue(payload["command"]).map { $0.joined(separator: " ") }
  guard let command else {
    return nil
  }
  return parseShellFileChanges(command)
}

func parsePatchFileChanges(_ patch: String) -> [ClaudeCodeFileChange] {
  var pendingUpdatePath: String?
  var pendingUpdateIndex: Int?
  var changes: [ClaudeCodeFileChange] = []
  for rawLine in patch.split(separator: "\n") {
    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
    if line.hasPrefix("*** Add File: ") {
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      changes.append(ClaudeCodeFileChange(path: String(line.dropFirst("*** Add File: ".count)), operation: .created, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Delete File: ") {
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      changes.append(ClaudeCodeFileChange(path: String(line.dropFirst("*** Delete File: ".count)), operation: .deleted, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Update File: ") {
      pendingUpdatePath = String(line.dropFirst("*** Update File: ".count))
      pendingUpdateIndex = changes.count
      changes.append(ClaudeCodeFileChange(path: pendingUpdatePath ?? "", operation: .modified, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Move to: "), let from = pendingUpdatePath {
      let to = String(line.dropFirst("*** Move to: ".count))
      if let pendingUpdateIndex {
        changes[pendingUpdateIndex] = ClaudeCodeFileChange(path: to, operation: .modified, source: .applyPatch, previousPath: from, patch: patch)
      } else {
        changes.append(ClaudeCodeFileChange(path: to, operation: .modified, source: .applyPatch, previousPath: from, patch: patch))
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

func parseShellFileChanges(_ command: String) -> [ClaudeCodeFileChange] {
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
  var changes: [ClaudeCodeFileChange] = []
  let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
  guard !tokens.isEmpty else {
    return []
  }
  if tokens.prefix(2) == ["git", "mv"], tokens.count >= 4 {
    changes.append(ClaudeCodeFileChange(path: cleanShellPath(tokens[3]), operation: .moved, source: .shell, previousPath: cleanShellPath(tokens[2])))
  } else if tokens.prefix(2) == ["git", "rm"], tokens.count >= 3 {
    changes.append(ClaudeCodeFileChange(path: cleanShellPath(tokens[2]), operation: .deleted, source: .shell))
  } else if tokens[0] == "mv", tokens.count >= 3 {
    changes.append(ClaudeCodeFileChange(path: cleanShellPath(tokens[2]), operation: .moved, source: .shell, previousPath: cleanShellPath(tokens[1])))
  } else if tokens[0] == "cp", tokens.count >= 3 {
    changes.append(ClaudeCodeFileChange(path: cleanShellPath(tokens[2]), operation: .created, source: .shell))
  } else if tokens[0] == "rm", tokens.count >= 2 {
    changes.append(ClaudeCodeFileChange(path: cleanShellPath(tokens[1]), operation: .deleted, source: .shell))
  } else if tokens[0] == "touch", tokens.count >= 2 {
    for path in tokens.dropFirst() {
      changes.append(ClaudeCodeFileChange(path: cleanShellPath(path), operation: .created, source: .shell))
    }
  } else if ["sed", "perl"].contains(tokens[0]), tokens.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }), let path = tokens.last {
    changes.append(ClaudeCodeFileChange(path: cleanShellPath(path), operation: .modified, source: .shell))
  } else if tokens[0] == "tee", tokens.count >= 2 {
    let paths = tokens.dropFirst().filter { !$0.hasPrefix("-") && $0 != ">" && $0 != ">>" }
    for path in paths {
      changes.append(ClaudeCodeFileChange(path: cleanShellPath(path), operation: tokens.contains("-a") ? .modified : .created, source: .shell))
    }
  }
  for (index, token) in tokens.enumerated() where [">", ">>"].contains(token) && index + 1 < tokens.count {
    changes.append(ClaudeCodeFileChange(path: cleanShellPath(tokens[index + 1]), operation: token == ">" ? .created : .modified, source: .shell))
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
  if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
    value = String(value.dropFirst().dropLast())
  }
  return value
}

public struct ClaudeCodeFileChangeIndex: Equatable, Sendable {
  private var changes: [ClaudeCodeFileChange] = []

  public init(changes: [ClaudeCodeFileChange] = []) {
    self.changes = changes
  }

  public static func rebuild(from lines: [ClaudeCodeRolloutLine]) -> ClaudeCodeFileChangeIndex {
    ClaudeCodeFileChangeIndex(changes: ClaudeCodeFileChanges.extract(from: lines))
  }

  public func listChangedFiles() -> [String] {
    Array(Set(changes.flatMap { change in
      [change.path, change.previousPath].compactMap { $0 }
    })).sorted()
  }

  public func patches(for path: String) -> [ClaudeCodeFileChange] {
    changes.filter { $0.path == path || $0.previousPath == path }
  }

  public func find(_ path: String) -> ClaudeCodeFileChange? {
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

func fileChangeArray(_ value: JSONValue?) -> [ClaudeCodeFileChange]? {
  guard case let .array(values) = value else {
    return nil
  }
  return values.compactMap { entry in
    guard let object = fileChangeObject(entry), let path = fileChangeString(object["path"]) else {
      return nil
    }
    return ClaudeCodeFileChange(
      path: path,
      operation: ClaudeCodeFileOperation(rawValue: fileChangeString(object["operation"]) ?? "") ?? .modified,
      source: ClaudeCodeFileChangeSource(rawValue: fileChangeString(object["source"]) ?? "") ?? .shell,
      previousPath: fileChangeString(object["previousPath"] ?? object["previous_path"] ?? object["oldPath"] ?? object["from"]),
      command: fileChangeString(object["command"]),
      patch: fileChangeString(object["patch"])
    )
  }
}

func fileChangeObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}

func fileChangeString(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}

func claudeCodeStringArrayValue(_ value: JSONValue?) -> [String]? {
  guard case let .array(values)? = value else {
    return nil
  }
  return values.compactMap(fileChangeString)
}

func claudeCodeNumberValue(_ value: JSONValue?) -> Double? {
  switch value {
  case let .number(number):
    return number
  case let .integer(number):
    return Double(number)
  default:
    return nil
  }
}

func claudeCodeIntValue(_ value: JSONValue?) -> Int? {
  guard let number = claudeCodeNumberValue(value) else {
    return nil
  }
  return Int(number)
}

func claudeCodeNonNegativeUInt64Value(_ value: JSONValue?) -> UInt64? {
  guard let int = claudeCodeIntValue(value) else {
    return nil
  }
  return UInt64(max(0, int))
}

func claudeCodeStringValue(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}

func claudeCodeStringValue(_ value: Any?) -> String? {
  value as? String
}

func claudeCodeObjectValue(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}

func claudeCodeStringArray(_ value: JSONValue?) -> [String] {
  guard case let .array(values) = value else {
    return []
  }
  return values.compactMap(claudeCodeStringValue)
}

func parseLooseJSONValue(_ text: String) throws -> JSONValue {
  if let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
    return value
  }
  return .string(text)
}

func processOptions(from object: JSONObject, claudeCodeHome defaultClaudeCodeHome: String? = nil) throws -> ClaudeCodeProcessOptions {
  if let sandbox = claudeCodeStringValue(object["sandbox"]) {
    try validateStringUnion(sandbox, key: "sandbox", allowed: ["read-only", "workspace-write", "danger-full-access"])
  }
  if let streamGranularity = claudeCodeStringValue(object["streamGranularity"]) {
    try validateStringUnion(streamGranularity, key: "streamGranularity", allowed: ["event", "char"])
  }
  let images = try strictStringArray(object["images"], key: "images")
  let imagePaths = try strictStringArray(object["imagePaths"], key: "imagePaths")
  let additionalArguments = try strictStringArray(object["additionalArguments"], key: "additionalArguments")
  let additionalArgs = try strictStringArray(object["additionalArgs"], key: "additionalArgs")
  let environment = try strictStringDictionary(object["environment"], key: "environment")
  let environmentVariables = try strictStringDictionary(object["environmentVariables"], key: "environmentVariables")
  return ClaudeCodeProcessOptions(
    model: claudeCodeStringValue(object["model"]),
    cwd: claudeCodeStringValue(object["cwd"]),
    sandbox: claudeCodeStringValue(object["sandbox"]),
    approvalMode: claudeCodeStringValue(object["approvalMode"]),
    fullAuto: claudeCodeBoolValue(object["fullAuto"]) ?? false,
    images: images.isEmpty ? imagePaths : images,
    configOverrides: try strictStringArray(object["configOverrides"], key: "configOverrides"),
    additionalArguments: additionalArguments.isEmpty ? additionalArgs : additionalArguments,
    environmentVariables: environment.isEmpty ? environmentVariables : environment,
    systemPrompt: claudeCodeStringValue(object["systemPrompt"]),
    claudeCodeHome: claudeCodeStringValue(object["claudeCodeHome"]) ?? defaultClaudeCodeHome,
    streamGranularity: claudeCodeStringValue(object["streamGranularity"]),
    forwardApprovalMode: false
  )
}

func validateStringUnion(_ value: String, key: String, allowed: Set<String>) throws {
  guard allowed.contains(value) else {
    throw ClaudeCodeGraphQLError.invalidParam("\(key) must be one of \(allowed.sorted().joined(separator: ", "))")
  }
}

func strictStringArray(_ value: JSONValue?, key: String) throws -> [String] {
  guard let value else {
    return []
  }
  guard case let .array(values) = value else {
    throw ClaudeCodeGraphQLError.invalidParam("\(key) must be an array of strings")
  }
  return try values.enumerated().map { index, item in
    guard let string = claudeCodeStringValue(item) else {
      throw ClaudeCodeGraphQLError.invalidParam("\(key)[\(index)] must be a string")
    }
    return string
  }
}

func executableName(from object: JSONObject) -> String {
  claudeCodeStringValue(object["executableName"]) ?? claudeCodeStringValue(object["claudeBinary"]) ?? claudeCodeStringValue(object["claudeCodeBinary"]) ?? "claude"
}

func strictStringDictionary(_ value: JSONValue?, key: String) throws -> [String: String] {
  guard let value else {
    return [:]
  }
  guard case let .object(object) = value else {
    throw ClaudeCodeGraphQLError.invalidParam("\(key) must be an object with string values")
  }
  var result: [String: String] = [:]
  for (key, value) in object {
    guard let string = claudeCodeStringValue(value) else {
      throw ClaudeCodeGraphQLError.invalidParam("\(key) must be a string")
    }
    result[key] = string
  }
  return result
}

func claudeCodeBoolValue(_ value: JSONValue?) -> Bool? {
  guard case let .bool(value) = value else {
    return nil
  }
  return value
}

func extractCommandName(from document: String) -> String? {
  let trimmed = document.trimmingCharacters(in: .whitespacesAndNewlines)
  if let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}") {
    let inside = trimmed[trimmed.index(after: open)..<close]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return inside.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "{" }).first.map(String.init)
  }
  if ClaudeCodeGraphQLCommandExecutor.supportedCommandNames.contains(trimmed) || trimmed.contains(".") {
    return trimmed
  }
  return nil
}
