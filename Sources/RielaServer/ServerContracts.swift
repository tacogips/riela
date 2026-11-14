import Foundation
import RielaCore
import RielaGraphQL
import RielaObservability

public struct ServerRequestEnvelope: Equatable, Sendable {
  public var method: String
  public var path: String
  public var headers: [String: String]
  public var body: Data?

  public init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) {
    self.method = method
    self.path = path
    self.headers = headers
    self.body = body
  }
}

public struct ServerResponseDescriptor: Equatable, Sendable {
  public var status: Int
  public var contentType: String
  public var body: JSONObject

  public init(status: Int, contentType: String = "application/json", body: JSONObject) {
    self.status = status
    self.contentType = contentType
    self.body = body
  }
}

public struct ServerRequestContext: Equatable, Sendable {
  public var serviceName: String
  public var bearerToken: String?
  public var managerSessionId: String?
  public var inheritedEnvironment: [String: String]

  public init(
    serviceName: String = "riela",
    bearerToken: String? = nil,
    managerSessionId: String? = nil,
    inheritedEnvironment: [String: String] = [:]
  ) {
    self.serviceName = serviceName
    self.bearerToken = bearerToken
    self.managerSessionId = managerSessionId
    self.inheritedEnvironment = inheritedEnvironment
  }

  public var sanitizedEnvironment: [String: String] {
    let strippedKeys: Set<String> = [
      "RIELA_MANAGER_SESSION_ID",
      "RIELA_WORKFLOW_ID",
      "RIELA_WORKFLOW_EXECUTION_ID"
    ]
    return inheritedEnvironment.filter { key, _ in
      !key.hasPrefix("RIELA_MANAGER_") && !strippedKeys.contains(key)
    }
  }
}

public struct GraphQLServerEnvelope: Equatable, Sendable {
  public var query: String
  public var variables: JSONObject
  public var operationName: String?

  public init(query: String, variables: JSONObject = [:], operationName: String? = nil) {
    self.query = query
    self.variables = variables
    self.operationName = operationName
  }
}

public protocol ServerRouteHandling: Sendable {
  func route(_ request: ServerRequestEnvelope, context: ServerRequestContext) async -> ServerResponseDescriptor
}

public struct DeterministicServerRouteHandler: ServerRouteHandling {
  public var telemetry: any RielaTelemetry

  public init(telemetry: any RielaTelemetry = NoOpRielaTelemetry()) {
    self.telemetry = telemetry
  }

  public func route(_ request: ServerRequestEnvelope, context: ServerRequestContext) async -> ServerResponseDescriptor {
    let startedAt = Date()
    let normalizedMethod = request.method.uppercased()
    let contextWithHeaders = context.withHeaders(from: request.headers)
    let response: ServerResponseDescriptor
    switch (normalizedMethod, request.path) {
    case ("GET", "/"), ("GET", "/overview"):
      response = .init(status: 200, body: [
        "service": .string(context.serviceName),
        "route": .string(request.path),
        "readOnly": .bool(true)
      ])
    case ("GET", "/healthz"):
      response = .init(status: 200, body: [
        "service": .string(context.serviceName),
        "status": .string("ok")
      ])
    case ("POST", "/graphql"):
      response = routeGraphQL(request, context: contextWithHeaders)
    case (_, "/"), (_, "/overview"), (_, "/healthz"), (_, "/graphql"):
      response = .init(status: 405, body: [
        "error": .string("unsupported method"),
        "method": .string(normalizedMethod),
        "path": .string(request.path)
      ])
    default:
      response = .init(status: 404, body: [
        "error": .string("unknown path"),
        "path": .string(request.path)
      ])
    }
    await recordServerTelemetry(
      request: request,
      normalizedMethod: normalizedMethod,
      response: response,
      startedAt: startedAt
    )
    return response
  }

  public func parseGraphQLEnvelope(_ request: ServerRequestEnvelope) -> GraphQLEnvelopeParseResult {
    guard let body = request.body, !body.isEmpty else {
      return .failure("graphql request body is required")
    }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: body), case let .object(object) = value else {
      return .failure("graphql request body must be a JSON object")
    }
    guard case let .string(rawQuery)? = object["query"] else {
      return .failure("graphql request body must include a non-empty query string")
    }
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return .failure("graphql request body must include a non-empty query string")
    }
    let variables: JSONObject
    if let rawVariables = object["variables"] {
      if case .null = rawVariables {
        variables = [:]
      } else if case let .object(variableObject) = rawVariables {
        variables = variableObject
      } else {
        return .failure("graphql variables must be an object when present")
      }
    } else {
      variables = [:]
    }
    let operationName: String?
    if let rawOperationName = object["operationName"] {
      switch rawOperationName {
      case .null:
        operationName = nil
      case let .string(value):
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        operationName = trimmed.isEmpty ? nil : trimmed
      default:
        return .failure("graphql operationName must be a string when present")
      }
    } else {
      operationName = nil
    }
    if let operationName, !graphqlNamedOperationNames(in: query).contains(operationName) {
      return .failure("graphql operationName '\(operationName)' was not found in query")
    }
    return .success(.init(query: query, variables: variables, operationName: operationName))
  }

  private func routeGraphQL(_ request: ServerRequestEnvelope, context: ServerRequestContext) -> ServerResponseDescriptor {
    switch parseGraphQLEnvelope(request) {
    case let .failure(message):
      return .init(status: 400, body: [
        "error": .string(message),
        "graphql": .object([
          "errors": .array([.object(["message": .string(message)])])
        ])
      ])
    case let .success(envelope):
      return .init(status: 200, body: [
        "graphql": .object([
          "delegated": .bool(true),
          "query": .string(envelope.query),
          "variables": .object(envelope.variables),
          "operationName": envelope.operationName.map(JSONValue.string) ?? .null,
          "schema": .string(GraphQLContractProjector.schemaContract)
        ]),
        "context": .object([
          "bearerTokenPresent": .bool(context.bearerToken != nil),
          "managerSessionId": context.managerSessionId.map(JSONValue.string) ?? .null,
          "sanitizedEnvironmentKeys": .array(context.sanitizedEnvironment.keys.sorted().map(JSONValue.string))
        ])
      ])
    }
  }
}

public enum GraphQLEnvelopeParseResult: Equatable, Sendable {
  case success(GraphQLServerEnvelope)
  case failure(String)
}

private extension DeterministicServerRouteHandler {
  func recordServerTelemetry(
    request: ServerRequestEnvelope,
    normalizedMethod: String,
    response: ServerResponseDescriptor,
    startedAt: Date
  ) async {
    var attributes: [String: String] = [
      "runtime.surface": "serve",
      "http.method": normalizedMethod,
      "http.path": request.path,
      "status": String(response.status)
    ]
    if request.path == "/graphql" {
      attributes["graphql.operation.type"] = graphqlOperationType(request)
      if case let .success(envelope) = parseGraphQLEnvelope(request),
        let operationName = envelope.operationName {
        attributes["graphql.operation.name"] = operationName
      }
    }
    let status: RielaTelemetryStatus = (200...399).contains(response.status) ? .ok : .error
    await telemetry.recordSpan(RielaTelemetrySpan(
      name: "riela.server.request",
      status: status,
      startedAt: startedAt,
      attributes: attributes
    ))
    await telemetry.recordMetric(RielaTelemetryMetric(
      name: "riela.server.request.count",
      value: 1,
      attributes: attributes
    ))
  }

  func graphqlOperationType(_ request: ServerRequestEnvelope) -> String {
    guard case let .success(envelope) = parseGraphQLEnvelope(request) else {
      return "unknown"
    }
    guard let firstToken = graphqlTokens(in: envelope.query).first?.lowercased() else {
      return "unknown"
    }
    if firstToken == "mutation" {
      return "mutation"
    }
    if firstToken == "subscription" {
      return "subscription"
    }
    if firstToken == "query" || firstToken == "{" {
      return "query"
    }
    return "unknown"
  }

  func graphqlNamedOperationNames(in query: String) -> Set<String> {
    let tokens = graphqlTokens(in: query)
    var names = Set<String>()
    for index in tokens.indices {
      guard ["query", "mutation", "subscription"].contains(tokens[index].lowercased()) else {
        continue
      }
      let nameIndex = tokens.index(after: index)
      guard nameIndex < tokens.endIndex, isGraphQLName(tokens[nameIndex]) else {
        continue
      }
      names.insert(tokens[nameIndex])
    }
    return names
  }

  func graphqlTokens(in query: String) -> [String] {
    let scalars = Array(query.unicodeScalars)
    var index = 0
    var tokens: [String] = []
    while index < scalars.count {
      let scalar = scalars[index]
      if isGraphQLIgnored(scalar) {
        index += 1
      } else if scalar == "#" {
        skipGraphQLComment(scalars, index: &index)
      } else if scalar == "\"" {
        skipGraphQLString(scalars, index: &index)
      } else if isGraphQLNameStart(scalar) {
        tokens.append(readGraphQLName(scalars, index: &index))
      } else {
        tokens.append(String(scalar))
        index += 1
      }
    }
    return tokens
  }

  func skipGraphQLComment(_ scalars: [UnicodeScalar], index: inout Int) {
    while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" {
      index += 1
    }
  }

  func skipGraphQLString(_ scalars: [UnicodeScalar], index: inout Int) {
    if scalars[safe: index + 1] == "\"", scalars[safe: index + 2] == "\"" {
      index += 3
      while index < scalars.count {
        if scalars[safe: index] == "\"", scalars[safe: index + 1] == "\"", scalars[safe: index + 2] == "\"" {
          index += 3
          return
        }
        index += 1
      }
      return
    }
    index += 1
    while index < scalars.count {
      if scalars[index] == "\\" {
        index += 2
      } else if scalars[index] == "\"" {
        index += 1
        return
      } else {
        index += 1
      }
    }
  }

  func readGraphQLName(_ scalars: [UnicodeScalar], index: inout Int) -> String {
    let start = index
    index += 1
    while index < scalars.count, isGraphQLNameContinue(scalars[index]) {
      index += 1
    }
    return String(String.UnicodeScalarView(scalars[start..<index]))
  }

  func isGraphQLName(_ token: String) -> Bool {
    guard let first = token.unicodeScalars.first, isGraphQLNameStart(first) else {
      return false
    }
    return token.unicodeScalars.dropFirst().allSatisfy(isGraphQLNameContinue)
  }

  func isGraphQLIgnored(_ scalar: UnicodeScalar) -> Bool {
    scalar == "," || scalar.properties.isWhitespace
  }

  func isGraphQLNameStart(_ scalar: UnicodeScalar) -> Bool {
    scalar == "_" || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
  }

  func isGraphQLNameContinue(_ scalar: UnicodeScalar) -> Bool {
    isGraphQLNameStart(scalar) || (48...57).contains(scalar.value)
  }
}

private extension Collection {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

private extension ServerRequestContext {
  func withHeaders(from headers: [String: String]) -> ServerRequestContext {
    var copy = self
    var lowercased: [String: String] = [:]
    for key in headers.keys.sorted() {
      lowercased[key.lowercased()] = headers[key]
    }
    if let authorization = lowercased["authorization"], authorization.lowercased().hasPrefix("bearer ") {
      copy.bearerToken = String(authorization.dropFirst("Bearer ".count))
    }
    if let managerSessionId = lowercased["x-riela-manager-session-id"] {
      copy.managerSessionId = managerSessionId
    }
    return copy
  }
}
