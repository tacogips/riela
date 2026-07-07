import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension BuiltinWorkflowAddonResolver {
  func executeAppleNotesList(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    guard input.addon.env?.isEmpty != false else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) does not support addon.env")
    }

    let listContext = try AppleNotesListContext(input: input, environment: environment)
    let query = try listContext.graphQLQuery()
    let resolvedBinary = try listContext.resolvedBinary()
    let processOutput = try AppleGatewayProcessRunner(runtimeEnvironment: environment).run(
      executablePath: resolvedBinary.path,
      arguments: ["graphql", "--query", query],
      deadline: context.deadline
    )
    let envelope = try AppleGatewayGraphQLEnvelope(stdout: processOutput.stdout, addonName: input.addon.name)
    if !envelope.errors.isEmpty {
      throw AdapterExecutionError(
        .providerError,
        "\(input.addon.name) GraphQL errors: \(appleGatewayCompactText(envelope.errors.joined(separator: "; ")))"
      )
    }
    let data = envelope.data
    let notesPayload = try AppleGatewayNotesPayload(data: data, addonName: input.addon.name)
    let requestId = envelope.requestId ?? ""
    let appleNotes: JSONObject = [
      "accounts": .array(notesPayload.accounts),
      "folders": .array(notesPayload.folders),
      "notes": .array(notesPayload.notes.map(JSONValue.object)),
      "pageInfo": .object(notesPayload.pageInfo),
      "totalCount": notesPayload.totalCount,
      "requestId": .string(requestId)
    ]
    let payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "appleNotes": .object(appleNotes),
      "noteCount": .number(Double(notesPayload.notes.count)),
      "replyText": .string("Listed \(notesPayload.notes.count) Apple Notes."),
      "appleGateway": .object([
        "binary": .object([
          "path": .string(resolvedBinary.path),
          "source": .string(resolvedBinary.source.rawValue)
        ]),
        "requestId": .string(requestId),
        "rawData": .object(data)
      ])
    ]

    return AdapterExecutionOutput(
      provider: "apple-gateway",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: ["always": true, "has_notes": !notesPayload.notes.isEmpty],
      payload: payload
    )
  }
}

private struct AppleNotesListContext {
  private static let executableName = "apple-gateway"
  private static let executableEnvironmentName = "APPLE_GATEWAY_BIN"
  private static let defaultFirst = 25
  private static let maxFirst = 100

  var input: WorkflowAddonExecutionInput
  var config: JSONObject
  var variables: JSONObject
  var environment: [String: String]

  init(input: WorkflowAddonExecutionInput, environment: [String: String]) throws {
    self.input = input
    self.config = input.addon.config ?? [:]
    self.variables = addonVariables(for: input)
    self.environment = environment
    _ = try first()
    _ = try bool("includePlaintext", defaultValue: false)
    _ = try bool("includeBodyHtml", defaultValue: false)
    _ = try bool("includeBodyFiles", defaultValue: false)
    _ = try bool("includeAttachments", defaultValue: false)
  }

  func graphQLQuery() throws -> String {
    let noteFields = noteSelectionFields()
    return """
    query RielaAppleNotesList {
      noteAccounts {
        id
        name
        isDefault
      }
      noteFolders {
        id
        accountId
        name
        parentFolderId
        noteCount
      }
      notes(input: {\(try notesInputLiteral())}) {
        totalCount
        pageInfo {
          hasNextPage
          endCursor
        }
        edges {
          cursor
          node {
    \(noteFields)
          }
        }
      }
    }
    """
  }

  func resolvedBinary() throws -> AppleGatewayResolvedBinary {
    if let configured = configuredBinaryPath() {
      guard let path = resolveExecutable(configured, searchPath: executableSearchPath(environment: environment)) else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) config.binaryPath is not executable: \(configured)")
      }
      return AppleGatewayResolvedBinary(path: path, source: .config)
    }
    if let envPath = environmentValue(Self.executableEnvironmentName, environment: environment) {
      guard let path = resolveExecutable(envPath, searchPath: executableSearchPath(environment: environment)) else {
        throw AdapterExecutionError(.policyBlocked, "\(Self.executableEnvironmentName) is not executable: \(envPath)")
      }
      return AppleGatewayResolvedBinary(path: path, source: .environment)
    }
    guard let path = resolveExecutable(Self.executableName, searchPath: executableSearchPath(environment: environment)) else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(input.addon.name) requires apple-gateway; set config.binaryPath, \(Self.executableEnvironmentName), or PATH"
      )
    }
    return AppleGatewayResolvedBinary(path: path, source: .path)
  }

  private func configuredBinaryPath() -> String? {
    guard let configured = nonEmptyString(config["binaryPath"]) else {
      return nil
    }
    let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func notesInputLiteral() throws -> String {
    var fields = ["first: \(try first())"]
    appendStringField("accountId", to: &fields)
    appendStringField("folderId", to: &fields)
    appendStringField("query", to: &fields)
    appendStringField("modifiedAfter", to: &fields)
    appendStringField("modifiedBefore", to: &fields)
    appendStringField("after", to: &fields)
    return fields.joined(separator: ", ")
  }

  private func appendStringField(_ key: String, to fields: inout [String]) {
    guard let value = string(key) else {
      return
    }
    fields.append("\(key): \(appleGatewayGraphQLString(value))")
  }

  private func noteSelectionFields() -> String {
    var fields = [
      "            id",
      "            accountId",
      "            folderId",
      "            name",
      "            snippet",
      "            isPasswordProtected",
      "            isShared",
      "            creationDate",
      "            modificationDate"
    ]
    if (try? bool("includePlaintext", defaultValue: false)) == true {
      fields.append("            plaintext")
    }
    if (try? bool("includeBodyHtml", defaultValue: false)) == true {
      fields.append("            bodyHtml")
    }
    if (try? bool("includeBodyFiles", defaultValue: false)) == true {
      fields.append("            bodyFile {")
      fields.append("              downloadKey")
      fields.append("              kind")
      fields.append("              byteSize")
      fields.append("            }")
    }
    if (try? bool("includeAttachments", defaultValue: false)) == true {
      fields.append("            attachments {")
      fields.append("              id")
      fields.append("              name")
      fields.append("              contentIdentifier")
      fields.append("              downloadKey")
      fields.append("            }")
    }
    return fields.joined(separator: "\n")
  }

  private func string(_ key: String) -> String? {
    if let template = nonEmptyString(config[key]) {
      let rendered = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
      return rendered.isEmpty ? nil : rendered
    }
    guard let value = nonEmptyString(variables[key])?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return nil
    }
    return value.isEmpty ? nil : value
  }

  private func first() throws -> Int {
    let raw = intValue(config["first"]) ?? intValue(variables["first"]) ?? Self.defaultFirst
    guard raw > 0 && raw <= Self.maxFirst else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) first must be between 1 and \(Self.maxFirst)")
    }
    return raw
  }

  private func bool(_ key: String, defaultValue: Bool) throws -> Bool {
    if let value = boolValue(config[key]) ?? boolValue(variables[key]) {
      return value
    }
    guard config[key] != nil || variables[key] != nil else {
      return defaultValue
    }
    throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be a boolean")
  }
}

private struct AppleGatewayProcessRunner {
  private static let childEnvironmentAllowlist = [
    "HOME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LOGNAME",
    "PATH",
    "TMPDIR",
    "USER",
    "__CF_USER_TEXT_ENCODING"
  ]

  var runtimeEnvironment: [String: String]

  func run(executablePath: String, arguments: [String], deadline: Date?) throws -> AppleGatewayProcessOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = sanitizedChildEnvironment()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    let termination = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
      termination.signal()
    }
    do {
      try process.run()
    } catch {
      throw AdapterExecutionError(.providerError, "apple-gateway failed to start: \(error.localizedDescription)")
    }
    let stdoutDrain = AppleGatewayPipeDrain(
      handle: outputPipe.fileHandleForReading,
      label: "riela.apple-gateway.stdout"
    )
    let stderrDrain = AppleGatewayPipeDrain(
      handle: errorPipe.fileHandleForReading,
      label: "riela.apple-gateway.stderr"
    )
    if !waitForAppleGatewayProcess(process, termination: termination, until: deadline) {
      terminateAppleGatewayProcess(process, termination: termination)
      _ = stdoutDrain.waitForData()
      _ = stderrDrain.waitForData()
      throw AdapterExecutionError(.timeout, "apple-gateway exceeded deadline and was terminated")
    }
    process.terminationHandler = nil
    let stdout = String(data: stdoutDrain.waitForData(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrDrain.waitForData(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      let detail = appleGatewayCompactText(stderr.isEmpty ? stdout : stderr)
      throw AdapterExecutionError(.providerError, "apple-gateway failed with exit code \(process.terminationStatus): \(detail)")
    }
    return AppleGatewayProcessOutput(stdout: stdout, stderr: stderr)
  }

  private func sanitizedChildEnvironment() -> [String: String] {
    var childEnvironment: [String: String] = [:]
    for name in Self.childEnvironmentAllowlist {
      guard let value = runtimeEnvironment[name], !value.isEmpty else {
        continue
      }
      childEnvironment[name] = value
    }
    return childEnvironment
  }
}

private func waitForAppleGatewayProcess(
  _ process: Process,
  termination: DispatchSemaphore,
  until deadline: Date?
) -> Bool {
  guard process.isRunning else {
    return true
  }
  guard let deadline else {
    termination.wait()
    return true
  }
  let remaining = deadline.timeIntervalSinceNow
  guard remaining > 0 else {
    return false
  }
  return termination.wait(timeout: .now() + remaining) == .success
}

private func terminateAppleGatewayProcess(_ process: Process, termination: DispatchSemaphore) {
  if process.isRunning {
    process.terminate()
  }
  guard termination.wait(timeout: .now() + 1) == .timedOut else {
    return
  }
  #if canImport(Darwin) || canImport(Glibc)
  if process.isRunning {
    _ = kill(process.processIdentifier, SIGKILL)
  }
  #endif
  termination.wait()
}

private final class AppleGatewayPipeDrain: @unchecked Sendable {
  private let group = DispatchGroup()
  private let lock = NSLock()
  private var data = Data()

  init(handle: FileHandle, label: String) {
    group.enter()
    DispatchQueue(label: label).async {
      let drained = handle.readDataToEndOfFile()
      self.lock.lock()
      self.data = drained
      self.lock.unlock()
      self.group.leave()
    }
  }

  func waitForData() -> Data {
    group.wait()
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}

private struct AppleGatewayProcessOutput {
  var stdout: String
  var stderr: String
}

private struct AppleGatewayGraphQLEnvelope {
  var data: JSONObject
  var errors: [String]
  var requestId: String?

  init(stdout: String, addonName: String) throws {
    guard let bytes = stdout.data(using: .utf8) else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) stdout was not UTF-8")
    }
    let decoded: JSONValue
    do {
      decoded = try JSONDecoder().decode(JSONValue.self, from: bytes)
    } catch {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) stdout was not valid JSON: \(error.localizedDescription)")
    }
    guard case let .object(envelope) = decoded else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) stdout must be a GraphQL JSON object")
    }
    self.errors = appleGatewayErrors(envelope["errors"])
    self.requestId = objectValue(envelope["extensions"]).flatMap { nonEmptyString($0["requestId"]) }
    if !errors.isEmpty {
      self.data = [:]
      return
    }
    guard case let .object(data)? = envelope["data"] else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) GraphQL data is missing")
    }
    self.data = data
  }
}

private struct AppleGatewayNotesPayload {
  var accounts: [JSONValue]
  var folders: [JSONValue]
  var notes: [JSONObject]
  var pageInfo: JSONObject
  var totalCount: JSONValue

  init(data: JSONObject, addonName: String) throws {
    self.accounts = try appleGatewayRequiredArray(
      data["noteAccounts"],
      field: "\(addonName) GraphQL data.noteAccounts"
    )
    self.folders = try appleGatewayRequiredArray(
      data["noteFolders"],
      field: "\(addonName) GraphQL data.noteFolders"
    )
    let notesConnection = try appleGatewayRequiredObject(
      data["notes"],
      field: "\(addonName) GraphQL data.notes"
    )
    let edges = try appleGatewayRequiredArray(
      notesConnection["edges"],
      field: "\(addonName) GraphQL data.notes.edges"
    )
    self.notes = try edges.enumerated().map { index, edge in
      try appleGatewayNote(fromEdge: edge, index: index, addonName: addonName)
    }
    self.pageInfo = try appleGatewayRequiredObject(
      notesConnection["pageInfo"],
      field: "\(addonName) GraphQL data.notes.pageInfo"
    )
    self.totalCount = try appleGatewayRequiredNumber(
      notesConnection["totalCount"],
      field: "\(addonName) GraphQL data.notes.totalCount"
    )
  }
}

private struct AppleGatewayResolvedBinary {
  var path: String
  var source: AppleGatewayBinarySource
}

private enum AppleGatewayBinarySource: String {
  case config
  case environment
  case path
}

private func appleGatewayNote(fromEdge value: JSONValue, index: Int, addonName: String) throws -> JSONObject {
  guard case let .object(edge) = value else {
    throw AdapterExecutionError(
      .invalidOutput,
      "\(addonName) GraphQL data.notes.edges[\(index)] must be an object"
    )
  }
  guard case var .object(node)? = edge["node"] else {
    throw AdapterExecutionError(
      .invalidOutput,
      "\(addonName) GraphQL data.notes.edges[\(index)].node must be an object"
    )
  }
  if let cursor = nonEmptyString(edge["cursor"]) {
    node["cursor"] = .string(cursor)
  }
  return node
}

private func appleGatewayRequiredArray(_ value: JSONValue?, field: String) throws -> [JSONValue] {
  guard case let .array(values)? = value else {
    throw AdapterExecutionError(.invalidOutput, "\(field) must be an array")
  }
  return values
}

private func appleGatewayRequiredObject(_ value: JSONValue?, field: String) throws -> JSONObject {
  guard case let .object(object)? = value else {
    throw AdapterExecutionError(.invalidOutput, "\(field) must be an object")
  }
  return object
}

private func appleGatewayRequiredNumber(_ value: JSONValue?, field: String) throws -> JSONValue {
  guard let value, value.asDouble != nil else {
    throw AdapterExecutionError(.invalidOutput, "\(field) must be numeric")
  }
  return value
}

private func appleGatewayArray(_ value: JSONValue?) -> [JSONValue] {
  guard case let .array(values)? = value else {
    return []
  }
  return values
}

private func appleGatewayErrors(_ value: JSONValue?) -> [String] {
  appleGatewayArray(value).map { error in
    if case let .object(object) = error,
      let message = nonEmptyString(object["message"]) {
      return message
    }
    return error.compactJSONStringOrEmpty()
  }.filter { !$0.isEmpty }
}

private func appleGatewayGraphQLString(_ value: String) -> String {
  let data = (try? JSONEncoder().encode(value)) ?? Data("\"\(value)\"".utf8)
  return String(data: data, encoding: .utf8) ?? "\"\""
}

private func appleGatewayCompactText(_ value: String, maxLength: Int = 600) -> String {
  let compact = value
    .split(whereSeparator: \.isNewline)
    .joined(separator: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard compact.count > maxLength else {
    return compact
  }
  let endIndex = compact.index(compact.startIndex, offsetBy: maxLength)
  return String(compact[..<endIndex]) + "..."
}
