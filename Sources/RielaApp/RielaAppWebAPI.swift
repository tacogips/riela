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
  var expectedProfile: String?
  var workingDirectory: String?
  var environmentFilePath: String?
  var environmentVariableUpdates: [String: String]?
  var environmentVariablesToClear: [String]?
  var workflowVariables: JSONObject?
}

private struct RielaAppWebAssistantPatch: Decodable {
  var expectedRevision: Int
  var expectedProfile: String?
  var assistance: String?
  var vendor: RielaAppAssistantVendor?
  var model: String?
}

private struct RielaAppWebNoteSettingsPatch: Decodable {
  var expectedRevision: Int
  var expectedProfile: String?
  var exposesNoteAPI: Bool?
  var s3Profiles: [RielaAppWebNoteS3ProfilePayload]?
}

private struct RielaAppWebNoteClientRequest: Decodable {
  var expectedRevision: Int
  var expectedProfile: String?
}

private struct RielaAppWebAppearancePatch: Decodable {
  var expectedRevision: Int
  var colorScheme: String
}

private struct RielaAppWebServerSettingsPatch: Decodable {
  var expectedRevision: Int
  var isEnabled: Bool?
  var port: Int?
}

private struct RielaAppWebDirectoryRequest: Decodable {
  var expectedRevision: Int
  var expectedProfile: String?
  var path: String
}

extension RielaApp {
  func webAPIResponse(for request: RielaHTTPRequest, csrfToken: String) async -> RielaHTTPResponse {
    let components = request.percentEncodedPath.split(separator: "/").map(String.init)
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
        "profile": .string(daemonProfileName.rawValue),
        "revision": .number(Double(webRevision)),
        "items": .array(webInstancesJSON())
      ])
    case ("GET", "/api/v1/workflows/sources"):
      return webJSON([
        "profile": .string(daemonProfileName.rawValue),
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
            "scope": .string(source.sourceScope.rawValue),
            "sourceKind": .string(source.packageDirectory == nil ? "directory" : "package")
          ])
        })
      ])
    case ("POST", "/api/v1/workflows/sources/directories"):
      return await webAddWorkflowDirectory(request: request, csrfToken: csrfToken)
    case ("GET", "/api/v1/settings/assistant"):
      return webJSON([
        "profile": .string(daemonProfileName.rawValue),
        "revision": .number(Double(webRevision)),
        "assistance": .string(daemonState.assistant.assistance),
        "vendor": .string(daemonState.assistant.vendor.rawValue),
        "model": .string(daemonState.assistant.normalizedModel)
      ])
    case ("PUT", "/api/v1/settings/assistant"):
      return await webUpdateAssistantSettings(request: request, csrfToken: csrfToken)
    case ("GET", "/api/v1/settings/notes"):
      return webJSON(webNoteSettingsJSON())
    case ("PUT", "/api/v1/settings/notes"):
      return await webUpdateNoteSettings(request: request, csrfToken: csrfToken)
    case ("GET", "/api/v1/settings/notes/clients"):
      return webNoteClientsJSON()
    case ("POST", "/api/v1/settings/notes/clients/registrations"):
      guard let body = decodeWebBody(request, as: RielaAppWebNoteClientRequest.self),
            body.expectedRevision == webRevision else {
        return webConflictOrBadRequest(request)
      }
      return await webRegisterNoteClient(expectedProfile: body.expectedProfile)
    case ("GET", "/api/v1/settings/appearance"):
      return webJSON(webAppearanceSettingsJSON())
    case ("PUT", "/api/v1/settings/appearance"):
      guard let patch = decodeWebBody(request, as: RielaAppWebAppearancePatch.self),
            patch.expectedRevision == webRevision else {
        return webConflictOrBadRequest(request)
      }
      return webUpdateAppearanceSettings(colorScheme: patch.colorScheme)
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
      return await webParameterizedResponse(components: components, request: request)
    }
  }

  private func webAddWorkflowDirectory(
    request: RielaHTTPRequest,
    csrfToken: String
  ) async -> RielaHTTPResponse {
    guard let body = decodeWebBody(request, as: RielaAppWebDirectoryRequest.self) else {
      return webConflictOrBadRequest(request)
    }
    if let conflict = webProfileConflict(expectedProfile: body.expectedProfile) { return conflict }
    guard body.expectedRevision == webRevision else { return webConflictOrBadRequest(request) }
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
  }

  private func webUpdateAssistantSettings(
    request: RielaHTTPRequest,
    csrfToken: String
  ) async -> RielaHTTPResponse {
    guard let patch = decodeWebBody(request, as: RielaAppWebAssistantPatch.self) else {
      return webConflictOrBadRequest(request)
    }
    if let conflict = webProfileConflict(expectedProfile: patch.expectedProfile) { return conflict }
    guard patch.expectedRevision == webRevision else { return webConflictOrBadRequest(request) }
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
  }

  private func webUpdateNoteSettings(
    request: RielaHTTPRequest,
    csrfToken: String
  ) async -> RielaHTTPResponse {
    guard let patch = decodeWebBody(request, as: RielaAppWebNoteSettingsPatch.self) else {
      return webConflictOrBadRequest(request)
    }
    if let conflict = webProfileConflict(expectedProfile: patch.expectedProfile) { return conflict }
    guard patch.expectedRevision == webRevision else { return webConflictOrBadRequest(request) }
    let store = RielaAppNoteSettingsStore(noteRoot: noteRootURL(profileName: daemonProfileName))
    var settings = store.load()
    if let exposesNoteAPI = patch.exposesNoteAPI { settings.exposesNoteAPI = exposesNoteAPI }
    if let s3Profiles = patch.s3Profiles {
      do {
        settings.s3Profiles = try s3Profiles.map { try $0.validatedSettings() }
      } catch {
        return webError(status: 400, code: "invalid_settings", message: error.localizedDescription)
      }
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
  }

  private func webParameterizedResponse(
    components: [String],
    request: RielaHTTPRequest
  ) async -> RielaHTTPResponse {
    if let noteResponse = await webNoteWorkspaceResponse(components: components, request: request) {
      return noteResponse
    }
    if components.count == 6,
       components[0...3] == ["api", "v1", "workflows", "sources"],
       components[5] == "definition",
       request.method == "GET",
       let sourceId = components[4].removingPercentEncoding {
      return webWorkflowDefinition(sourceId: sourceId)
    }
    if components.count == 6,
       components[0...4] == ["api", "v1", "settings", "notes", "clients"],
       request.method == "DELETE",
       let clientId = components[5].removingPercentEncoding {
      guard let body = decodeWebBody(request, as: RielaAppWebNoteClientRequest.self),
            body.expectedRevision == webRevision else {
        return webConflictOrBadRequest(request)
      }
      return webRevokeNoteClient(clientId: clientId, expectedProfile: body.expectedProfile)
    }
    guard components.count == 4 || components.count == 5 || components.count == 6,
          components[0...2] == ["api", "v1", "instances"],
          let identity = components[3].removingPercentEncoding else {
      return webError(status: 404, code: "not_found", message: "Unknown API route")
    }
    if components.count == 4, request.method == "GET" {
      return webInstanceDetail(identity: identity)
    }
    if components.count == 5, components[4] == "configuration", request.method == "PUT" {
      return await webUpdateInstance(identity: identity, request: request)
    }
    if components.count == 5, components[4] == "executions", request.method == "GET" {
      return webExecutions(identity: identity)
    }
    if components.count == 6,
       components[4] == "executions",
       request.method == "GET",
       let sessionId = components[5].removingPercentEncoding {
      return webExecutionDetail(identity: identity, sessionId: sessionId)
    }
    return webError(status: 404, code: "not_found", message: "Unknown API route")
  }

  private func webInstanceDetail(identity: String) -> RielaHTTPResponse {
    if let instance = daemonInstances.first(where: { $0.identity == identity }) {
      return webJSON([
        "profile": .string(daemonProfileName.rawValue),
        "revision": .number(Double(webRevision)),
        "item": webInstanceJSON(instance)
      ])
    }
    if let preference = daemonState.preferences[identity] {
      return webJSON([
        "revision": .number(Double(webRevision)),
        "item": webMissingSourceInstanceJSON(identity: identity, preference: preference)
      ])
    }
    return webError(status: 404, code: "instance_not_found", message: "Workflow instance was not found")
  }

  private func webExecutions(identity: String) -> RielaHTTPResponse {
    guard let instance = daemonInstances.first(where: { $0.identity == identity }) else {
      return webError(status: 404, code: "instance_not_found", message: "Workflow instance was not found")
    }
    do {
      let state = try WorkflowViewerLoader().loadBounded(
        WorkflowViewerLoadRequest(
          workflowDirectory: instance.source.workflowDirectory,
          sessionStoreRoot: webSessionStoreRootPath
        ),
        maximumSessionCount: 101
      )
      let formatter = ISO8601DateFormatter()
      let projection = WorkflowWebProjectionPolicy()
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
        "diagnostics": .array(state.diagnostics.prefix(20).map {
          .string(projection.persistedSummary($0, context: .diagnostic).value)
        })
      ])
    } catch {
      return webJSON([
        "revision": .number(Double(webRevision)),
        "instanceId": .string(identity),
        "items": .array([]),
        "truncated": .bool(false),
        "diagnostics": .array([.string("Workflow executions could not be loaded")])
      ])
    }
  }

  private func webExecutionDetail(identity: String, sessionId: String) -> RielaHTTPResponse {
    guard let instance = daemonInstances.first(where: { $0.identity == identity }) else {
      return webError(status: 404, code: "instance_not_found", message: "Workflow instance was not found")
    }
    do {
      let state = try WorkflowViewerLoader().loadBounded(
        WorkflowViewerLoadRequest(
          workflowDirectory: instance.source.workflowDirectory,
          sessionStoreRoot: webSessionStoreRootPath,
          selectedSessionId: sessionId
        ),
        maximumSessionCount: 1
      )
      guard state.selectedSessionId == sessionId,
            let summary = state.sessions.first(where: { $0.sessionId == sessionId }) else {
        return webError(status: 404, code: "session_not_found", message: "Workflow session was not found")
      }
      let projection = WorkflowWebProjectionPolicy()
      let formatter = ISO8601DateFormatter()
      let steps = Array(state.timeline.prefix(256))
      let messages = Array(state.messages.suffix(200))
      let messageTotalCount = state.messageTotalCount ?? state.messages.count
      let diagnostics = Array(state.diagnostics.suffix(100))
      let evidence = state.loopEvidence
      let gates = Array((evidence?.gates ?? []).prefix(100))
      let sessionIdentifier = projection.identifier(summary.sessionId)
      let workflowIdentifier = projection.identifier(summary.workflowId)
      let currentStepIdentifier = summary.currentStepId.map(projection.identifier)
      let instanceIdentifier = projection.identifier(identity)
      return webBoundedRunDetailJSON([
        "revision": .number(Double(webRevision)),
        "instanceId": .string(instanceIdentifier.value),
        "instanceIdTruncated": .bool(instanceIdentifier.truncated),
        "session": .object([
          "sessionId": .string(sessionIdentifier.value),
          "sessionIdTruncated": .bool(sessionIdentifier.truncated),
          "workflowId": .string(workflowIdentifier.value),
          "workflowIdTruncated": .bool(workflowIdentifier.truncated),
          "status": .string(summary.status.rawValue),
          "currentStepId": currentStepIdentifier.map { .string($0.value) } ?? .null,
          "currentStepIdTruncated": .bool(currentStepIdentifier?.truncated ?? false),
          "updatedAt": .string(formatter.string(from: summary.updatedAt))
        ]),
        "steps": .array(steps.map { step in
          let events = Array(step.backendEvents.suffix(50))
          let executionIdentifier = projection.identifier(step.executionId)
          let stepIdentifier = projection.identifier(step.stepId)
          let nodeIdentifier = projection.identifier(step.nodeId)
          let failure = step.failureReason.map { projection.persistedSummary($0, context: .stepFailure) }
          return .object([
            "executionId": .string(executionIdentifier.value),
            "executionIdTruncated": .bool(executionIdentifier.truncated),
            "stepId": .string(stepIdentifier.value),
            "stepIdTruncated": .bool(stepIdentifier.truncated),
            "nodeId": .string(nodeIdentifier.value),
            "nodeIdTruncated": .bool(nodeIdentifier.truncated),
            "attempt": .number(Double(step.attempt)),
            "status": .string(step.status.rawValue),
            "backend": step.backend.map { .string($0.rawValue) } ?? .null,
            "startedAt": .string(formatter.string(from: step.startedAt)),
            "endedAt": step.endedAt.map { .string(formatter.string(from: $0)) } ?? .null,
            "durationMs": step.duration.map { .number($0 * 1_000) } ?? .null,
            "failureReason": failure.map { .string($0.value) } ?? .null,
            "failureReasonTruncated": .bool(failure?.truncated ?? false),
            "events": .array(events.map { event in
              let eventType = projection.identifier(event.eventType)
              let toolName = event.toolName.map(projection.identifier)
              return .object([
                "sequence": .number(Double(event.sequence)),
                "at": .string(formatter.string(from: event.at)),
                "eventType": .string(eventType.value),
                "eventTypeTruncated": .bool(eventType.truncated),
                "channel": event.channel.map { .string($0.rawValue) } ?? .null,
                "toolName": toolName.map { .string($0.value) } ?? .null,
                "toolNameTruncated": .bool(toolName?.truncated ?? false)
              ])
            }),
            "eventTotalCount": .number(Double(step.backendEventTotalCount ?? step.backendEvents.count)),
            "eventsTruncated": .bool((step.backendEventTotalCount ?? step.backendEvents.count) > events.count)
          ])
        }),
        "stepsTotalCount": .number(Double(state.timeline.count)),
        "stepsTruncated": .bool(state.timeline.count > steps.count),
        "logs": .array(messages.map { message in
          let communicationId = projection.identifier(message.id)
          let fromStepId = message.fromStepId.map(projection.identifier)
          let toStepId = message.toStepId.map(projection.identifier)
          let sourceExecutionId = message.sourceStepExecutionId.map(projection.identifier)
          return .object([
            "communicationId": .string(communicationId.value),
            "communicationIdTruncated": .bool(communicationId.truncated),
            "direction": .string(message.direction.rawValue),
            "fromStepId": fromStepId.map { .string($0.value) } ?? .null,
            "fromStepIdTruncated": .bool(fromStepId?.truncated ?? false),
            "toStepId": toStepId.map { .string($0.value) } ?? .null,
            "toStepIdTruncated": .bool(toStepId?.truncated ?? false),
            "sourceStepExecutionId": sourceExecutionId.map { .string($0.value) } ?? .null,
            "sourceStepExecutionIdTruncated": .bool(sourceExecutionId?.truncated ?? false),
            "status": .string(message.status.rawValue),
            "deliveryKind": message.deliveryKind.map { .string($0.rawValue) } ?? .null,
            "createdOrder": message.createdOrder.map { .number(Double($0)) } ?? .null,
            "createdAt": message.createdAt.map { .string(formatter.string(from: $0)) } ?? .null
          ])
        }),
        "logsTotalCount": .number(Double(messageTotalCount)),
        "logsTruncated": .bool(messageTotalCount > messages.count),
        "diagnostics": .array(diagnostics.map { webPersistedSummaryJSON($0, context: .diagnostic) }),
        "diagnosticsTotalCount": .number(Double(state.diagnostics.count)),
        "diagnosticsTruncated": .bool(state.diagnostics.count > diagnostics.count),
        "gates": .array(gates.map { gate in
          let findings = Array(gate.blockingFindings.prefix(50))
          let evidenceReferences = Array(gate.evidenceRefs.prefix(50))
          let gateDiagnostics = Array(gate.diagnostics.prefix(100))
          let gateId = projection.identifier(gate.gateId)
          let gateStepId = projection.identifier(gate.stepId)
          return .object([
            "gateId": .string(gateId.value),
            "gateIdTruncated": .bool(gateId.truncated),
            "stepId": .string(gateStepId.value),
            "stepIdTruncated": .bool(gateStepId.truncated),
            "decision": .string(gate.decision.rawValue),
            "blockingFindingCount": .number(Double(gate.blockingFindings.count)),
            "findings": .array(findings.map { finding in
              let findingId = projection.identifier(finding.id)
              let severity = projection.identifier(finding.severity)
              let filePath = finding.filePath.map(projection.displayText)
              let findingSummary = projection.persistedSummary(finding.message, context: .gateFinding)
              return JSONValue.object([
                "id": .string(findingId.value),
                "idTruncated": .bool(findingId.truncated),
                "severity": .string(severity.value),
                "severityTruncated": .bool(severity.truncated),
                "file": filePath.map { .string($0.value) } ?? .null,
                "fileTruncated": .bool(filePath?.truncated ?? false),
                "line": finding.line.map { .number(Double($0)) } ?? .null,
                "summary": .string(findingSummary.value),
                "summaryTruncated": .bool(findingSummary.truncated),
                "evidenceReferenceCount": .number(Double(finding.evidenceRefs.count))
              ])
            }),
            "findingsTotalCount": .number(Double(gate.blockingFindings.count)),
            "findingsTruncated": .bool(gate.blockingFindings.count > findings.count),
            "evidenceRefs": .array(evidenceReferences.map { reference in
              let projected = projection.identifier(reference)
              return .object([
                "value": .string(projected.value),
                "truncated": .bool(projected.truncated)
              ])
            }),
            "evidenceRefsTotalCount": .number(Double(gate.evidenceRefs.count)),
            "evidenceRefsTruncated": .bool(gate.evidenceRefs.count > evidenceReferences.count),
            "diagnostics": .array(gateDiagnostics.map {
              webPersistedSummaryJSON($0, context: .diagnostic)
            }),
            "diagnosticsTotalCount": .number(Double(gate.diagnostics.count)),
            "diagnosticsTruncated": .bool(gate.diagnostics.count > gateDiagnostics.count)
          ])
        }),
        "gatesTotalCount": .number(Double(evidence?.gates.count ?? 0)),
        "gatesTruncated": .bool((evidence?.gates.count ?? 0) > gates.count),
        "recovery": evidence?.recovery.map { recovery in
          let childSessionIds = Array(recovery.childSessionIds.prefix(100))
          let reason = recovery.reason.map { projection.persistedSummary($0, context: .recoveryReason) }
          let parentSessionId = recovery.parentSessionId.map(projection.identifier)
          return .object([
            "entryMode": .string(recovery.entryMode.rawValue),
            "parentSessionId": parentSessionId.map { .string($0.value) } ?? .null,
            "parentSessionIdTruncated": .bool(parentSessionId?.truncated ?? false),
            "childSessionIds": .array(childSessionIds.map { childSessionId in
              let projected = projection.identifier(childSessionId)
              return .object([
                "value": .string(projected.value),
                "truncated": .bool(projected.truncated)
              ])
            }),
            "childSessionIdsTotalCount": .number(Double(recovery.childSessionIds.count)),
            "childSessionIdsTruncated": .bool(recovery.childSessionIds.count > childSessionIds.count),
            "reason": reason.map { .string($0.value) } ?? .null,
            "reasonTruncated": .bool(reason?.truncated ?? false)
          ])
        } ?? .null,
        "truncated": .bool(
          state.timeline.count > steps.count
            || state.messages.count > messages.count
            || state.diagnostics.count > diagnostics.count
            || (evidence?.gates.count ?? 0) > gates.count
        )
      ])
    } catch let error as WorkflowViewerLoadError {
      return webError(status: 404, code: "session_not_found", message: webSafeSummary(error.description))
    } catch {
      return webError(status: 500, code: "session_load_failed", message: "The persisted workflow session could not be loaded")
    }
  }

  private func webWorkflowDefinition(sourceId: String) -> RielaHTTPResponse {
    guard let source = daemonWorkflowSources.first(where: { $0.id == sourceId }) else {
      return webError(status: 404, code: "workflow_source_not_found", message: "Workflow source was not found")
    }
    let workflowURL = URL(
      fileURLWithPath: source.workflowDirectory,
      isDirectory: true
    ).appendingPathComponent("workflow.json")
    do {
      let data = try Data(contentsOf: workflowURL)
      guard data.count <= WorkflowWebProjectionPolicy.definitionResponseLimit else {
        return webError(
          status: 413,
          code: "workflow_definition_too_large",
          message: "The workflow definition exceeds its display limit"
        )
      }
      let validation = validateAuthoredWorkflowData(data)
      guard let workflow = validation.workflow else {
        return webError(status: 422, code: "invalid_workflow", message: "The workflow definition is invalid")
      }
      let projection = WorkflowWebProjectionPolicy()
      let steps = Array(workflow.steps.prefix(500))
      let nodes = Array(workflow.nodes.prefix(500))
      let diagnostics = Array(validation.diagnostics.prefix(100))
      let transitionTotalCount = workflow.steps.reduce(0) { $0 + ($1.transitions?.count ?? 0) }
      var transitionBudget = 500
      let description = projection.displayText(workflow.description)
      let sourceIdentifier = projection.identifier(source.id)
      let workflowIdentifier = projection.identifier(workflow.workflowId)
      let displayName = projection.displayText(source.displayName)
      let entryStepIdentifier = projection.identifier(workflow.entryStepId)
      let managerStepIdentifier = workflow.managerStepId.map(projection.identifier)
      let response: JSONObject = [
        "revision": .number(Double(webRevision)),
        "sourceId": .string(sourceIdentifier.value),
        "sourceIdTruncated": .bool(sourceIdentifier.truncated),
        "workflowId": .string(workflowIdentifier.value),
        "workflowIdTruncated": .bool(workflowIdentifier.truncated),
        "name": .string(displayName.value),
        "nameTruncated": .bool(displayName.truncated),
        "scope": .string(source.sourceScope.rawValue),
        "sourceKind": .string(source.packageDirectory == nil ? "directory" : "package"),
        "definitionRevision": .string(webContentRevision(data)),
        "definition": .object([
          "description": .string(description.value),
          "descriptionTruncated": .bool(description.truncated),
          "entryStepId": .string(entryStepIdentifier.value),
          "entryStepIdTruncated": .bool(entryStepIdentifier.truncated),
          "managerStepId": managerStepIdentifier.map { .string($0.value) } ?? .null,
          "managerStepIdTruncated": .bool(managerStepIdentifier?.truncated ?? false),
          "steps": .array(steps.map { step in
            let availableTransitions = min(step.transitions?.count ?? 0, transitionBudget)
            let transitions = Array((step.transitions ?? []).prefix(availableTransitions))
            transitionBudget -= transitions.count
            let stepIdentifier = projection.identifier(step.id)
            let nodeIdentifier = projection.identifier(step.nodeId)
            return .object([
              "id": .string(stepIdentifier.value),
              "idTruncated": .bool(stepIdentifier.truncated),
              "nodeId": .string(nodeIdentifier.value),
              "nodeIdTruncated": .bool(nodeIdentifier.truncated),
              "role": step.role.map { .string($0.rawValue) } ?? .null,
              "transitions": .array(transitions.map { transition in
                let label = transition.label.map(projection.displayText)
                let targetIdentifier = projection.identifier(transition.toStepId)
                return .object([
                  "toStepId": .string(targetIdentifier.value),
                  "toStepIdTruncated": .bool(targetIdentifier.truncated),
                  "label": label.map { .string($0.value) } ?? .null,
                  "labelTruncated": .bool(label?.truncated ?? false)
                ])
              }),
              "transitionsTotalCount": .number(Double(step.transitions?.count ?? 0)),
              "transitionsTruncated": .bool((step.transitions?.count ?? 0) > transitions.count)
            ])
          }),
          "stepsTotalCount": .number(Double(workflow.steps.count)),
          "stepsTruncated": .bool(workflow.steps.count > steps.count),
          "nodes": .array(nodes.map { node in
            let nodeIdentifier = projection.identifier(node.id)
            return .object([
              "id": .string(nodeIdentifier.value),
              "idTruncated": .bool(nodeIdentifier.truncated),
              "kind": node.kind.map { .string($0.rawValue) } ?? .null,
              "role": node.role.map { .string($0.rawValue) } ?? .null
            ])
          }),
          "nodesTotalCount": .number(Double(workflow.nodes.count)),
          "nodesTruncated": .bool(workflow.nodes.count > nodes.count),
          "transitionsTotalCount": .number(Double(transitionTotalCount)),
          "transitionsTruncated": .bool(transitionTotalCount > 500)
        ]),
        "diagnostics": .array(diagnostics.map {
          webPersistedSummaryJSON(
            "\($0.path): \($0.message)",
            context: .registryDiagnostic
          )
        }),
        "diagnosticsTotalCount": .number(Double(validation.diagnostics.count)),
        "diagnosticsTruncated": .bool(validation.diagnostics.count > diagnostics.count),
        "truncated": .bool(
          workflow.steps.count > steps.count
            || workflow.nodes.count > nodes.count
            || transitionTotalCount > 500
            || validation.diagnostics.count > 100
        )
      ]
      return webBoundedDefinitionJSON(response)
    } catch {
      return webError(status: 404, code: "workflow_definition_unavailable", message: "Workflow definition was not found")
    }
  }

  private func webUpdateInstance(
    identity: String,
    request: RielaHTTPRequest
  ) async -> RielaHTTPResponse {
    guard let patch = decodeWebBody(request, as: RielaAppWebInstancePatch.self) else {
      return webConflictOrBadRequest(request)
    }
    if let conflict = webProfileConflict(expectedProfile: patch.expectedProfile) { return conflict }
    guard patch.expectedRevision == webRevision else {
      return webConflictOrBadRequest(request)
    }
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      return webError(status: 404, code: "instance_not_found", message: "Workflow instance was not found")
    }
    let saved = updateDaemonPreference(identity: identity) { preference in
      if let workingDirectory = patch.workingDirectory {
        preference.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if let environmentFilePath = patch.environmentFilePath {
        preference.environmentFilePath = environmentFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if let environmentVariableUpdates = patch.environmentVariableUpdates {
        for (name, value) in environmentVariableUpdates where !value.isEmpty {
          preference.environmentVariables[name] = value
        }
      }
      if let environmentVariablesToClear = patch.environmentVariablesToClear {
        for name in environmentVariablesToClear {
          preference.environmentVariables.removeValue(forKey: name)
        }
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
    let updatedPreference = daemonState(profileName: resolved.profileName).preference(for: resolved.localIdentity)
    let updatedInstance = WorkflowInstance.configured(
      identity: identity,
      source: resolved.instance.instance.source,
      preference: updatedPreference
    )
    return webJSON([
      "profile": .string(daemonProfileName.rawValue),
      "revision": .number(Double(webRevision)),
      "item": webInstanceJSON(updatedInstance)
    ])
  }

  private func webInstanceJSON(_ instance: WorkflowInstance) -> JSONValue {
    let snapshot = daemonRuntime.snapshot(for: profileRuntimeIdentity(
      profileName: daemonProfileName,
      localIdentity: instance.identity
    ))
    let preference = instance.preference
    let effectiveEnvironment = daemonEnvironment(for: instance.candidate, preference: preference)
    return .object([
      "id": .string(instance.identity),
      "name": .string(instance.displayName),
      "workflowId": .string(instance.source.workflowId),
      "source": .string(instance.source.sourceDescription),
      "sourceKind": .string(instance.source.packageDirectory == nil ? "directory" : "package"),
      "status": .string(snapshot.status.rawValue),
      "statusDetail": .string(snapshot.detail),
      "active": .bool(preference.active),
      "enabledAtLaunch": .bool(preference.enabledAtLaunch),
      "workingDirectory": preference.workingDirectory.map(JSONValue.string) ?? .null,
      "environmentFilePath": preference.environmentFilePath.map(JSONValue.string) ?? .null,
      "environmentVariables": .array(preference.environmentVariables.keys.sorted().map { name in
        .object([
          "name": .string(name),
          "isSet": .bool(true),
          "masked": .string("••••••••")
        ])
      }),
      "requiredEnvironment": .array(instance.candidate.requiredEnvironment.map { requirement in
        let value = effectiveEnvironment[requirement.name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .object([
          "name": .string(requirement.name),
          "description": requirement.description.map(JSONValue.string) ?? .null,
          "required": .bool(true),
          "secret": .bool(requirement.secret),
          "source": .string("workflow"),
          "present": .bool(value?.isEmpty == false)
        ])
      }),
      "workflowVariables": .object(preference.defaultVariables),
      "nodePatchCount": .number(Double(preference.nodePatches.count)),
      "nodePatches": .object(preference.nodePatches.mapValues { .object($0.jsonObject) }),
      "eventSources": .array(instance.source.eventSources.map { eventSource in
        .object(["id": .string(eventSource.id), "kind": .string(eventSource.kind)])
      })
    ])
  }

  private func webInstancesJSON() -> [JSONValue] {
    let availableIdentities = Set(daemonInstances.map(\.identity))
    let availableItems = daemonInstances.map(webInstanceJSON)
    let missingSourceItems = daemonState.preferences
      .filter { !availableIdentities.contains($0.key) }
      .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
      .map { identity, preference in
        webMissingSourceInstanceJSON(identity: identity, preference: preference)
      }
    return availableItems + missingSourceItems
  }

  private func webMissingSourceInstanceJSON(
    identity: String,
    preference: RielaAppDaemonWorkflowPreference
  ) -> JSONValue {
    let sourceIdentity = preference.sourceIdentity ?? identity
    let name = preference.displayName?.isEmpty == false ? preference.displayName ?? identity : identity
    return .object([
      "id": .string(identity),
      "name": .string(name),
      "workflowId": .string(sourceIdentity),
      "source": .string("Missing source: \(sourceIdentity)"),
      "sourceKind": .string("missing"),
      "status": .string("needsSource"),
      "statusDetail": .string("The configured workflow source is unavailable. Relink it in the native app."),
      "active": .bool(preference.active),
      "enabledAtLaunch": .bool(preference.enabledAtLaunch),
      "workingDirectory": preference.workingDirectory.map(JSONValue.string) ?? .null,
      "environmentFilePath": preference.environmentFilePath.map(JSONValue.string) ?? .null,
      "environmentVariables": .array(preference.environmentVariables.keys.sorted().map { name in
        .object([
          "name": .string(name),
          "isSet": .bool(true),
          "masked": .string("••••••••")
        ])
      }),
      "requiredEnvironment": .array([]),
      "workflowVariables": .object(preference.defaultVariables),
      "nodePatchCount": .number(Double(preference.nodePatches.count)),
      "nodePatches": .object(preference.nodePatches.mapValues { .object($0.jsonObject) }),
      "eventSources": .array([])
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

  private func webProfileConflict(expectedProfile: String?) -> RielaHTTPResponse? {
    guard expectedProfile == daemonProfileName.rawValue else {
      return webError(
        status: 409,
        code: "profile_conflict",
        message: "The active profile changed after this editor was loaded"
      )
    }
    return nil
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

  private func webSafeIdentifier(_ value: String) -> String {
    WorkflowWebProjectionPolicy().safeIdentifier(value)
  }

  private var webSessionStoreRootPath: String {
    webSessionStoreRootOverride ?? RielaAppDaemonWorkflowRuntime.defaultSessionStoreRootPath
  }

  private func webSafeSummary(_ value: String) -> String {
    WorkflowWebProjectionPolicy().safeSummary(value)
  }

  private func webPersistedSummaryJSON(
    _ value: String,
    context: WorkflowWebPersistedSummaryContext
  ) -> JSONValue {
    let summary = WorkflowWebProjectionPolicy().persistedSummary(value, context: context)
    return .object([
      "summary": .string(summary.value),
      "truncated": .bool(summary.truncated)
    ])
  }

  private func webContentRevision(_ data: Data) -> String {
    WorkflowWebProjectionPolicy().contentRevision(data)
  }

  private func webBoundedRunDetailJSON(_ object: JSONObject) -> RielaHTTPResponse {
    guard let bounded = WorkflowWebProjectionPolicy().boundedRunDetail(object) else {
      return webError(
        status: 500,
        code: "projection_too_large",
        message: "The bounded workflow session projection exceeded its response limit"
      )
    }
    return webJSON(bounded)
  }

  private func webBoundedDefinitionJSON(_ object: JSONObject) -> RielaHTTPResponse {
    guard let bounded = WorkflowWebProjectionPolicy().boundedDefinition(object) else {
      return webError(
        status: 500,
        code: "projection_too_large",
        message: "The bounded workflow definition projection exceeded its response limit"
      )
    }
    return webJSON(bounded)
  }
}
#endif
