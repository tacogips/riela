import Foundation
import RielaAdapters
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let commandResultRegistration = BuiltinAddonHandlerRegistration(name: "riela/command-result", bindsCLIVariablesAsInputs: false) { resolver, input, context in
    try await resolver.executeCommandResult(input, context: context)
  }

  func executeCommandResult(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    try Task.checkCancellation()
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["executable", "arguments", "environment", "workingDirectory", "timeoutMs", "cancellationPolicy", "maximumStdoutBytes", "stdoutSchema", "context"]),
      case let .string(executable)? = config["executable"], executable.hasPrefix("/"), !executable.contains("\0"), executable.utf8.count <= 4096,
      case let .array(raw) = config["arguments"] ?? .array([]), raw.count <= 1024,
      case let .object(overlay) = config["environment"] ?? .object([:]), overlay.count <= 128,
      case let .integer(timeout) = config["timeoutMs"] ?? .integer(120_000), (1...7_200_000).contains(timeout),
      case let .integer(maximum) = config["maximumStdoutBytes"] ?? .integer(65_536), (1...1_000_000).contains(maximum),
      case let .string(policy) = config["cancellationPolicy"] ?? .string("terminate-group"), let cancellation = WorkflowProcessCancellation(rawValue: policy),
      try JSONEncoder().encode(config).count <= 1_000_000,
      try JSONEncoder().encode(config["context"] ?? .null).count <= 4096 else { throw commandResultInvalid() }
    let args = try raw.map { value -> String in
      guard case let .string(text) = value, text.utf8.count <= 32768, !text.contains("\0") else { throw commandResultInvalid() }; return text
    }
    var childEnvironment = environment
    for (key, value) in overlay {
      guard isValidEnvironmentVariableName(key), case let .string(text) = value, text.utf8.count <= 32768, !text.contains("\0") else { throw commandResultInvalid() }
      childEnvironment[key] = text
    }
    for key in ["RIELA_COMMAND_LOCKS", "RIELA_MAILBOX_DIR", "RIELA_WORKFLOW_INPUT", "RIELA_WORKFLOW_OUTPUT"] { childEnvironment.removeValue(forKey: key) }
    let directory: URL
    if let supplied = config["workingDirectory"] {
      guard case let .string(path) = supplied, !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0") else { throw commandResultInvalid() }
      directory = URL(fileURLWithPath: path, relativeTo: workingDirectory)
    } else { directory = workingDirectory }
    let schema: JSONObject?
    if let supplied = config["stdoutSchema"] {
      guard case let .object(value) = supplied, value["type"] == .string("object"),
        try JSONEncoder().encode(value).count <= 65_536, DefaultWorkflowOutputValidator().validateContractSchema(value) == nil else { throw commandResultInvalid() }
      schema = value
    } else { schema = nil }
    let deadline = min(context.deadline ?? .distantFuture, Date().addingTimeInterval(Double(timeout) / 1000))
    var payload: JSONObject
    do {
      let result = try await containerProcessRunner.run(configuration: .init(executableURL: URL(fileURLWithPath: executable), arguments: args,
        environment: childEnvironment, workingDirectoryURL: directory, inheritEnvironment: false,
        stdoutCaptureByteLimit: Int(maximum) + 1, stderrCaptureByteLimit: 0, cancellationPolicy: cancellation), stdin: "", deadline: deadline)
      try Task.checkCancellation()
      if result.stdoutInvalidUTF8 || (result.stdoutRetainedByteCount ?? result.stdout.utf8.count) > maximum {
        payload = ["status": .string("invalid_summary")]
      } else if let schema {
        guard let data = result.stdout.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          let projected = try CommandResultProjection.project(value, schema: schema), case .object = projected else {
          return commandResultOutput(input, ["status": .string("invalid_summary")], context: config["context"])
        }
        payload = ["status": .string("completed"), "exit_code": .integer(Int64(result.terminationStatus)), "stdout": .string(try projected.compactJSONString())]
      } else {
        payload = ["status": .string("completed"), "exit_code": .integer(Int64(result.terminationStatus)), "stdout": .string(result.stdout)]
      }
    } catch is CancellationError { throw CancellationError() } catch {
      try Task.checkCancellation()
      payload = ["status": .string((error as? AdapterExecutionError)?.code == .timeout ? "timed_out" : "unavailable")]
    }
    return commandResultOutput(input, payload, context: config["context"])
  }
}

private func commandResultOutput(_ input: WorkflowAddonExecutionInput, _ payload: JSONObject, context: JSONValue?) -> AdapterExecutionOutput {
  .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true,
    payload: payload.merging(["context": context ?? .null]) { _, value in value })
}

private func commandResultInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid bounded command-result configuration") }

/// Drop undeclared or invalid optional metadata before it enters runtime output.
/// Required-field failure refuses the whole projection. Never evaluate data.
enum CommandResultProjection {
  static func project(_ value: JSONValue, schema: JSONObject, depth: Int = 0) throws -> JSONValue? {
    guard depth <= 16, case let .string(type)? = schema["type"],
      ["object", "array", "string", "integer", "number", "boolean", "null"].contains(type) else { return nil }
    var selected = value
    if schema["type"] == .string("object") {
      guard case let .object(object) = value, case let .object(properties)? = schema["properties"] else { return nil }
      var result: JSONObject = [:]
      for (key, spec) in properties {
        guard let supplied = object[key], case let .object(child) = spec else { continue }
        if let found = try project(supplied, schema: child, depth: depth + 1) { result[key] = found }
      }
      selected = .object(result)
    } else if schema["type"] == .string("array") {
      guard case let .array(items) = value, items.count <= 10_000, case let .object(child)? = schema["items"] else { return nil }
      var result: [JSONValue] = []
      for item in items {
        guard let found = try project(item, schema: child, depth: depth + 1) else { return nil }; result.append(found)
      }
      selected = .array(result)
    }
    let wrapper: JSONObject = ["type": .string("object"), "properties": .object(["value": .object(schema)]),
      "required": .array([.string("value")]), "additionalProperties": .bool(false)]
    let validation = try DefaultWorkflowOutputValidator().validate(.init(source: .inlineCandidate, payload: ["value": selected], completionPassed: true), contract: .init(schema: wrapper, requiredObject: true))
    return validation.status == .accepted ? selected : nil
  }
}
