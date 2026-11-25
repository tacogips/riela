import Foundation
import RielaCore

struct AskToolServerProtocol {
  let executor: AskToolExecutor
  let conversationId: String
  let turnId: String

  func response(to line: String) async throws -> JSONObject? {
    guard let request = try? JSONDecoder().decode(JSONObject.self, from: Data(line.utf8)),
          request["jsonrpc"] == .string("2.0"), case let .string(method)? = request["method"],
          !method.isEmpty, Self.validId(request["id"]) else {
      return Self.invalidRequest()
    }
    // MCP notifications have no response, and tool calls require a request ID.
    guard let id = request["id"] else { return nil }
    let result: JSONObject
    switch method {
    case "initialize":
      guard case let .object(params)? = request["params"],
            case let .string(version)? = params["protocolVersion"], !version.isEmpty else {
        return Self.invalidRequest(id: id)
      }
      result = [
        "protocolVersion": .string(version),
        "capabilities": .object(["tools": .object([:])]),
        "serverInfo": .object(["name": .string("riela-ask"), "version": .string(rielaSwiftMigrationVersion)])
      ]
    case "tools/list":
      guard case .object = request["params"] ?? .object([:]) else { return Self.invalidRequest(id: id) }
      result = ["tools": .array(AskToolSet.all.map(Self.describe))]
    case "tools/call":
      guard case let .object(params)? = request["params"], case let .string(name)? = params["name"] else {
        return Self.invalidRequest(id: id)
      }
      guard case let .object(arguments) = params["arguments"] ?? .object([:]) else {
        return Self.invalidRequest(id: id)
      }
      result = try await call(name: name, arguments: arguments)
    default:
      return Self.error(id: id, code: -32601, message: "Method not found")
    }
    return ["jsonrpc": .string("2.0"), "id": id, "result": .object(result)]
  }

  private func call(name: String, arguments: JSONObject) async throws -> JSONObject {
    var result = await executor.execute(
      conversationId: conversationId, turnId: turnId, toolCallId: "mcp-\(UUID().uuidString)",
      name: name, arguments: arguments
    )
    do {
      try executor.store.addAskReferences(conversationId: conversationId, turnId: turnId, refs: result.refs)
    } catch {
      result = AskToolResult(ok: false, error: AskToolFailure(code: "tool_failed", message: "Ask references could not be saved"))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let text = try String(data: encoder.encode(result), encoding: .utf8) else {
      throw AskError(code: "tool_failed", message: "Ask result could not be encoded as UTF-8")
    }
    return ["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(!result.ok)]
  }

  private static func describe(_ tool: AskToolDescriptor) -> JSONValue {
    var properties: JSONObject = [:]
    for argument in tool.arguments {
      var schema: JSONObject = ["type": .string(argument.type.rawValue)]
      schema["minimum"] = argument.minimum.map { .integer(Int64($0)) }
      schema["maximum"] = argument.maximum.map { .integer(Int64($0)) }
      schema["default"] = argument.defaultValue
      properties[argument.name] = .object(schema)
    }
    let schema: JSONObject = [
      "type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false),
      "required": .array(tool.arguments.filter(\.required).map { .string($0.name) })
    ]
    return .object(["name": .string(tool.name), "inputSchema": .object(schema)])
  }

  private static func validId(_ id: JSONValue?) -> Bool {
    switch id {
    case nil, .null?, .string?, .integer?, .number?: return true
    default: return false
    }
  }

  private static func invalidRequest(id: JSONValue = .null) -> JSONObject {
    error(id: id, code: -32600, message: "Invalid Request")
  }

  private static func error(id: JSONValue, code: Int64, message: String) -> JSONObject {
    [
      "jsonrpc": .string("2.0"), "id": id,
      "error": .object(["code": .integer(code), "message": .string(message)])
    ]
  }
}
