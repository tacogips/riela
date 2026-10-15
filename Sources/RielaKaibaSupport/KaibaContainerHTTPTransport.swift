import Foundation
import KaibaClient
import RielaCore

private struct KaibaContainerHTTPRequest: Codable {
  var body: Data
  var maximumResponseBytes: Int
}

private struct KaibaContainerHTTPResponse: Codable {
  var statusCode: Int
  var body: Data
}

/// The guest supplies only a GraphQL body and response bound. The captured
/// instance owns the destination and authentication; redirects remain disabled.
public struct KaibaContainerHostTransport: Sendable {
  private let endpoint: URL
  private let headers: [String: String]
  private let transport: any KaibaHTTPTransporting
  private let configuration: KaibaClientConfiguration
  private let authentication: KaibaAuthentication

  public init(
    instance: KaibaInstance,
    environment: [String: String],
    transport: any KaibaHTTPTransporting = URLSessionKaibaHTTPTransport()
  ) throws {
    let client = try KaibaClientFactory().makeClient(instance: instance, environment: environment)
    guard client.endpoint.isLoopback,
          let endpoint = URL(string: try KaibaInstanceValidation.normalizedEndpoint(instance)) else {
      throw AdapterExecutionError(.policyBlocked, "Kaiba host transport requires the captured loopback instance")
    }
    self.endpoint = endpoint
    self.configuration = client.configuration
    self.authentication = client.authentication
    self.transport = transport
    var headers = ["accept": "application/json", "content-type": "application/json"]
    if let credential = instance.authentication.credentialEnvironmentVariable,
       let value = environment[credential] { headers["authorization"] = "Bearer " + value }
    self.headers = headers
  }

  public func send(_ encodedRequest: String, deadline: Date) async throws -> String {
    let request = try JSONDecoder().decode(KaibaContainerHTTPRequest.self, from: Data(encodedRequest.utf8))
    guard request.body.count <= configuration.maximumRequestBytes,
          (1...configuration.maximumResponseBytes).contains(request.maximumResponseBytes) else {
      throw AdapterExecutionError(.policyBlocked, "Kaiba host transport byte limit exceeded")
    }
    let timeout = min(configuration.requestTimeout, deadline.timeIntervalSinceNow)
    guard timeout > 0 else { throw AdapterExecutionError(.timeout, "Kaiba host request expired") }
    let response = try await transport.send(.init(url: endpoint, headers: headers, body: request.body, timeout: timeout),
      maximumResponseBytes: request.maximumResponseBytes)
    guard response.body.count <= request.maximumResponseBytes else {
      throw AdapterExecutionError(.invalidOutput, "Kaiba host response exceeds its byte limit")
    }
    let body = try safeResponseBody(response.body)
    guard body.count <= request.maximumResponseBytes else {
      throw AdapterExecutionError(.invalidOutput, "Kaiba host response exceeds its byte limit")
    }
    let data = try JSONEncoder().encode(KaibaContainerHTTPResponse(statusCode: response.statusCode, body: body))
    guard let result = String(data: data, encoding: .utf8) else { throw AdapterExecutionError(.invalidOutput, "invalid Kaiba bridge encoding") }
    return result
  }

  private func safeResponseBody(_ data: Data) throws -> Data {
    // Non-JSON error bodies are unnecessary to the SDK, which diagnoses them
    // from the HTTP status. Never expose raw server diagnostics to the guest.
    guard case var .object(value)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return Data() }
    guard let errors = value["errors"] else { return data }
    value["errors"] = redactedDiagnostic(errors)
    return try JSONEncoder().encode(JSONValue.object(value))
  }

  private func redactedDiagnostic(_ value: JSONValue) -> JSONValue {
    switch value {
    case let .string(text): .string(authentication.redactedDiagnostic(text))
    case let .array(values): .array(values.map(redactedDiagnostic))
    case let .object(values): .object(values.mapValues(redactedDiagnostic))
    default: value
    }
  }
}

public enum KaibaContainerGuestTransport {
  public typealias BridgeCall = @Sendable (String, Date) async throws -> String

  public static func clientFactory(call: @escaping BridgeCall) -> KaibaClientFactory {
    .init(transportFactory: { Transport(call: call) })
  }

  private struct Transport: KaibaHTTPTransporting {
    var call: BridgeCall

    func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
      let data = try JSONEncoder().encode(KaibaContainerHTTPRequest(body: request.body, maximumResponseBytes: maximumResponseBytes))
      guard let encoded = String(data: data, encoding: .utf8) else { throw KaibaClientError.invalidRequest("bridge encoding failed") }
      let reply = try await call(encoded, Date().addingTimeInterval(request.timeout))
      let response = try JSONDecoder().decode(KaibaContainerHTTPResponse.self, from: Data(reply.utf8))
      guard response.body.count <= maximumResponseBytes, (100...599).contains(response.statusCode) else {
        throw KaibaClientError.invalidResponse(status: response.statusCode, byteCount: response.body.count)
      }
      return .init(statusCode: response.statusCode, body: response.body)
    }
  }
}
