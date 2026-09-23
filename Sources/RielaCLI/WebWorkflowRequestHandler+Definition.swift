import Foundation
import RielaCore
import RielaGraphQL
import RielaServer
import RielaWorkflowRegistry

public extension RielaWebWorkflowRequestHandler {
  /// Explicit authoring projection. Normal registry queries retain their
  /// existing redaction contract; unknown configuration and env stay opaque.
  func webWorkflowEditorDefinition(request: RielaHTTPRequest) async -> RielaHTTPResponse {
    guard request.headers["x-riela-profile"] == context.profile.rawValue else {
      return .json(status: 409, .object(["error": .object(["message": .string("The active profile changed. Refresh before editing.")])]))
    }
    guard request.method == "POST", request.body.count <= 16_384,
          let body = try? JSONDecoder().decode(JSONObject.self, from: request.body),
          case let .string(workflowId)? = body["workflowId"],
          case let .string(originId)? = body["originId"] else {
      return .json(status: 400, .object(["error": .object(["message": .string("Select an exact saved workflow.")])]))
    }
    do {
      let entry = try await FileWorkflowRegistryGraphQLProvider(
        workingDirectory: context.workingDirectory.path,
        webPrincipalId: context.principalId,
        authoringProjection: true
      ).workflow(target: WorkflowRegistryTarget(workflowId: workflowId, scope: .user, originId: originId))
      return RielaHTTPResponse(status: 200,
        headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: try JSONEncoder().encode(entry))
    } catch {
      return .json(status: 422, .object(["error": .object(["message": .string("Could not load this mutable workflow for editing.")])]))
    }
  }

  /// Copies the complete bundle, including node/prompt files, into the mutable
  /// registry. Package definitions remain owned by the package manager.
  func webWorkflowEditableCopy(sourceId: String, request: RielaHTTPRequest) async -> RielaHTTPResponse {
    guard request.headers["x-riela-profile"] == context.profile.rawValue else {
      return .json(status: 409, .object(["error": .object([
        "code": .string("profile_conflict"), "message": .string("The active profile changed. Refresh before continuing.")
      ])]))
    }
    guard let source = context.sources.first(where: { $0.id == sourceId }) else {
      return .json(status: 404, .object(["error": .object([
        "code": .string("source_not_found"), "message": .string("The workflow source no longer exists.")
      ])]))
    }
    let provider = FileWorkflowRegistryGraphQLProvider(workingDirectory: context.workingDirectory.path)
    do {
      var payload = try await provider.registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(overwrite: false, activationState: .deactivated),
        resolvedBundleURL: URL(fileURLWithPath: source.workflowDirectory, isDirectory: true)
      )
      if let workflow = payload.workflow {
        payload.workflow = try await FileWorkflowRegistryGraphQLProvider(
          workingDirectory: context.workingDirectory.path,
          webPrincipalId: context.principalId
        ).workflow(target: WorkflowRegistryTarget(
          workflowId: workflow.workflowId, scope: .user, originId: workflow.originId
        ))
      }
      let data = try JSONEncoder().encode(payload)
      return RielaHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
    } catch {
      return .json(status: 422, .object(["error": .object([
        "code": .string("copy_failed"),
        "message": .string("Could not create an editable copy. If a mutable workflow with this ID already exists, open it from Workflow studio.")
      ])]))
    }
  }
}
