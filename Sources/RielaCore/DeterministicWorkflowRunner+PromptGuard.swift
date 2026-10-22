import Crypto
#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

let agentPromptDefaultMaxBytes = 400_000
let agentPromptSpillMinBytes = 4_096
let agentPromptSpillPreviewCharacters = 256

struct AgentPromptGuardOutcome: Sendable {
  var prompts: ComposedAdapterPrompts
  var evidence: JSONObject?
  var rejection: AdapterExecutionError?
}

private struct AgentPromptSpillCandidate {
  var pointer: [String]
  var value: JSONValue
  var bytes: Int
}

extension DeterministicWorkflowRunner {
  func effectiveAgentPromptMaxBytes(workflow: WorkflowDefinition, payload: AgentNodePayload) -> Int {
    payload.promptMaxBytes ?? workflow.defaults.agentPromptMaxBytes ?? agentPromptDefaultMaxBytes
  }

  func guardAgentPrompt(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload,
    request: DeterministicWorkflowRunRequest,
    session: WorkflowSession,
    resolvedInputPayload: JSONObject,
    prompts: ComposedAdapterPrompts
  ) throws -> AgentPromptGuardOutcome {
    let budget = effectiveAgentPromptMaxBytes(workflow: workflow, payload: payload)
    let measured = promptSize(prompts)
    guard measured > budget else {
      return AgentPromptGuardOutcome(prompts: prompts, evidence: nil, rejection: nil)
    }

    let initialSize = measured
    var currentPrompts = prompts
    var compactedRequestVariables = request.variables
    var compactedResolvedInputPayload = resolvedInputPayload
    var spills: [JSONValue] = []
    var rejection: AdapterExecutionError?
    let root = resolvedBackendWorkingDirectory(
      backend: payload.executionBackend,
      configuredWorkingDirectory: payload.workingDirectory,
      workspaceRoot: fanoutWorkspaceRoot
    ) ?? fanoutWorkspaceRoot?.standardizedFileURL.path ?? FileManager.default.currentDirectoryPath
    let spillRoot = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("tmp/riela-prompt-spill", isDirectory: true)
      .appendingPathComponent(session.sessionId, isDirectory: true)
      .appendingPathComponent(step.id, isDirectory: true)

    while promptSize(currentPrompts) > budget {
      let currentSize = promptSize(currentPrompts)
      let view = runtimeVariableView(
        requestVariables: compactedRequestVariables,
        resolvedInputPayload: compactedResolvedInputPayload
      )
      let candidates = promptSpillCandidates(view)
      guard step.placement == nil, let candidate = selectPromptSpillCandidate(candidates, excess: currentSize - budget) else {
        rejection = AdapterExecutionError(
          .invalidInput,
          "agent prompt exceeds budget: measured=\(currentSize) budget=\(budget) after \(spills.count) spill(s)",
          failureKind: .promptTooLarge
        )
        break
      }
      do {
        let bytes = Data(try candidate.value.compactJSONString().utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fileURL = spillRoot.appendingPathComponent("\(digest).json")
        try writePromptSpill(bytes, to: fileURL)
        let pointer = "/" + candidate.pointer.map(escapeJSONPointer).joined(separator: "/")
        let preview = String(try candidate.value.compactJSONString().prefix(agentPromptSpillPreviewCharacters))
        let stub: JSONValue = .object([
          "$rielaSpilled": .bool(true),
          "pointer": .string(pointer),
          "path": .string(fileURL.standardizedFileURL.path),
          "bytes": .integer(Int64(bytes.count)),
          "sha256": .string(digest),
          "preview": .string(preview)
        ])
        replacePromptSpill(
          candidate: candidate,
          stub: stub,
          requestVariables: &compactedRequestVariables,
          resolvedInputPayload: &compactedResolvedInputPayload
        )
        spills.append(.object([
          "pointer": .string(pointer),
          "path": .string(fileURL.standardizedFileURL.path),
          "bytes": .integer(Int64(bytes.count)),
          "sha256": .string(digest)
        ]))
        let variables = promptVariables(
          workflow: workflow,
          step: step,
          payload: payload,
          requestVariables: compactedRequestVariables,
          resolvedInputPayload: compactedResolvedInputPayload
        )
        currentPrompts = try composedPromptsWithFinalizationEvidence(
          workflow: workflow,
          step: step,
          payload: payload,
          variables: variables,
          session: session
        )
      } catch let error as AdapterExecutionError {
        rejection = error
        break
      } catch {
        rejection = AdapterExecutionError(.providerError, "prompt spill failed: \(error)")
        break
      }
    }

    let finalSize = promptSize(currentPrompts)
    let isOverBudget = rejection != nil || finalSize > budget
    if isOverBudget, rejection == nil {
      rejection = AdapterExecutionError(
        .invalidInput,
        "agent prompt exceeds budget: measured=\(finalSize) budget=\(budget) after \(spills.count) spill(s)",
        failureKind: .promptTooLarge
      )
    }
    let evidence: JSONObject = [
      "budgetBytes": .integer(Int64(budget)),
      "measuredBytes": .integer(Int64(initialSize)),
      "finalBytes": .integer(Int64(finalSize)),
      "outcome": .string(isOverBudget ? "overBudget" : "spilled"),
      "spills": .array(spills)
    ]
    return AgentPromptGuardOutcome(prompts: currentPrompts, evidence: evidence, rejection: rejection)
  }
}

private func promptSize(_ prompts: ComposedAdapterPrompts) -> Int {
  (prompts.systemPromptText ?? "").utf8.count + max(prompts.promptText.utf8.count, prompts.resumedPromptText.utf8.count)
}

private func runtimeVariableView(requestVariables: JSONObject, resolvedInputPayload: JSONObject) -> JSONObject {
  var values = requestVariables
  for (key, value) in resolvedInputPayload { values[key] = value }
  return deduplicatedRuntimeVariablesView(values)
}

private func promptSpillCandidates(_ view: JSONObject) -> [AgentPromptSpillCandidate] {
  var result: [AgentPromptSpillCandidate] = []
  func visit(_ value: JSONValue, path: [String]) {
    if case let .object(object) = value, object["$rielaSpilled"] == .bool(true) { return }
    if !path.isEmpty, let data = try? value.compactJSONString().data(using: .utf8), data.count >= agentPromptSpillMinBytes {
      result.append(AgentPromptSpillCandidate(pointer: path, value: value, bytes: data.count))
    }
    switch value {
    case let .object(object):
      for key in object.keys.sorted() where key != "$rielaElidedKeys" && key != "$rielaSameAs" {
        if let child = object[key] { visit(child, path: path + [key]) }
      }
    case let .array(values):
      for (index, child) in values.enumerated() { visit(child, path: path + [String(index)]) }
    case .null, .bool, .integer, .number, .string:
      break
    }
  }
  for key in view.keys.sorted() { if let value = view[key] { visit(value, path: [key]) } }
  return result
}

private func selectPromptSpillCandidate(_ candidates: [AgentPromptSpillCandidate], excess: Int) -> AgentPromptSpillCandidate? {
  let pointer: (AgentPromptSpillCandidate) -> String = { $0.pointer.map(escapeJSONPointer).joined(separator: "/") }
  if let covering = candidates.filter({ $0.bytes >= excess }).sorted(by: {
    $0.bytes == $1.bytes ? pointer($0) < pointer($1) : $0.bytes < $1.bytes
  }).first { return covering }
  return candidates.sorted(by: {
    $0.bytes == $1.bytes ? pointer($0) < pointer($1) : $0.bytes > $1.bytes
  }).first
}

private func replacePromptSpill(
  candidate: AgentPromptSpillCandidate,
  stub: JSONValue,
  requestVariables: inout JSONObject,
  resolvedInputPayload: inout JSONObject
) {
  guard let root = candidate.pointer.first else { return }
  let relative = Array(candidate.pointer.dropFirst())
  if root != "_rielaInput" {
    if resolvedInputPayload[root] != nil {
      if let value = resolvedInputPayload[root] { resolvedInputPayload[root] = replacing(value, path: relative, with: stub) }
      replaceMatchingMessagePayloads(root: root, path: relative, original: candidate.value, stub: stub, payload: &resolvedInputPayload)
    } else if let value = requestVariables[root] {
      requestVariables[root] = replacing(value, path: relative, with: stub)
    }
    return
  }
  if let value = resolvedInputPayload[root] {
    var compactedInput = replacing(value, path: relative, with: stub)
    if relative.count >= 4,
       relative[0] == "messages",
       relative[2] == "payload",
       let messageIndex = Int(relative[1]),
       case let .object(input) = value,
       case let .array(messages)? = input["messages"],
       messageIndex == messages.count - 1 {
      let latestPath = ["latest", "payload"] + relative.dropFirst(3)
      compactedInput = replacing(compactedInput, path: latestPath, with: stub)
    }
    resolvedInputPayload[root] = compactedInput
  }
}

private func replaceMatchingMessagePayloads(root: String, path: [String], original: JSONValue, stub: JSONValue, payload: inout JSONObject) {
  guard case var .object(input)? = payload["_rielaInput"] else { return }
  if case var .array(messages)? = input["messages"] {
    for index in messages.indices {
      guard case var .object(message) = messages[index], case var .object(messagePayload)? = message["payload"],
            let value = messagePayload[root], let target = jsonValue(at: value, path: path),
            (try? target.compactJSONString()) == (try? original.compactJSONString()) else { continue }
      messagePayload[root] = replacing(value, path: path, with: stub)
      message["payload"] = .object(messagePayload)
      messages[index] = .object(message)
    }
    input["messages"] = .array(messages)
  }
  if case var .object(latest)? = input["latest"], case var .object(latestPayload)? = latest["payload"],
     let value = latestPayload[root], let target = jsonValue(at: value, path: path),
     (try? target.compactJSONString()) == (try? original.compactJSONString()) {
    latestPayload[root] = replacing(value, path: path, with: stub)
    latest["payload"] = .object(latestPayload)
    input["latest"] = .object(latest)
  }
  payload["_rielaInput"] = .object(input)
}

private func replacing(_ value: JSONValue, path: [String], with replacement: JSONValue) -> JSONValue {
  guard let key = path.first else { return replacement }
  let remaining = Array(path.dropFirst())
  switch value {
  case var .object(object):
    if let child = object[key] { object[key] = replacing(child, path: remaining, with: replacement) }
    return .object(object)
  case var .array(array):
    guard let index = Int(key), array.indices.contains(index) else { return value }
    array[index] = replacing(array[index], path: remaining, with: replacement)
    return .array(array)
  case .null, .bool, .integer, .number, .string:
    return value
  }
}

private func jsonValue(at value: JSONValue, path: [String]) -> JSONValue? {
  guard let key = path.first else { return value }
  let remaining = Array(path.dropFirst())
  switch value {
  case let .object(object): return object[key].flatMap { jsonValue(at: $0, path: remaining) }
  case let .array(array): return Int(key).flatMap { array.indices.contains($0) ? jsonValue(at: array[$0], path: remaining) : nil }
  case .null, .bool, .integer, .number, .string: return nil
  }
}

private func escapeJSONPointer(_ component: String) -> String {
  component.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}

private func writePromptSpill(_ data: Data, to url: URL) throws {
  let manager = FileManager.default
  let stepDirectory = url.deletingLastPathComponent()
  let sessionDirectory = stepDirectory.deletingLastPathComponent()
  let spillDirectory = sessionDirectory.deletingLastPathComponent()
  let temporaryDirectory = spillDirectory.deletingLastPathComponent()
  try manager.createDirectory(
    at: temporaryDirectory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  for directory in [spillDirectory, sessionDirectory, stepDirectory] {
    try ensurePrivatePromptDirectory(directory)
  }
  let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
  if descriptor < 0 {
    if errno == EEXIST {
      let existing = try Data(contentsOf: url)
      guard existing == data else {
        throw AdapterExecutionError(.policyBlocked, "prompt spill file exists with different content: \(url.path)")
      }
      return
    }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  defer { _ = close(descriptor) }
  try data.withUnsafeBytes { bytes in
    guard let base = bytes.baseAddress else { return }
    var written = 0
    while written < bytes.count {
      let count = write(descriptor, base.advanced(by: written), bytes.count - written)
      guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      written += count
    }
  }
}

private func ensurePrivatePromptDirectory(_ url: URL) throws {
  guard mkdir(url.path, mode_t(0o700)) == 0 || errno == EEXIST else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  var metadata = stat()
  guard lstat(url.path, &metadata) == 0,
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? ENOTDIR : errno))
  }
  guard chmod(url.path, mode_t(0o700)) == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
}
