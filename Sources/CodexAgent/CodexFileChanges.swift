import Foundation
import RielaCore

public enum CodexMarkdown {
  public struct Section: Equatable, Sendable {
    public var level: Int
    public var heading: String
    public var body: String
  }

  public struct Task: Equatable, Sendable {
    public var sectionHeading: String
    public var text: String
    public var checked: Bool
  }

  public static func parseTasks(_ markdown: String) -> [Task] {
    var heading = ""
    var tasks: [Task] = []
    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if line.hasPrefix("#") {
        heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# " ))
      } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
        let checked = line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ")
        tasks.append(Task(sectionHeading: heading, text: String(line.dropFirst(6)), checked: checked))
      }
    }
    return tasks
  }

  public static func parseSections(_ markdown: String) -> [Section] {
    var sections: [Section] = []
    var currentLevel = 0
    var currentHeading = ""
    var body: [String] = []
    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if let heading = parseHeading(line) {
        if !currentHeading.isEmpty || !body.isEmpty {
          sections.append(Section(level: currentLevel, heading: currentHeading, body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        currentLevel = heading.level
        currentHeading = heading.text
        body = []
      } else {
        body.append(line)
      }
    }
    if !currentHeading.isEmpty || !body.isEmpty {
      sections.append(Section(level: currentLevel, heading: currentHeading, body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    return sections
  }

  private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
    let hashes = line.prefix { $0 == "#" }.count
    guard hashes > 0, hashes < line.count, line.dropFirst(hashes).first == " " else {
      return nil
    }
    return (hashes, line.dropFirst(hashes).trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

public enum CodexFileChangeSource: String, Equatable, Codable, Sendable {
  case applyPatch = "apply_patch"
  case shell
  case execCommand = "exec_command"
  case localShell = "local_shell"
}

public enum CodexFileOperation: String, Equatable, Codable, Sendable {
  case created
  case modified
  case deleted
  case moved
}

public struct CodexFileChange: Equatable, Codable, Sendable {
  public var path: String
  public var operation: CodexFileOperation
  public var source: CodexFileChangeSource
  public var previousPath: String?
  public var command: String?
  public var patch: String?

  public init(path: String, operation: CodexFileOperation, source: CodexFileChangeSource, previousPath: String? = nil, command: String? = nil, patch: String? = nil) {
    self.path = path
    self.operation = operation
    self.source = source
    self.previousPath = previousPath
    self.command = command
    self.patch = patch
  }
}

public enum CodexFileChanges {
  public static func extract(from lines: [CodexRolloutLine]) -> [CodexFileChange] {
    var pending: [String: [CodexFileChange]] = [:]
    var changes: [CodexFileChange] = []
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

  public static func extract(from line: CodexRolloutLine) -> [CodexFileChange] {
    guard let payload = fileChangeObject(line.payload) else {
      return []
    }
    if let exitCode = numberValue(payload["exit_code"]), exitCode != 0 {
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

private func isToolInvocationPayload(_ payload: JSONObject) -> Bool {
  guard let type = fileChangeString(payload["type"]) else {
    return false
  }
  return ["function_call", "local_shell_call", "custom_tool_call", "ExecCommandBegin"].contains(type)
}

private func isToolResultPayload(_ payload: JSONObject) -> Bool {
  guard let type = fileChangeString(payload["type"]) else {
    return false
  }
  return ["function_call_output", "custom_tool_call_output", "local_shell_call_output", "ExecCommandEnd"].contains(type)
}

private func isSuccessfulToolResult(_ payload: JSONObject) -> Bool {
  if codexJSONBool(payload["is_error"]) == true || codexJSONBool(payload["isError"]) == true {
    return false
  }
  if let exitCode = numberValue(payload["exit_code"]) ?? numberValue(payload["exitCode"]) {
    return exitCode == 0
  }
  if let status = fileChangeString(payload["status"])?.lowercased() {
    return isSuccessfulToolStatus(status)
  }
  if let output = fileChangeObject(payload["output"]) ?? fileChangeString(payload["output"]).flatMap(parseFileChangeArguments) {
    if codexJSONBool(output["is_error"]) == true || codexJSONBool(output["isError"]) == true {
      return false
    }
    if let metadata = fileChangeObject(output["metadata"]) {
      if codexJSONBool(metadata["is_error"]) == true || codexJSONBool(metadata["isError"]) == true {
        return false
      }
      if let exitCode = numberValue(metadata["exit_code"]) ?? numberValue(metadata["exitCode"]), exitCode != 0 {
        return false
      }
      if let status = fileChangeString(metadata["status"])?.lowercased() {
        return isSuccessfulToolStatus(status)
      }
    }
    if let exitCode = numberValue(output["exit_code"]) ?? numberValue(output["exitCode"]), exitCode != 0 {
      return false
    }
    if let status = fileChangeString(output["status"])?.lowercased() {
      return isSuccessfulToolStatus(status)
    }
  }
  return true
}

private func isSuccessfulToolStatus(_ status: String) -> Bool {
  ["completed", "success", "succeeded", "ok"].contains(status)
}

private func extractDirectChanges(from payload: JSONObject) -> [CodexFileChange] {
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

private func commandLikeFileChanges(payload: JSONObject) -> [CodexFileChange]? {
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
    ?? stringArrayValue(argumentObject?["command"]).map { $0.joined(separator: " ") }
    ?? stringArrayValue(payload["command"]).map { $0.joined(separator: " ") }
  guard let command else {
    return nil
  }
  return parseShellFileChanges(command)
}

private func parsePatchFileChanges(_ patch: String) -> [CodexFileChange] {
  var pendingUpdatePath: String?
  var pendingUpdateIndex: Int?
  var changes: [CodexFileChange] = []
  for rawLine in patch.split(separator: "\n") {
    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
    if line.hasPrefix("*** Add File: ") {
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      changes.append(CodexFileChange(path: String(line.dropFirst("*** Add File: ".count)), operation: .created, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Delete File: ") {
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      changes.append(CodexFileChange(path: String(line.dropFirst("*** Delete File: ".count)), operation: .deleted, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Update File: ") {
      pendingUpdatePath = String(line.dropFirst("*** Update File: ".count))
      pendingUpdateIndex = changes.count
      changes.append(CodexFileChange(path: pendingUpdatePath ?? "", operation: .modified, source: .applyPatch, patch: patch))
      continue
    }
    if line.hasPrefix("*** Move to: "), let from = pendingUpdatePath {
      let to = String(line.dropFirst("*** Move to: ".count))
      if let pendingUpdateIndex {
        changes[pendingUpdateIndex] = CodexFileChange(path: to, operation: .modified, source: .applyPatch, previousPath: from, patch: patch)
      } else {
        changes.append(CodexFileChange(path: to, operation: .modified, source: .applyPatch, previousPath: from, patch: patch))
      }
      pendingUpdatePath = nil
      pendingUpdateIndex = nil
      continue
    }
  }
  return changes
}

private func parseFileChangeArguments(_ text: String) -> JSONObject? {
  guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data), case let .object(object) = value else {
    return nil
  }
  return object
}

private func parseShellFileChanges(_ command: String) -> [CodexFileChange] {
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
  var changes: [CodexFileChange] = []
  let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
  guard !tokens.isEmpty else {
    return []
  }
  if tokens.prefix(2) == ["git", "mv"], tokens.count >= 4 {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[3]), operation: .moved, source: .shell, previousPath: cleanShellPath(tokens[2])))
  } else if tokens.prefix(2) == ["git", "rm"], tokens.count >= 3 {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[2]), operation: .deleted, source: .shell))
  } else if tokens[0] == "mv", tokens.count >= 3 {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[2]), operation: .moved, source: .shell, previousPath: cleanShellPath(tokens[1])))
  } else if tokens[0] == "cp", tokens.count >= 3 {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[2]), operation: .created, source: .shell))
  } else if tokens[0] == "rm", tokens.count >= 2 {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[1]), operation: .deleted, source: .shell))
  } else if tokens[0] == "touch", tokens.count >= 2 {
    for path in tokens.dropFirst() {
      changes.append(CodexFileChange(path: cleanShellPath(path), operation: .created, source: .shell))
    }
  } else if ["sed", "perl"].contains(tokens[0]), tokens.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }), let path = tokens.last {
    changes.append(CodexFileChange(path: cleanShellPath(path), operation: .modified, source: .shell))
  } else if tokens[0] == "tee", tokens.count >= 2 {
    let paths = tokens.dropFirst().filter { !$0.hasPrefix("-") && $0 != ">" && $0 != ">>" }
    for path in paths {
      changes.append(CodexFileChange(path: cleanShellPath(path), operation: tokens.contains("-a") ? .modified : .created, source: .shell))
    }
  }
  for (index, token) in tokens.enumerated() where [">", ">>"].contains(token) && index + 1 < tokens.count {
    changes.append(CodexFileChange(path: cleanShellPath(tokens[index + 1]), operation: token == ">" ? .created : .modified, source: .shell))
  }
  return changes.map { change in
    var annotated = change
    annotated.command = command
    return annotated
  }
}

private func unwrapBashLoginCommand(_ command: String) -> String? {
  let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
  for prefix in ["bash -lc ", "sh -lc ", "zsh -lc "] where trimmed.hasPrefix(prefix) {
    return stripShellQuotes(String(trimmed.dropFirst(prefix.count)))
  }
  return nil
}

private func cleanShellPath(_ path: String) -> String {
  stripShellQuotes(path).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`; "))
}

private func stripShellQuotes(_ text: String) -> String {
  var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
    value = String(value.dropFirst().dropLast())
  }
  return value
}

public struct CodexFileChangeIndex: Equatable, Sendable {
  private var changes: [CodexFileChange] = []

  public init(changes: [CodexFileChange] = []) {
    self.changes = changes
  }

  public static func rebuild(from lines: [CodexRolloutLine]) -> CodexFileChangeIndex {
    CodexFileChangeIndex(changes: CodexFileChanges.extract(from: lines))
  }

  public func listChangedFiles() -> [String] {
    Array(Set(changes.flatMap { change in
      [change.path, change.previousPath].compactMap { $0 }
    })).sorted()
  }

  public func patches(for path: String) -> [CodexFileChange] {
    changes.filter { $0.path == path || $0.previousPath == path }
  }

  public func find(_ path: String) -> CodexFileChange? {
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

private func fileChangeArray(_ value: JSONValue?) -> [CodexFileChange]? {
  guard case let .array(values) = value else {
    return nil
  }
  return values.compactMap { entry in
    guard let object = fileChangeObject(entry), let path = fileChangeString(object["path"]) else {
      return nil
    }
    return CodexFileChange(
      path: path,
      operation: CodexFileOperation(rawValue: fileChangeString(object["operation"]) ?? "") ?? .modified,
      source: CodexFileChangeSource(rawValue: fileChangeString(object["source"]) ?? "") ?? .shell,
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

private func stringArrayValue(_ value: JSONValue?) -> [String]? {
  guard case let .array(values)? = value else {
    return nil
  }
  return values.compactMap(fileChangeString)
}

private func numberValue(_ value: JSONValue?) -> Double? {
  value?.asDouble
}

func codexJSONInt(_ value: JSONValue?) -> Int? {
  guard let number = value?.asInt64 else {
    return nil
  }
  return Int(number)
}

func nonNegativeUInt64Value(_ value: JSONValue?) -> UInt64? {
  guard let int = codexJSONInt(value) else {
    return nil
  }
  return UInt64(max(0, int))
}

func codexJSONString(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}

func codexJSONStringArray(_ value: JSONValue?) -> [String] {
  guard case let .array(values) = value else {
    return []
  }
  return values.compactMap(codexJSONString)
}

func parseLooseJSONValue(_ text: String) throws -> JSONValue {
  if let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
    return value
  }
  return .string(text)
}

func processOptions(from object: JSONObject, codexHome defaultCodexHome: String? = nil) throws -> CodexProcessOptions {
  if let sandbox = codexJSONString(object["sandbox"]) {
    try validateStringUnion(sandbox, key: "sandbox", allowed: ["read-only", "workspace-write", "danger-full-access"])
  }
  if let approvalMode = codexJSONString(object["approvalMode"]) {
    try validateStringUnion(approvalMode, key: "approvalMode", allowed: ["always", "unless-allow-listed", "untrusted", "on-request", "on-failure", "never"])
  }
  if let streamGranularity = codexJSONString(object["streamGranularity"]) {
    try validateStringUnion(streamGranularity, key: "streamGranularity", allowed: ["event", "char"])
  }
  let images = try strictStringArray(object["images"], key: "images")
  let imagePaths = try strictStringArray(object["imagePaths"], key: "imagePaths")
  let additionalArguments = try strictStringArray(object["additionalArguments"], key: "additionalArguments")
  let additionalArgs = try strictStringArray(object["additionalArgs"], key: "additionalArgs")
  let environment = try strictStringDictionary(object["environment"], key: "environment")
  let environmentVariables = try strictStringDictionary(object["environmentVariables"], key: "environmentVariables")
  return CodexProcessOptions(
    model: codexJSONString(object["model"]),
    cwd: codexJSONString(object["cwd"]),
    sandbox: codexJSONString(object["sandbox"]),
    approvalMode: codexJSONString(object["approvalMode"]),
    fullAuto: codexJSONBool(object["fullAuto"]) ?? false,
    images: images.isEmpty ? imagePaths : images,
    configOverrides: try strictStringArray(object["configOverrides"], key: "configOverrides"),
    additionalArguments: additionalArguments.isEmpty ? additionalArgs : additionalArguments,
    environmentVariables: environment.isEmpty ? environmentVariables : environment,
    systemPrompt: codexJSONString(object["systemPrompt"]),
    codexHome: codexJSONString(object["codexHome"]) ?? defaultCodexHome,
    streamGranularity: codexJSONString(object["streamGranularity"]),
    forwardApprovalMode: false
  )
}

private func validateStringUnion(_ value: String, key: String, allowed: Set<String>) throws {
  guard allowed.contains(value) else {
    throw CodexGraphQLError.invalidParam("\(key) must be one of \(allowed.sorted().joined(separator: ", "))")
  }
}

private func strictStringArray(_ value: JSONValue?, key: String) throws -> [String] {
  guard let value else {
    return []
  }
  guard case let .array(values) = value else {
    throw CodexGraphQLError.invalidParam("\(key) must be an array of strings")
  }
  return try values.enumerated().map { index, item in
    guard let string = codexJSONString(item) else {
      throw CodexGraphQLError.invalidParam("\(key)[\(index)] must be a string")
    }
    return string
  }
}

func executableName(from object: JSONObject) -> String {
  codexJSONString(object["executableName"]) ?? codexJSONString(object["codexBinary"]) ?? "codex"
}

private func strictStringDictionary(_ value: JSONValue?, key: String) throws -> [String: String] {
  guard let value else {
    return [:]
  }
  guard case let .object(object) = value else {
    throw CodexGraphQLError.invalidParam("\(key) must be an object with string values")
  }
  var result: [String: String] = [:]
  for (key, value) in object {
    guard let string = codexJSONString(value) else {
      throw CodexGraphQLError.invalidParam("\(key) must be a string")
    }
    result[key] = string
  }
  return result
}

func codexJSONBool(_ value: JSONValue?) -> Bool? {
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
  if CodexGraphQLCommandExecutor.supportedCommandNames.contains(trimmed) || trimmed.contains(".") {
    return trimmed
  }
  return nil
}
