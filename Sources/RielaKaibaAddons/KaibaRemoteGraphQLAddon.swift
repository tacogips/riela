import Foundation
import KaibaClient
import RielaAddonSupport
import RielaCore

/// Compatibility GraphQL transport shared by both registered GraphQL node
/// names. Endpoint and authentication come solely from the preflight snapshot.
public enum KaibaRemoteGraphQLAddon {
  static let addonName = "kaiba/note-graphql-remote"

  static func execute(
    _ input: WorkflowAddonExecutionInput,
    client: KaibaClient
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(
        .policyBlocked,
        "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'"
      )
    }
    let inputs = KaibaAddonInputs(input: input, environment: [:])
    let query = try inputs.requiredString(["query", "document"], fieldName: "query")
    let response: KaibaGraphQLResponse<KaibaJSONValue>
    do {
      response = try await client.execute(.init(
        document: query,
        variables: remoteGraphQLVariables(inputs).mapValues(kaibaJSONValue),
        operationName: inputs.string(["operationName"])
      ))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AdapterExecutionError(.providerError, "kaiba GraphQL request failed")
    }
    var payload = kaibaGraphQLDocumentPayload(
      responseData: rielaJSONValue(response.data),
      resolvedInputPayload: input.resolvedInputPayload
    )
    payload["status"] = .string("ok")
    payload["addon"] = .string(input.addon.name)
    payload["operation"] = .string("graphql")
    payload["stepId"] = .string(input.stepId)
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
