import Foundation
import RielaCore

public struct GraphQLDocumentRequest: Equatable, Sendable {
  public var query: String
  public var variables: JSONObject
  public var operationName: String?
  public var environment: [String: String]
  public var authenticatedClientId: String?
  public var transportCredential: GraphQLTransportCredential?
  public var isLocallyTrusted: Bool
  public var localWorkingDirectory: String?
  var parsedRootFields: [ParsedNoteGraphQLRootField]?
  var domainPreflightComplete: Bool
  var verifiedRegistryPrincipal: WorkflowRegistryVerifiedPrincipal?

  public init(
    query: String,
    variables: JSONObject = [:],
    operationName: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    authenticatedClientId: String? = nil,
    transportCredential: GraphQLTransportCredential? = nil,
    isLocallyTrusted: Bool = false,
    localWorkingDirectory: String? = nil
  ) {
    self.query = query
    self.variables = variables
    self.operationName = operationName
    self.environment = environment
    self.authenticatedClientId = authenticatedClientId
    self.transportCredential = transportCredential
    self.isLocallyTrusted = isLocallyTrusted
    self.localWorkingDirectory = localWorkingDirectory
    parsedRootFields = nil
    domainPreflightComplete = false
    verifiedRegistryPrincipal = nil
  }
}

public struct GraphQLDocumentExecutionResponse: Equatable, Sendable {
  public var handled: Bool
  public var status: Int
  public var body: JSONObject

  public init(handled: Bool, status: Int = 200, body: JSONObject = [:]) {
    self.handled = handled
    self.status = status
    self.body = body
  }

  public static let notHandled = GraphQLDocumentExecutionResponse(handled: false)
}

public protocol GraphQLDocumentExecuting: Sendable {
  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse
}

protocol GraphQLDocumentDomainPreflighting: Sendable {
  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedNoteGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse?
}

