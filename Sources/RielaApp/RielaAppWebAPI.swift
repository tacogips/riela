#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCore
import RielaServer
import RielaViewer

private struct RielaAppWebRevisionRequest: Decodable {
  var expectedRevision: Int
}

private struct RielaAppWebInstancePatch: Decodable {
  var expectedRevision: Int
  var workingDirectory: String?
  var environmentFilePath: String?
  var environmentVariables: [String: String]?
  var workflowVariables: JSONObject?
}

private struct RielaAppWebAssistantPatch: Decodable {
  var expectedRevision: Int
  var assistance: String?
  var vendor: RielaAppAssistantVendor?
  var model: String?
}

private struct RielaAppWebNoteSettingsPatch: Decodable {
  var expectedRevision: Int
  var exposesNoteAPI: Bool?
  var defaultTranslationTargetLanguage: String?
}

private struct RielaAppWebServerSettingsPatch: Decodable {
  var expectedRevision: Int
  var isEnabled: Bool?
  var port: Int?
}

private struct RielaAppWebDirectoryRequest: Decodable {
  var expectedRevision: Int
  var path: String
}

extension RielaApp {
  func webAPIResponse(for request: RielaHTTPRequest, csrfToken: String) async -> RielaHTTPResponse {
    let components = request.path.split(separator: "/").map(String.init)
    switch (request.method, request.path) {
    case ("GET", "/api/v1/bootstrap"):
      return webJSON([
        "apiVersion": .string("v1"),
        "profile": .string(daemonProfileName.rawValue),
        "csrfToken": .string(csrfToken),
        "revision": .number(Double(webRevision)),
        "capabilities": .array(["instances", "executions", "workflows", "notes", "assistant", "web-server"]
          .map(JSONValue.string)),
        "server": .object(webServerSettingsJSON())
      ])
    case ("GET", "/api/v1/instances"):
      return webJSON([
        "revision": .number(Double(webRevision)),
        "items": .array(daemonInstances.map(webInstanceJSON))
      ])
    case ("GET", "/api/v1/workflows/sources"):
      return webJSON([
        "revision": .number(Double(webRevision)),
        "directories": .array(daemonState.workflowDirectories.map(JSONValue.string)),
        "projectDirectories": .array(daemonState.projectDirectories.map(JSONValue.string)),
        "repositories": .array(daemonState.workflowRepositories.map { repository in
          .object(["id": .string(repository.id), "source": .string(repository.cloneURL)])
        }),
        "discovered": .array(daemonWorkflowSources.map { source in
          .object([
            "id": .string(source.id),
            "name": .string(source.displayName),
            "workflowId": .string(source.workflowId),
            "scope": .string(source.sourceScope.rawValue)
          ])
        })
      ])
    case ("POST", "/api/v1/workflows/sources/directories"):
      guard let body: RielaAppWebDirectoryRequest = decodeWebBody(request, as: RielaAppWebDirectoryRequest.self),
            body.expectedRevision == webRevision else {
        return webConflictOrBadRequest(request)
      }
      var state = daemonState
      state.addWorkflowDirectory(body.path)
      guard saveDaemonState(state, profileName: daemonProfileName) else {
        return webError(status: 500, code: "persistence_failed", message: status)
      }
      webRevision += 1
      refreshDaemonWorkflowWindow()
      return await webAPIResponse(
        for: RielaHTTPRequest(method: "GET", path: "/api/v1/workflows/sources"),
        csrfToken: csrfToken
      )
    case ("GET", "/api/v1/settings/assistant"):
      return webJSON([
        "revision": .number(Double(webRevision)),
        "assistance": .string(daemonState.assistant.assistance),
        "vendor": .string(daemonState.assistant.vendor.rawValue),
        "model": .string(daemonState.assistant.normalizedModel)
      ])
    case ("PUT", "/api/v1/settings/assistant"):
      guard let patch = decodeWebBody(request, as: RielaAppWebAssistantPatch.self),
            patch.expectedRevision == webRevision else {
        return webConflictOrBadRequest(request)
      }
      var settings = daemonState.assistant
      if let assistance = patch.assistance { settings.assistance = assistance }
      if let vendor = patch.vendor { settings.vendor = vendor }
      if let model = patch.model { settings.setSelectedModel(model, for: settings.vendor) }
      if let error = saveAssistantSettings(settings) {
        return webError(status: 500, code: "persistence_failed", message: error)
      }
      webRevision += 1
      return await webAPIResponse(
        for: RielaHTTPRequest(method: "GET", path: "/api/v1/settings/assistant"),
        csrfToken: csrfToken
      )
    case ("GET", "/api/v1/settings/notes"):
      let settings = RielaAppNoteSettingsStore(noteRoot: noteRootURL(profileName: daemonProfileName)).load()
      return webJSON([
        "revision": .number(Double(webRevision)),
        "exposesNoteAPI": .bool(settings.exposesNoteAPI),
        "defaultTranslationTargetLanguage": .string(settings.defaultTranslationTargetLanguage),
        "s3ProfileCount": .number(Double(settings.s3Profiles.count))
      ])
    case ("PUT", "/api/v1/settings/notes"):
      guard let patch = decodeWebBody(request, as: RielaAppWebNoteSettingsPatch.self),
            patch.expectedRevision == webRevision else {
        return webConflictOrBadRequest(request)
      }
      let store = RielaAppNoteSettingsStore(noteRoot: noteRootURL(profileName: daemonProfileName))
      var settings = store.load()
      if let exposesNoteAPI = patch.exposesNoteAPI { settings.exposesNoteAPI = exposesNoteAPI }
      if let language = patch.defaultTranslationTargetLanguage {
        settings.defaultTranslationTargetLanguage = language
      }
      do {
        try store.save(settings)
      } catch {
        return webError(status: 500, code: "persistence_failed", message: error.localizedDescription)
      }
      webRevision += 1
      return await webAPIResponse(
        for: RielaHTTPRequest(method: "GET", path: "/api/v1/settings/notes"),
        csrfToken: csrfToken
      )
    case ("GET", "/api/v1/settings/web-server"):
      return webJSON(webServerSettingsJSON())
    case ("PUT", "/api/v1/settings/web-server"):
      guard let patch = decodeWebBody(request, as: RielaAppWebServerSettingsPatch.self),
            patch.expectedRevision == webRevision else {
        return webConflictOrBadRequest(request)
      }
      do {
        if let port = patch.port {
          try webServerController?.updateConfiguredPort(port)
        }
        if let isEnabled = patch.isEnabled {
          if isEnabled {
            await webServerController?.start()
          } else {
            await webServerController?.stop(explicit: true)
          }
        }
      } catch {
        return webError(status: 400, code: "invalid_settings", message: error.localizedDescription)
      }
      webRevision += 1
      return webJSON(webServerSettingsJSON())
    default:
      if components.count == 4, components[0...2] == ["api", "v1", "instances"], request.method == "GET" {
        return webInstanceDetail(identity: components[3])
      }
      if components.count == 5,
         components[0...2] == ["api", "v1", "instances"],
         components[4] == "configuration",
         request.method == "PUT" {
        return await webUpdateInstance(identity: components[3], request: request, csrfToken: csrfToken)
      }
      if components.count == 5,
         components[0...2] == ["api", "v1", "instances"],
         components[4] == "executions",
         request.method == "GET" {
        return webExecutions(identity: components[3])
      }
      return webError(status: 404, code: "not_found", message: "Unknown API route")
    }
  }

  private func webInstanceDetail(identity: String) -> RielaHTTPResponse {
    guard let instance = daemonInstances.first(where: { $0.identity == identity }) else {
      return webError(status: 404, code: "instance_not_found", message: "Workflow instance was not found")
    }
    return webJSON(["revision": .number(Double(webRevision)), "item": webInstanceJSON(instance)])
  }

  private func webExecutions(identity: String) -> RielaHTTPResponse {
    guard let instance = daemonInstances.first(where: { $0.identity == identity }) else {
      return webError(status: 404, code: "instance_not_found", message: "Workflow instance was not found")
    }
    do {
      let state = try WorkflowViewerLoader().load(WorkflowViewerLoadRequest(
        workflowDirectory: instance.source.workflowDirectory,
        sessionStoreRoot: RielaAppDaemonWorkflowRuntime.defaultSessionStoreRootPath
      ))
      let formatter = ISO8601DateFormatter()
      return webJSON([
        "revision": .number(Double(webRevision)),
        "instanceId": .string(identity),
        "items": .array(state.sessions.prefix(100).map { session in
          .object([
            "sessionId": .string(session.sessionId),
            "workflowId": .string(session.workflowId),
            "status": .string(session.status.rawValue),
            "currentStepId": session.currentStepId.map(JSONValue.string) ?? .null,
            "activeStepIds": .array(session.activeStepIds.map(JSONValue.string)),
            "updatedAt": .string(formatter.string(from: session.updatedAt))
          ])
        }),
        "truncated": .bool(state.sessions.count > 100),
        "diagnostics": .array(state.diagnostics.prefix(20).map(JSONValue.string))
      ])
    } catch {
      return webJSON([
        "revision": .number(Double(webRevision)),
        "instanceId": .string(identity),
        "items": .array([]),
        "diagnostic": .string(error.localizedDescription)
      ])
    }
  }

  private func webUpdateInstance(
    identity: String,
    request: RielaHTTPRequest,
    csrfToken: String
  ) async -> RielaHTTPResponse {
    guard let patch = decodeWebBody(request, as: RielaAppWebInstancePatch.self),
          patch.expectedRevision == webRevision else {
      return webConflictOrBadRequest(request)
    }
    guard resolveDaemonWorkflowInstance(identity: identity) != nil else {
      return webError(status: 404, code: "instance_not_found", message: "Workflow instance was not found")
    }
    let saved = updateDaemonPreference(identity: identity) { preference in
      if let workingDirectory = patch.workingDirectory {
        preference.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if let environmentFilePath = patch.environmentFilePath {
        preference.environmentFilePath = environmentFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if let environmentVariables = patch.environmentVariables {
        preference.environmentVariables = environmentVariables
      }
      if let workflowVariables = patch.workflowVariables {
        preference.defaultVariables = workflowVariables
      }
    }
    guard saved else {
      return webError(status: 500, code: "persistence_failed", message: status)
    }
    webRevision += 1
    restartActiveDaemonWorkflowAfterConfigurationChange(
      identity: identity,
      changeDescription: "web configuration"
    )
    return webInstanceDetail(identity: identity)
  }

  private func webInstanceJSON(_ instance: WorkflowInstance) -> JSONValue {
    let snapshot = daemonRuntime.snapshot(for: profileRuntimeIdentity(
      profileName: daemonProfileName,
      localIdentity: instance.identity
    ))
    let preference = instance.preference
    return .object([
      "id": .string(instance.identity),
      "name": .string(instance.displayName),
      "workflowId": .string(instance.source.workflowId),
      "source": .string(instance.source.sourceDescription),
      "status": .string(snapshot.status.rawValue),
      "statusDetail": .string(snapshot.detail),
      "active": .bool(preference.active),
      "enabledAtLaunch": .bool(preference.enabledAtLaunch),
      "workingDirectory": preference.workingDirectory.map(JSONValue.string) ?? .null,
      "environmentFilePath": preference.environmentFilePath.map(JSONValue.string) ?? .null,
      "environmentVariables": .object(preference.environmentVariables.mapValues(JSONValue.string)),
      "workflowVariables": .object(preference.defaultVariables),
      "nodePatchCount": .number(Double(preference.nodePatches.count)),
      "eventSources": .array(instance.source.eventSources.map { eventSource in
        .object(["id": .string(eventSource.id), "kind": .string(eventSource.kind)])
      })
    ])
  }

  private func webServerSettingsJSON() -> JSONObject {
    let settings = webServerController?.settings ?? RielaAppWebServerSettings()
    return [
      "revision": .number(Double(webRevision)),
      "isEnabled": .bool(settings.isEnabled),
      "configuredPort": .number(Double(settings.port)),
      "boundPort": webServerController?.state.boundPort.map { .number(Double($0)) } ?? .null,
      "restartRequired": .bool(webServerController?.restartRequired ?? false),
      "state": .string(webServerController?.state.label ?? "stopped")
    ]
  }

  private func decodeWebBody<Value: Decodable>(_ request: RielaHTTPRequest, as type: Value.Type) -> Value? {
    try? JSONDecoder().decode(type, from: request.body)
  }

  private func webConflictOrBadRequest(_ request: RielaHTTPRequest) -> RielaHTTPResponse {
    guard let revision = decodeWebBody(request, as: RielaAppWebRevisionRequest.self)?.expectedRevision else {
      return webError(status: 400, code: "invalid_request", message: "expectedRevision and a valid JSON body are required")
    }
    return webError(
      status: 409,
      code: "revision_conflict",
      message: "Expected revision \(revision), current revision is \(webRevision)"
    )
  }

  private func webJSON(_ object: JSONObject, status: Int = 200) -> RielaHTTPResponse {
    .json(status: status, .object(object))
  }

  private func webError(status: Int, code: String, message: String) -> RielaHTTPResponse {
    webJSON([
      "error": .object([
        "code": .string(code),
        "message": .string(message)
      ]),
      "revision": .number(Double(webRevision))
    ], status: status)
  }
}
#endif
