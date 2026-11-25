import RielaCore
import RielaGraphQL

extension ProviderAskMutationSurface {
  private static let registerWorkflow = """
  mutation($input: RegisterMutableWorkflowInput!) {
    registerMutableWorkflow(input: $input) {
      accepted
      workflow { workflowId definitionRevision }
      errors { code message }
    }
  }
  """

  private static let updateWorkflow = """
  mutation($input: UpdateMutableWorkflowInput!) {
    updateMutableWorkflow(input: $input) {
      accepted
      workflow { workflowId definitionRevision }
      errors { code message }
    }
  }
  """

  func applyWorkflow(_ target: AskWorkflowActionTarget) async throws -> AskActionResult {
    var input: JSONObject = ["definition": .object(target.definition)]
    let field: String
    let query: String
    let summary: String
    if let baseId = target.baseWorkflowId, let originId = target.baseOriginId, let revision = target.expectedRevision {
      input["target"] = .object(["workflowId": .string(baseId), "scope": .string("USER"), "originId": .string(originId)])
      input["expectedDefinitionRevision"] = .string(revision)
      field = "updateMutableWorkflow"
      query = Self.updateWorkflow
      summary = "Workflow updated"
    } else {
      input["overwrite"] = .bool(false)
      field = "registerMutableWorkflow"
      query = Self.registerWorkflow
      summary = "Workflow registered"
    }

    let executor = try registry.get()
    let request = GraphQLDocumentRequest(
      query: query, variables: ["input": .object(input)], environment: environment,
      isLocallyTrusted: true, localWorkingDirectory: workingDirectory
    )
    let response = await CLIRuntimeEnvironment.$overrides.withValue(nil) {
      await CLIRuntimeEnvironment.$captured.withValue(environment) {
        await executor.execute(request)
      }
    }
    if let error = Self.registryError(response.body, usesExtensions: true) { throw error }
    guard response.handled, case let .object(data)? = response.body["data"],
          case let .object(payload)? = data[field] else { throw Self.invalidWorkflowResult }
    if let error = Self.registryError(payload, usesExtensions: false) { throw error }
    guard payload["accepted"] == .bool(true), case let .object(workflow)? = payload["workflow"],
          let workflowId = workflow.askString("workflowId"),
          let revision = workflow.askString("definitionRevision") else { throw Self.invalidWorkflowResult }
    return .init(ok: true, summary: summary, ids: [workflowId, revision])
  }

  private static var invalidWorkflowResult: AskError {
    AskError(code: "action_mutation_failed", message: "The workflow registry returned an incomplete mutation result")
  }

  private static func registryError(_ container: JSONObject, usesExtensions: Bool) -> AskError? {
    guard case let .array(errors)? = container["errors"], case let .object(error)? = errors.first else { return nil }
    let code: String?
    if usesExtensions, case let .object(extensions)? = error["extensions"] {
      code = extensions.askString("code")
    } else {
      code = error.askString("code")
    }
    return AskError(
      code: code ?? "action_mutation_failed",
      message: error.askString("message") ?? "Workflow registry mutation failed"
    )
  }
}
