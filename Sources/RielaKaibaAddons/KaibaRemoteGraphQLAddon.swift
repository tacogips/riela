import AppCore
import AppGraphQL
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import RielaAddonSupport
import RielaCore

/// `kaiba/note-graphql-remote` — riela's node for kaiba running as an external
/// GraphQL server.
///
/// It is deliberately not the local document node with an extra flag. This node
/// opens no store and holds no schema of its own: it forwards a document to
/// `kaiba serve` with a bearer key, and kaiba's own authentication, account
/// ownership, and library access control decide what the call may reach. The
/// only local state it needs is the endpoint and the name of the environment
/// variable holding the key.
public enum KaibaRemoteGraphQLAddon {
  static let addonName = "kaiba/note-graphql-remote"

  /// Test seam. The node's contract — what it sends and how it reports — is
  /// testable without a live `kaiba serve` by substituting the transport;
  /// production always uses the real URLSession transport.
  @TaskLocal static var transportOverride: (any GraphQLHTTPTransporting)?

  static func execute(
    _ input: WorkflowAddonExecutionInput,
    environment: [String: String]
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(
        .policyBlocked,
        "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'"
      )
    }
    let inputs = KaibaAddonInputs(input: input, environment: environment)
    let endpoint = try inputs.requiredString(["endpoint"], fieldName: "endpoint")
    guard let baseURL = URL(string: endpoint), baseURL.scheme != nil else {
      throw noteAddonInvalidInput("\(input.addon.name) endpoint must be an absolute URL, got: \(endpoint)")
    }
    let query = try inputs.requiredString(["query", "document"], fieldName: "query")
    // Resolved once: it decides both the header and what the payload reports.
    let apiKey = try inputs.remoteAPIKey()
    let client = GraphQLHTTPDocumentClient(
      endpoint: GraphQLHTTPDocumentClient.endpointURL(from: baseURL),
      bearerToken: apiKey,
      transport: transportOverride ?? URLSessionGraphQLHTTPTransport()
    )
    let response = await client.execute(GraphQLDocumentRequest(
      query: query,
      variables: try kaibaJSONObject(remoteGraphQLVariables(inputs)),
      operationName: inputs.string(["operationName"])
    ))
    var payload = try kaibaGraphQLDocumentPayload(
      addonName: input.addon.name,
      responseBody: try rielaJSONObject(response.body),
      handled: response.handled,
      status: response.status,
      resolvedInputPayload: input.resolvedInputPayload
    )
    payload["status"] = .string("ok")
    payload["addon"] = .string(input.addon.name)
    payload["operation"] = .string("graphql-remote")
    payload["stepId"] = .string(input.stepId)
    payload["endpoint"] = .string(endpoint)
    payload["authenticated"] = .bool(apiKey != nil)
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: ["always": true],
      payload: payload
    )
  }
}

private func remoteGraphQLVariables(_ inputs: KaibaAddonInputs) throws -> RielaCore.JSONObject {
  guard let rawVariables = inputs.value("variables") else {
    return [:]
  }
  let rendered = renderJSONTemplates(rawVariables, variables: inputs.variables)
  guard case let .object(variables) = rendered else {
    throw noteAddonInvalidInput("\(inputs.addonName) variables must be an object")
  }
  return variables
}
