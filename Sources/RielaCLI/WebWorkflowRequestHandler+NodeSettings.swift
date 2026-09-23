import Foundation
import RielaCore
import RielaServer
import RielaWorkflowRegistry

private enum WorkflowNodeSettingsAction: String { case load, save }

public extension RielaWebWorkflowRequestHandler {
  func webWorkflowEditorNodeSettings(request: RielaHTTPRequest) async -> RielaHTTPResponse {
    guard request.headers["x-riela-profile"] == context.profile.rawValue else {
      return nodeSettingsError(409, "The active profile changed. Refresh before editing.")
    }
    guard request.method == "POST", request.body.count <= 524_288,
          let body = try? JSONDecoder().decode(JSONObject.self, from: request.body),
          case let .string(actionName)? = body["action"], let action = WorkflowNodeSettingsAction(rawValue: actionName),
          case let .string(workflowId)? = body["workflowId"],
          case let .string(originId)? = body["originId"],
          case let .string(nodeId)? = body["nodeId"],
          case let .string(revision)? = body["definitionRevision"] else {
      return nodeSettingsError(400, "Select a saved file-backed node.")
    }
    let service = WorkflowRegistryService()
    let target = WorkflowRegistryTarget(workflowId: workflowId, scope: .user, originId: originId)
    do {
      let data: Data
      switch action {
      case .load:
        data = try JSONEncoder().encode(service.editorNodeSettings(target: target, nodeId: nodeId,
          definitionRevision: revision, workingDirectory: context.workingDirectory.path))
      case .save:
        guard case let .string(assetRevision)? = body["assetRevision"] else {
          return nodeSettingsError(400, "Load the current node settings before saving.")
        }
        let prompt = try nodeSettingsString(body, key: "prompt")
        let model = try nodeSettingsString(body, key: "model")
        _ = try service.updateEditorNodeSettings(target: target, nodeId: nodeId,
          definitionRevision: revision, assetRevision: assetRevision, prompt: prompt, model: model,
          workingDirectory: context.workingDirectory.path)
        let entry = try await FileWorkflowRegistryGraphQLProvider(workingDirectory: context.workingDirectory.path,
          webPrincipalId: context.principalId, authoringProjection: true).workflow(target: target)
        data = try JSONEncoder().encode(entry)
      }
      return RielaHTTPResponse(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: data)
    } catch let error as WorkflowRegistryError {
      return nodeSettingsError(error.code == .registryConflict ? 409 : 422, error.message)
    } catch {
      return nodeSettingsError(422, "Could not read or update node settings. Reload the workflow before trying again.")
    }
  }

  private func nodeSettingsString(_ body: JSONObject, key: String) throws -> String? {
    guard let value = body[key] else { return nil }
    guard case let .string(text) = value else {
      throw WorkflowRegistryError(code: .invalidWorkflow, message: "\(key) must be text when changed.")
    }
    return text
  }

  private func nodeSettingsError(_ status: Int, _ message: String) -> RielaHTTPResponse {
    .json(status: status, .object(["error": .object(["message": .string(message)])]))
  }
}
