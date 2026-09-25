import Foundation
import RielaCore

/// Checks the operator credential before the composite executor removes transport credentials.
public struct WorkflowExecutionAuthorizationWrapper: GraphQLDocumentExecuting {
  public var expectedBearer: String?
  public var next: any GraphQLDocumentExecuting

  public init(expectedBearer: String?, next: any GraphQLDocumentExecuting) {
    self.expectedBearer = expectedBearer
    self.next = next
  }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    let operations: [ParsedGraphQLOperation]
    do {
      operations = try parseGraphQLOperations(
        in: request.query,
        operationName: request.operationName,
        variables: request.variables,
        parseArguments: true
      )
    } catch {
      return workflowExecutionError(code: "INVALID_EXECUTION_INPUT", message: "invalid GraphQL document")
    }
    let hasExecutionRoots = operations.contains { operation in
      operation.rootFields.contains { WorkflowExecutionGraphQLDocumentExecutor.supports($0.fieldName) }
    }
    guard hasExecutionRoots else { return await next.execute(request) }
    let configured = expectedBearer ?? ""
    let received = request.transportCredential?.value ?? ""
    guard request.isLocallyTrusted || (!configured.isEmpty && !received.isEmpty && secureBearerEquals(configured, received)) else {
      return workflowExecutionError(code: "UNAUTHENTICATED", message: "workflow execution authentication failed")
    }
    do {
      for operation in operations {
        try validateWorkflowExecutionRoots(
          operation.rootFields.filter { WorkflowExecutionGraphQLDocumentExecutor.supports($0.fieldName) }
        )
      }
    } catch {
      return workflowExecutionError(code: "INVALID_EXECUTION_INPUT", message: "invalid workflow execution input")
    }
    var routed = request
    routed.executionAuthorized = true
    return await next.execute(routed)
  }
}

public struct WorkflowExecutionGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  public static let queryFields: Set<String> = ["workflowExecution"]
  public static let mutationFields: Set<String> = ["executeWorkflow"]

  public var provider: (any WorkflowExecutionGraphQLProviding)?
  public var next: (any GraphQLDocumentExecuting)?

  public init(
    provider: (any WorkflowExecutionGraphQLProviding)? = nil,
    next: (any GraphQLDocumentExecuting)? = nil
  ) {
    self.provider = provider
    self.next = next
  }

  static func supports(_ field: String) -> Bool {
    queryFields.contains(field) || mutationFields.contains(field)
  }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    let roots: [ParsedGraphQLRootField]
    do {
      if let parsed = request.parsedRootFields {
        roots = parsed
      } else {
        let operations = try parseGraphQLOperations(
          in: request.query,
          operationName: request.operationName,
          variables: request.variables,
          parseArguments: true
        )
        for operation in operations {
          try validateWorkflowExecutionRoots(operation.rootFields.filter { Self.supports($0.fieldName) })
        }
        guard let selected = try selectGraphQLOperation(operations, operationName: request.operationName) else {
          return .notHandled
        }
        roots = selected.rootFields
      }
    } catch {
      return workflowExecutionError(code: "INVALID_EXECUTION_INPUT", message: "invalid workflow execution input")
    }
    let executionRoots = roots.filter { Self.supports($0.fieldName) }
    guard !executionRoots.isEmpty else {
      return await next?.execute(request) ?? .notHandled
    }
    if let rejected = await preflight(request, rootFields: roots) { return rejected }
    guard let provider else {
      return workflowExecutionError(code: "WORKFLOW_EXECUTION_FAILED", message: "workflow execution provider unavailable")
    }
    var data: JSONObject = [:]
    for root in executionRoots {
      do {
        let value: JSONValue
        if root.fieldName == "executeWorkflow" {
          guard case let .object(inputObject)? = root.arguments["input"] else {
            return workflowExecutionError(code: "INVALID_EXECUTION_INPUT", message: "invalid workflow execution input")
          }
          let input = try JSONDecoder().decode(
            GraphQLExecuteWorkflowInput.self,
            from: JSONEncoder().encode(JSONValue.object(inputObject))
          )
          value = try workflowExecutionJSON(await provider.executeWorkflow(input))
        } else {
          guard case let .string(sessionId)? = root.arguments["workflowExecutionId"] else {
            return workflowExecutionError(code: "INVALID_EXECUTION_INPUT", message: "invalid workflow execution ID")
          }
          if let summary = try await provider.workflowExecution(workflowExecutionId: sessionId) {
            value = try workflowExecutionJSON(summary)
          } else {
            value = .null
          }
        }
        data[root.responseKey] = projectGraphQLValue(value, selections: root.selections)
      } catch {
        return workflowExecutionError(code: "WORKFLOW_EXECUTION_FAILED", message: "workflow execution failed", completedData: data)
      }
    }
    return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(data)])
  }
}

extension WorkflowExecutionGraphQLDocumentExecutor: GraphQLDocumentDomainPreflighting {
  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    let executionRoots = rootFields.filter { Self.supports($0.fieldName) }
    if !executionRoots.isEmpty {
      guard request.executionAuthorized || request.isLocallyTrusted else {
        return workflowExecutionError(code: "UNAUTHENTICATED", message: "workflow execution authentication failed")
      }
      do { try validateWorkflowExecutionRoots(executionRoots) } catch {
        return workflowExecutionError(code: "INVALID_EXECUTION_INPUT", message: "invalid workflow execution input")
      }
    }
    let otherRoots = rootFields.filter { !Self.supports($0.fieldName) }
    if !otherRoots.isEmpty {
      guard let preflighting = next as? any GraphQLDocumentDomainPreflighting else {
        return workflowExecutionError(code: "INVALID_EXECUTION_INPUT", message: "mixed-domain preflight unavailable")
      }
      return await preflighting.preflight(request, rootFields: otherRoots)
    }
    return nil
  }
}

private func workflowExecutionJSON<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private func workflowExecutionError(
  code: String,
  message: String,
  completedData: JSONObject = [:]
) -> GraphQLDocumentExecutionResponse {
  GraphQLDocumentExecutionResponse(handled: true, body: [
    "data": completedData.isEmpty ? .null : .object(completedData),
    "errors": .array([.object([
      "message": .string(message),
      "extensions": .object(["code": .string(code)])
    ])])
  ])
}

private func secureBearerEquals(_ expected: String, _ received: String) -> Bool {
  let left = Array(expected.utf8)
  let right = Array(received.utf8)
  var difference = left.count ^ right.count
  for index in 0..<max(left.count, right.count) {
    let leftByte = index < left.count ? left[index] : 0
    let rightByte = index < right.count ? right[index] : 0
    difference |= Int(leftByte ^ rightByte)
  }
  return difference == 0
}
