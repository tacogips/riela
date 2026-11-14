import AgentGateway
import Foundation
import RielaCore

/// Lives beside the vendor process: inside guest tmpfs for ephemeral agents.
/// No schema path or file management is required in authored workflow nodes.
struct NativeStructuredOutputFile {
  let directory: URL
  var file: URL { directory.appendingPathComponent("output-schema.json") }
  var arguments: [String] { ["--output-schema", file.path] }

  init?(input: AdapterExecutionInput, vendor: GatewayVendor, arguments: [String]) throws {
    guard input.node.output?.nativeStructuredOutput == true else { return nil }
    guard vendor == .codex, input.sessionPolicy?.mode != .reuse,
          input.node.output?.jsonSchemaFrom == nil,
          let schema = input.node.output?.jsonSchema,
          DefaultWorkflowOutputValidator().validateContractSchema(schema) == nil,
          !arguments.contains(where: { $0 == "--output-schema" || $0.hasPrefix("--output-schema=") }) else {
      throw AdapterExecutionError(.invalidInput,
        "nativeStructuredOutput requires a fresh Codex turn and a resolved schema without an authored output-schema argument")
    }
    let data = try JSONEncoder().encode(schema)
    guard data.count <= 1_000_000 else {
      throw AdapterExecutionError(.invalidInput, "native structured output schema exceeds its size limit")
    }
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("riela-schema-" + UUID().uuidString)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      guard FileManager.default.createFile(atPath: file.path, contents: data,
        attributes: [.posixPermissions: 0o600]) else {
        throw AdapterExecutionError(.invalidInput, "native structured output schema could not be created")
      }
    } catch {
      remove()
      throw AdapterExecutionError(.invalidInput, "native structured output schema could not be prepared")
    }
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
