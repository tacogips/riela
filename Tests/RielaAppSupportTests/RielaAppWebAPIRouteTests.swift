#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCLI
import RielaCore
import RielaNote
import RielaServer
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppWebAPIRouteTests: XCTestCase {
  private let identity = "project-workflow:/tmp/riela:review-loop"
  private let secret = "SENTINEL_SECRET_MUST_NOT_RENDER"

  func testCompositeIdentityRoutesDecodeExactlyOnceAndRedactSecrets() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let encodedIdentity = encodePathSegment(identity)
    let router = RielaAppWebRouter(app: fixture.app, assetRoot: fixture.root, configuredPort: 19_091)

    let detailRequest = try parseRawRequest(path: "/api/v1/instances/\(encodedIdentity)")
    XCTAssertEqual(detailRequest.path, "/api/v1/instances/\(identity)")
    XCTAssertEqual(detailRequest.percentEncodedPath, "/api/v1/instances/\(encodedIdentity)")
    let detail = await router.response(for: detailRequest)
    XCTAssertEqual(detail.status, 200)
    let detailJSON = try jsonObject(detail)
    let item = try XCTUnwrap(detailJSON["item"] as? [String: Any])
    let environmentVariables = try XCTUnwrap(item["environmentVariables"] as? [[String: Any]])
    let requiredEnvironment = try XCTUnwrap(item["requiredEnvironment"] as? [[String: Any]])
    XCTAssertEqual(item["id"] as? String, identity)
    XCTAssertEqual(environmentVariables.first?["masked"] as? String, "••••••••")
    XCTAssertEqual(requiredEnvironment.first?["present"] as? Bool, true)
    XCTAssertFalse(String(data: detail.body, encoding: .utf8)?.contains(secret) ?? true)

    let executionsRequest = try parseRawRequest(
      path: "/api/v1/instances/\(encodedIdentity)/executions"
    )
    let executions = await router.response(for: executionsRequest)
    XCTAssertEqual(executions.status, 200)
    let executionsJSON = try jsonObject(executions)
    XCTAssertEqual(executionsJSON["instanceId"] as? String, identity)
    XCTAssertNotNil(executionsJSON["diagnostics"])
    XCTAssertEqual(executionsJSON["truncated"] as? Bool, false)
    XCTAssertFalse(String(data: executions.body, encoding: .utf8)?.contains(secret) ?? true)

    let doubleEncoded = encodePathSegment(encodedIdentity)
    let unmatched = await router.response(
      for: try parseRawRequest(path: "/api/v1/instances/\(doubleEncoded)")
    )
    XCTAssertEqual(unmatched.status, 404)

    for path in [
      "/api/v1/instances/%ZZ",
      "/api/v1/instances/%ZZ/configuration",
      "/api/v1/instances/%ZZ/executions"
    ] {
      let method = path.hasSuffix("configuration") ? "PUT" : "GET"
      let invalid = await fixture.app.webAPIResponse(
        for: RielaHTTPRequest(method: method, path: path),
        csrfToken: "csrf"
      )
      XCTAssertEqual(invalid.status, 404)
    }
  }

  func testRunEndpointsProjectPersistedStepLogsAndFailClosedForFreeformText() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let workflowDirectory = fixture.root.appendingPathComponent("workflow", isDirectory: true)
    let nodeDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let promptDirectory = workflowDirectory.appendingPathComponent("prompts", isDirectory: true)
    try FileManager.default.createDirectory(at: nodeDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
    try Data("""
      {
        "workflowId": "review-loop",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "nodes": [{ "id": "reviewer", "nodeFile": "nodes/reviewer.json" }],
        "steps": [{ "id": "review", "nodeId": "reviewer", "role": "worker" }]
      }
      """.utf8).write(to: workflowDirectory.appendingPathComponent("workflow.json"))
    try Data("""
      {
        "id": "reviewer",
        "executionBackend": "codex-agent",
        "model": "gpt-5.6",
        "promptTemplateFile": "prompts/reviewer.md",
        "variables": {}
      }
      """.utf8).write(to: nodeDirectory.appendingPathComponent("reviewer.json"))
    try Data("Review".utf8).write(to: promptDirectory.appendingPathComponent("reviewer.md"))

    let sessionStore = fixture.root.appendingPathComponent("sessions", isDirectory: true)
    fixture.app.webSessionStoreRootOverride = sessionStore.path
    let now = Date()
    let session = WorkflowSession(
      workflowId: "review-loop",
      sessionId: "session-web-detail",
      status: .completed,
      entryStepId: "review",
      createdAt: now,
      updatedAt: now,
      executions: [
        WorkflowStepExecution(
          executionId: "execution-review",
          stepId: "review",
          nodeId: "reviewer",
          attempt: 1,
          status: .completed,
          failureReason: "unlabeled-value-7Ta91Kp2Lm4N6Qr8",
          createdAt: now,
          updatedAt: now
        )
      ]
    )
    let message = WorkflowMessageRecord(
      communicationId: "comm-web-detail",
      workflowExecutionId: session.sessionId,
      fromStepId: "review",
      toStepId: "complete",
      sourceStepExecutionId: "execution-review",
      payload: ["private": .string("payload-canary-7Ta91Kp2Lm4N6Qr8")],
      lifecycleStatus: .delivered,
      createdOrder: 1,
      createdAt: now
    )
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: sessionStore.appendingPathComponent("runtime-records", isDirectory: true).path
    ).save(WorkflowRuntimePersistenceSnapshot(
      session: session,
      workflowMessages: [message],
      diagnostics: [
        "diagnostic-canary-7Ta91Kp2Lm4N6Qr8",
        "hunter2",
        "correcthorsebatterystaple",
        "12345678",
        "workflow validation failed"
      ]
    ))

    let executionsResponse = await fixture.app.webAPIResponse(
      for: RielaHTTPRequest(
        method: "GET",
        path: "/api/v1/instances/\(encodePathSegment(identity))/executions"
      ),
      csrfToken: "csrf"
    )
    XCTAssertEqual(executionsResponse.status, 200)
    let executionsJSON = try jsonObject(executionsResponse)
    let executionDiagnostics = try XCTUnwrap(executionsJSON["diagnostics"] as? [String])
    XCTAssertEqual(
      Array(executionDiagnostics.dropLast()),
      Array(repeating: "<redacted>", count: 4)
    )
    XCTAssertEqual(executionDiagnostics.last, "workflow validation failed")
    let executionsBody = String(data: executionsResponse.body, encoding: .utf8) ?? ""
    for canary in [
      "diagnostic-canary-7Ta91Kp2Lm4N6Qr8",
      "hunter2",
      "correcthorsebatterystaple",
      "12345678"
    ] {
      XCTAssertFalse(executionsBody.contains(canary))
    }

    let response = await fixture.app.webAPIResponse(
      for: RielaHTTPRequest(
        method: "GET",
        path: "/api/v1/instances/\(encodePathSegment(identity))/executions/\(session.sessionId)"
      ),
      csrfToken: "csrf"
    )
    XCTAssertEqual(response.status, 200)
    let json = try jsonObject(response)
    XCTAssertEqual(json["logsTotalCount"] as? Int, 1)
    XCTAssertEqual(json["logsTruncated"] as? Bool, false)
    XCTAssertEqual(json["stepsTotalCount"] as? Int, 1)
    let logs = try XCTUnwrap(json["logs"] as? [[String: Any]])
    XCTAssertEqual(logs.first?["communicationId"] as? String, "comm-web-detail")
    XCTAssertEqual(logs.first?["communicationIdTruncated"] as? Bool, false)
    let diagnostics = try XCTUnwrap(json["diagnostics"] as? [[String: Any]])
    XCTAssertEqual(
      diagnostics.dropLast().compactMap { $0["summary"] as? String },
      Array(repeating: "<redacted>", count: 4)
    )
    XCTAssertEqual(diagnostics.last?["summary"] as? String, "workflow validation failed")
    XCTAssertLessThanOrEqual(response.body.count, WorkflowWebProjectionPolicy.runDetailResponseLimit)
    let body = String(data: response.body, encoding: .utf8) ?? ""
    XCTAssertFalse(body.contains("payload-canary"))
    XCTAssertFalse(body.contains("diagnostic-canary"))
    XCTAssertFalse(body.contains("unlabeled-value"))
    XCTAssertFalse(body.contains("hunter2"))
    XCTAssertFalse(body.contains("correcthorsebatterystaple"))
    XCTAssertFalse(body.contains("12345678"))
    XCTAssertTrue(body.contains("<redacted>"))
  }

  func testMissingSourceInstanceIsVisibleAndRedacted() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let missingIdentity = "removed-workflow"
    fixture.app.daemonState.preferences[missingIdentity] = RielaAppDaemonWorkflowPreference(
      identity: missingIdentity,
      sourceIdentity: "removed-source",
      available: false,
      active: false,
      environmentVariables: ["MISSING_SECRET": secret]
    )

    let response = await fixture.app.webAPIResponse(
      for: RielaHTTPRequest(method: "GET", path: "/api/v1/instances"),
      csrfToken: "csrf"
    )
    XCTAssertEqual(response.status, 200)
    let items = try XCTUnwrap(try jsonObject(response)["items"] as? [[String: Any]])
    let missing = try XCTUnwrap(items.first(where: { $0["id"] as? String == missingIdentity }))
    XCTAssertEqual(missing["status"] as? String, "needsSource")
    XCTAssertEqual(missing["sourceKind"] as? String, "missing")
    XCTAssertFalse(String(data: response.body, encoding: .utf8)?.contains(secret) ?? true)
  }

  func testInstancesExposeTypedNodePatchesAndDefinitionsUseSourceScopedProjection() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    fixture.app.daemonState.preferences[identity]?.nodePatches = [
      "review": WorkflowInstanceNodePatch(
        executionBackend: .codexAgent,
        model: "gpt-5.6",
        effort: .high
      )
    ]
    fixture.app.daemonInstances = fixture.app.daemonInstances.map { instance in
      guard var preference = fixture.app.daemonState.preferences[instance.identity] else {
        return instance
      }
      preference.nodePatches = fixture.app.daemonState.preferences[instance.identity]?.nodePatches ?? [:]
      return .configured(identity: instance.identity, source: instance.source, preference: preference)
    }
    let instances = await fixture.app.webAPIResponse(
      for: RielaHTTPRequest(method: "GET", path: "/api/v1/instances"),
      csrfToken: "csrf"
    )
    let items = try XCTUnwrap(try jsonObject(instances)["items"] as? [[String: Any]])
    let projected = try XCTUnwrap(items.first?["nodePatches"] as? [String: [String: Any]])
    XCTAssertEqual(projected["review"]?["executionBackend"] as? String, "codex-agent")
    XCTAssertEqual(projected["review"]?["model"] as? String, "gpt-5.6")
    XCTAssertEqual(projected["review"]?["effort"] as? String, "high")

    let workflowDirectory = fixture.root.appendingPathComponent("workflow", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try Data("""
      {
        "workflowId": "review-loop",
        "description": "Review token=\(secret)",
        "environment": { "API_KEY": "ENVIRONMENT_SECRET_CANARY" },
        "prompt": "PROMPT_SECRET_CANARY",
        "addons": [{ "configuration": "ADDON_SECRET_CANARY" }],
        "command": { "argv": ["COMMAND_SECRET_CANARY"] },
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "review",
        "nodes": [{ "id": "reviewer", "nodeFile": "nodes/reviewer.json" }],
        "steps": [{ "id": "review", "nodeId": "reviewer", "role": "worker" }]
      }
      """.utf8).write(to: workflowDirectory.appendingPathComponent("workflow.json"))

    let definition = await fixture.app.webAPIResponse(
      for: RielaHTTPRequest(
        method: "GET",
        path: "/api/v1/workflows/sources/source-review-loop/definition"
      ),
      csrfToken: "csrf"
    )
    XCTAssertEqual(definition.status, 200)
    let definitionJSON = try jsonObject(definition)
    XCTAssertEqual(definitionJSON["workflowId"] as? String, "review-loop")
    XCTAssertEqual(definitionJSON["workflowIdTruncated"] as? Bool, false)
    XCTAssertEqual(definitionJSON["sourceIdTruncated"] as? Bool, false)
    let projectedDefinition = try XCTUnwrap(definitionJSON["definition"] as? [String: Any])
    XCTAssertEqual(projectedDefinition["stepsTotalCount"] as? Int, 1)
    XCTAssertEqual(projectedDefinition["stepsTruncated"] as? Bool, false)
    XCTAssertEqual((definitionJSON["definitionRevision"] as? String)?.count, 64)
    XCTAssertLessThanOrEqual(definition.body.count, WorkflowWebProjectionPolicy.definitionResponseLimit)
    let body = String(data: definition.body, encoding: .utf8) ?? ""
    XCTAssertFalse(body.contains(workflowDirectory.path))
    XCTAssertFalse(body.contains(secret))
    XCTAssertFalse(body.contains("ENVIRONMENT_SECRET_CANARY"))
    XCTAssertFalse(body.contains("PROMPT_SECRET_CANARY"))
    XCTAssertFalse(body.contains("ADDON_SECRET_CANARY"))
    XCTAssertFalse(body.contains("COMMAND_SECRET_CANARY"))
  }

  func testEncodedConfigurationUpdatePreservesBlankSecretsAndSupportsExplicitClear() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let path = "/api/v1/instances/\(encodePathSegment(identity))/configuration"

    let update = await fixture.app.webAPIResponse(
      for: try request(path: path, body: [
        "expectedRevision": 1,
        "expectedProfile": fixture.app.daemonProfileName.rawValue,
        "workingDirectory": "/tmp/updated",
        "environmentVariableUpdates": ["API_KEY": "", "OTHER_KEY": "replacement"],
        "environmentVariablesToClear": ["CLEAR_KEY"]
      ]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(update.status, 200)
    XCTAssertFalse(String(data: update.body, encoding: .utf8)?.contains(secret) ?? true)
    XCTAssertEqual(fixture.app.daemonState.preferences[identity]?.environmentVariables["API_KEY"], secret)
    XCTAssertEqual(fixture.app.daemonState.preferences[identity]?.environmentVariables["OTHER_KEY"], "replacement")
    XCTAssertNil(fixture.app.daemonState.preferences[identity]?.environmentVariables["CLEAR_KEY"])

    let conflict = await fixture.app.webAPIResponse(
      for: try request(path: path, body: [
        "expectedRevision": 1,
        "expectedProfile": fixture.app.daemonProfileName.rawValue
      ]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(conflict.status, 409)
    let conflictError = try XCTUnwrap(try jsonObject(conflict)["error"] as? [String: Any])
    XCTAssertEqual(conflictError["code"] as? String, "revision_conflict")
  }

  func testConfigurationUpdateRejectsStaleProfileBeforeMutatingSameIdentity() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let path = "/api/v1/instances/\(encodePathSegment(identity))/configuration"
    let original = fixture.app.daemonState.preferences[identity]

    let conflict = await fixture.app.webAPIResponse(
      for: try request(path: path, body: [
        "expectedRevision": fixture.app.webRevision,
        "expectedProfile": "previous-profile",
        "workingDirectory": "/tmp/wrong-profile",
        "environmentVariableUpdates": ["API_KEY": "wrong-profile-secret"],
        "workflowVariables": ["owner": "previous-profile"]
      ]),
      csrfToken: "csrf"
    )

    XCTAssertEqual(conflict.status, 409)
    let conflictError = try XCTUnwrap(try jsonObject(conflict)["error"] as? [String: Any])
    XCTAssertEqual(conflictError["code"] as? String, "profile_conflict")
    XCTAssertEqual(fixture.app.webRevision, 1)
    XCTAssertEqual(fixture.app.daemonState.preferences[identity], original)
  }

  func testProfileOwnedSettingsAndSourcesRejectStaleProfileBeforeMutation() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let currentProfile = fixture.app.daemonProfileName.rawValue
    let originalDirectories = fixture.app.daemonState.workflowDirectories
    let originalAssistant = fixture.app.daemonState.assistant
    let noteStore = RielaAppNoteSettingsStore(
      noteRoot: fixture.app.noteRootURL(profileName: fixture.app.daemonProfileName)
    )
    let originalNoteSettings = noteStore.load()

    for path in [
      "/api/v1/workflows/sources",
      "/api/v1/settings/assistant",
      "/api/v1/settings/notes"
    ] {
      let response = await fixture.app.webAPIResponse(
        for: RielaHTTPRequest(method: "GET", path: path),
        csrfToken: "csrf"
      )
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(try jsonObject(response)["profile"] as? String, currentProfile)
    }

    let staleSource = await fixture.app.webAPIResponse(
      for: RielaHTTPRequest(
        method: "POST",
        path: "/api/v1/workflows/sources/directories",
        headers: ["Content-Type": "application/json"],
        body: try JSONSerialization.data(withJSONObject: [
          "expectedRevision": fixture.app.webRevision,
          "expectedProfile": "previous-profile",
          "path": fixture.root.appendingPathComponent("wrong-profile-workflows").path
        ])
      ),
      csrfToken: "csrf"
    )
    XCTAssertEqual(staleSource.status, 409)
    XCTAssertEqual(
      (try jsonObject(staleSource)["error"] as? [String: Any])?["code"] as? String,
      "profile_conflict"
    )
    XCTAssertEqual(fixture.app.daemonState.workflowDirectories, originalDirectories)

    let staleAssistant = await fixture.app.webAPIResponse(
      for: try request(path: "/api/v1/settings/assistant", body: [
        "expectedRevision": fixture.app.webRevision,
        "expectedProfile": "previous-profile",
        "assistance": "wrong-profile-assistance",
        "model": "wrong-profile-model"
      ]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(staleAssistant.status, 409)
    XCTAssertEqual(
      (try jsonObject(staleAssistant)["error"] as? [String: Any])?["code"] as? String,
      "profile_conflict"
    )
    XCTAssertEqual(fixture.app.daemonState.assistant.assistance, originalAssistant.assistance)
    XCTAssertEqual(fixture.app.daemonState.assistant.vendor, originalAssistant.vendor)
    XCTAssertEqual(fixture.app.daemonState.assistant.normalizedModel, originalAssistant.normalizedModel)

    let staleNotes = await fixture.app.webAPIResponse(
      for: try request(path: "/api/v1/settings/notes", body: [
        "expectedRevision": fixture.app.webRevision,
        "expectedProfile": "previous-profile",
        "exposesNoteAPI": !originalNoteSettings.exposesNoteAPI
      ]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(staleNotes.status, 409)
    XCTAssertEqual(
      (try jsonObject(staleNotes)["error"] as? [String: Any])?["code"] as? String,
      "profile_conflict"
    )
    XCTAssertEqual(noteStore.load().exposesNoteAPI, originalNoteSettings.exposesNoteAPI)
    XCTAssertEqual(fixture.app.webRevision, 1)
  }

  func testRouterRejectsMutationWithoutCSRFHeaders() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let router = RielaAppWebRouter(app: fixture.app, assetRoot: fixture.root, configuredPort: 19_091)
    let response = await router.response(for: RielaHTTPRequest(
      method: "PUT",
      path: "/api/v1/instances/\(encodePathSegment(identity))/configuration",
      headers: [
        "Host": "127.0.0.1:19091",
        "Origin": "http://127.0.0.1:19091",
        "Content-Type": "application/json"
      ],
      body: try JSONSerialization.data(withJSONObject: ["expectedRevision": 1])
    ))
    XCTAssertEqual(response.status, 403)
  }

  func testGraphQLUsesCurrentProfileAndRejectsStaleSameIdentifierMutation() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let router = RielaAppWebRouter(app: fixture.app, assetRoot: fixture.root, configuredPort: 19_091)
    let defaultService = try NoteService(
      driver: SQLiteNoteDatabaseDriver(
        noteRoot: try prepareNoteRoot(for: fixture.app, profileName: .default).path
      )
    )
    _ = try defaultService.createNotebook(title: "Default profile notebook")

    let missingCSRF = await router.response(for: graphQLRequest(csrfToken: nil))
    XCTAssertEqual(missingCSRF.status, 403)
    let defineFolderQuery = """
      mutation DefineFolder($input: DefineNoteTagInput!) {
        defineNoteTag(input: $input) {
          result { accepted status diagnostics }
          tag { tagId name classId }
        }
      }
      """
    let sharedInput: [String: Any] = [
      "input": [
        "name": "profile-bound-folder",
        "classId": "folder",
        "createOnly": true
      ]
    ]
    var response = await router.response(for: graphQLRequest(csrfToken: router.csrfToken))
    XCTAssertTrue(String(data: response.body, encoding: .utf8)?.contains("Default profile notebook") == true)
    response = await router.response(for: graphQLRequest(
      csrfToken: router.csrfToken,
      query: defineFolderQuery,
      operationName: "DefineFolder",
      variables: sharedInput
    ))
    XCTAssertEqual(response.status, 200)
    XCTAssertTrue(String(data: response.body, encoding: .utf8)?.contains("profile-bound-folder") == true)

    fixture.app.daemonProfileName = RielaAppProfileName("second")
    let secondService = try NoteService(
      driver: SQLiteNoteDatabaseDriver(
        noteRoot: try prepareNoteRoot(
          for: fixture.app,
          profileName: fixture.app.daemonProfileName
        ).path
      )
    )
    _ = try secondService.createNotebook(title: "Second profile notebook")
    response = await router.response(for: graphQLRequest(
      csrfToken: router.csrfToken,
      query: defineFolderQuery,
      operationName: "DefineFolder",
      variables: sharedInput
    ))
    XCTAssertEqual(response.status, 409)
    XCTAssertEqual(try jsonObject(response)["error"] as? String, "profile_conflict")

    response = await router.response(for: graphQLRequest(
      csrfToken: router.csrfToken,
      profile: fixture.app.daemonProfileName.rawValue,
      query: "query Tags { tags { result { accepted } value { name } } }",
      operationName: "Tags"
    ))
    XCTAssertEqual(response.status, 200)
    XCTAssertFalse(
      String(data: response.body, encoding: .utf8)?.contains("profile-bound-folder") == true
    )

    response = await router.response(for: graphQLRequest(
      csrfToken: router.csrfToken,
      profile: fixture.app.daemonProfileName.rawValue
    ))
    let body = String(data: response.body, encoding: .utf8) ?? ""
    XCTAssertTrue(body.contains("Second profile notebook"), body)
    XCTAssertFalse(body.contains("Default profile notebook"), body)
  }

  func testGraphQLProfileBindingIsAtomicAcrossRouterInterleaving() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let secondProfile = RielaAppProfileName("second")
    _ = try NoteService(
      driver: SQLiteNoteDatabaseDriver(
        noteRoot: try prepareNoteRoot(for: fixture.app, profileName: secondProfile).path
      )
    )
    let router = RielaAppWebRouter(
      app: fixture.app,
      assetRoot: fixture.root,
      configuredPort: 19_091,
      beforeGraphQLProfileBinding: {
        fixture.app.daemonProfileName = secondProfile
      }
    )
    let defineFolderQuery = """
      mutation DefineFolder($input: DefineNoteTagInput!) {
        defineNoteTag(input: $input) {
          result { accepted status diagnostics }
          tag { tagId name classId }
        }
      }
      """
    let response = await router.response(for: graphQLRequest(
      csrfToken: router.csrfToken,
      query: defineFolderQuery,
      operationName: "DefineFolder",
      variables: [
        "input": [
          "name": "atomic-profile-folder",
          "classId": "folder",
          "createOnly": true
        ]
      ]
    ))
    XCTAssertEqual(fixture.app.daemonProfileName, secondProfile)
    XCTAssertEqual(response.status, 409)
    XCTAssertEqual(try jsonObject(response)["error"] as? String, "profile_conflict")

    let inspectionRouter = RielaAppWebRouter(
      app: fixture.app,
      assetRoot: fixture.root,
      configuredPort: 19_091
    )
    let tags = await inspectionRouter.response(for: graphQLRequest(
      csrfToken: inspectionRouter.csrfToken,
      profile: secondProfile.rawValue,
      query: "query Tags { tags { result { accepted } value { name } } }",
      operationName: "Tags"
    ))
    XCTAssertEqual(tags.status, 200)
    XCTAssertFalse(
      String(data: tags.body, encoding: .utf8)?.contains("atomic-profile-folder") == true
    )
  }

  func testGraphQLRegistryBridgeAuthorizesOnlyAfterTheWebSecurityGate() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let router = RielaAppWebRouter(app: fixture.app, assetRoot: fixture.root, configuredPort: 19_091)
    let query = """
      query WebRegistry {
        workflows(filter: {scope: USER, provenance: MUTABLE}) {
          workflows { workflowId }
          errors { code message }
        }
      }
      """
    await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.root.path]) {
      let rejected = await router.response(for: graphQLRequest(
        host: "localhost:19091",
        csrfToken: router.csrfToken,
        query: query,
        operationName: "WebRegistry"
      ))
      XCTAssertEqual(rejected.status, 403)

      let accepted = await router.response(for: graphQLRequest(
        csrfToken: router.csrfToken,
        query: query,
        operationName: "WebRegistry"
      ))
      XCTAssertEqual(accepted.status, 200)
      let body = String(data: accepted.body, encoding: .utf8) ?? ""
      XCTAssertTrue(body.contains("\"workflows\""), body)
      XCTAssertFalse(body.contains(WorkflowRegistryErrorCode.unauthenticated.rawValue), body)
      XCTAssertFalse(body.contains(WorkflowRegistryErrorCode.forbidden.rawValue), body)
    }
  }

  func testGraphQLSecurityPolicyRejectsBeforeExecutorConstruction() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let blockedHome = fixture.root.appendingPathComponent("blocked-home")
    try Data("not a directory".utf8).write(to: blockedHome)
    fixture.app.appHomeDirectory = blockedHome
    let router = RielaAppWebRouter(app: fixture.app, assetRoot: fixture.root, configuredPort: 19_091)

    try await assertGraphQLSecurityRejection(
      router,
      request: graphQLRequest(host: "localhost:19091", csrfToken: router.csrfToken),
      status: 403,
      error: "invalid_host"
    )
    try await assertGraphQLSecurityRejection(
      router,
      request: graphQLRequest(origin: "http://localhost:19091", csrfToken: router.csrfToken),
      status: 403,
      error: "invalid_origin"
    )
    try await assertGraphQLSecurityRejection(
      router,
      request: graphQLRequest(csrfToken: nil),
      status: 403,
      error: "invalid_csrf"
    )
    try await assertGraphQLSecurityRejection(
      router,
      request: graphQLRequest(csrfToken: "wrong"),
      status: 403,
      error: "invalid_csrf"
    )
    try await assertGraphQLSecurityRejection(
      router,
      request: graphQLRequest(csrfToken: router.csrfToken, contentType: nil),
      status: 415,
      error: "json_content_type_required"
    )
    try await assertGraphQLSecurityRejection(
      router,
      request: graphQLRequest(csrfToken: router.csrfToken, contentType: "text/plain"),
      status: 415,
      error: "json_content_type_required"
    )
  }

  func testGraphQLConstructionFailureIsSanitizedAndOtherRoutesRemainAvailable() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("<main>Dashboard</main>".utf8).write(
      to: fixture.root.appendingPathComponent("index.html")
    )
    let blockedHome = fixture.root.appendingPathComponent("blocked-home")
    try Data("not a directory".utf8).write(to: blockedHome)
    fixture.app.appHomeDirectory = blockedHome
    let router = RielaAppWebRouter(app: fixture.app, assetRoot: fixture.root, configuredPort: 19_091)

    let unavailable = await router.response(for: graphQLRequest(csrfToken: router.csrfToken))
    XCTAssertEqual(unavailable.status, 503)
    let unavailableJSON = try jsonObject(unavailable)
    XCTAssertEqual(unavailableJSON["error"] as? String, "note_graphql_unavailable")
    XCTAssertEqual(
      unavailableJSON["message"] as? String,
      "The active profile's Notes service is unavailable."
    )
    let unavailableBody = String(data: unavailable.body, encoding: .utf8) ?? ""
    XCTAssertFalse(unavailableBody.contains(blockedHome.path), unavailableBody)
    XCTAssertFalse(unavailableBody.localizedCaseInsensitiveContains("sqlite"), unavailableBody)

    let apiResponse = await router.response(for: RielaHTTPRequest(
      method: "GET",
      path: "/api/v1/instances",
      headers: ["Host": "127.0.0.1:19091"]
    ))
    XCTAssertEqual(apiResponse.status, 200)
    let staticResponse = await router.response(for: RielaHTTPRequest(method: "GET", path: "/"))
    XCTAssertEqual(staticResponse.status, 200)
    XCTAssertEqual(staticResponse.body, Data("<main>Dashboard</main>".utf8))
  }

  private func makeFixture() throws -> (app: RielaApp, root: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let app = RielaApp()
    app.appHomeDirectory = root
    app.profileStore = RielaAppProfileStore(appRootURL: root)
    try app.profileStore.prepareInitialProfile(.default, persistsSelection: false)
    _ = try prepareNoteRoot(for: app, profileName: .default)
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "source-review-loop",
      workflowId: "review-loop",
      displayName: "Review loop",
      sourceDescription: "project workflow",
      workflowDirectory: root.appendingPathComponent("workflow", isDirectory: true).path,
      workingDirectory: root.path,
      eventRoot: nil,
      eventSources: [],
      requiredEnvironment: [RielaAppEnvRequirement(name: "API_KEY", description: "Provider credential", secret: true)]
    )
    let preference = RielaAppDaemonWorkflowPreference(
      identity: identity,
      sourceIdentity: candidate.id,
      available: true,
      active: false,
      environmentVariables: ["API_KEY": secret, "CLEAR_KEY": "remove-me"]
    )
    app.daemonState = RielaAppDaemonWorkflowState(preferences: [identity: preference])
    app.daemonWorkflowSources = [candidate]
    app.daemonCandidates = [candidate]
    app.daemonInstances = [.configured(identity: identity, source: candidate, preference: preference)]
    return (app, root)
  }

  private func prepareNoteRoot(
    for app: RielaApp,
    profileName: RielaAppProfileName
  ) throws -> URL {
    let noteRoot = app.noteRootURL(profileName: profileName)
    try FileManager.default.createDirectory(at: noteRoot, withIntermediateDirectories: true)
    return noteRoot
  }

  private func assertGraphQLSecurityRejection(
    _ router: RielaAppWebRouter,
    request: RielaHTTPRequest,
    status: Int,
    error: String
  ) async throws {
    let response = await router.response(for: request)
    XCTAssertEqual(response.status, status, error)
    XCTAssertEqual(try jsonObject(response)["error"] as? String, error)
  }

  private func request(path: String, body: [String: Any]) throws -> RielaHTTPRequest {
    RielaHTTPRequest(
      method: "PUT",
      path: path,
      headers: ["Content-Type": "application/json"],
      body: try JSONSerialization.data(withJSONObject: body)
    )
  }

  private func graphQLRequest(
    host: String? = "127.0.0.1:19091",
    origin: String? = "http://127.0.0.1:19091",
    csrfToken: String?,
    profile: String? = RielaAppProfileName.default.rawValue,
    contentType: String? = "application/json",
    query: String = "query WebNotebooks { notebooks(limit: 200, sort: title) { result { accepted } value { notebookId title } } }",
    operationName: String = "WebNotebooks",
    variables: [String: Any] = [:]
  ) -> RielaHTTPRequest {
    var headers: [String: String] = [:]
    if let host {
      headers["Host"] = host
    }
    if let origin {
      headers["Origin"] = origin
    }
    if let csrfToken {
      headers["X-Riela-CSRF"] = csrfToken
    }
    if let profile {
      headers["X-Riela-Profile"] = profile
    }
    if let contentType {
      headers["Content-Type"] = contentType
    }
    return RielaHTTPRequest(
      method: "POST",
      path: "/graphql",
      headers: headers,
      body: (try? JSONSerialization.data(withJSONObject: [
        "query": query,
        "operationName": operationName,
        "variables": variables
      ])) ?? Data()
    )
  }

  private func parseRawRequest(path: String) throws -> RielaHTTPRequest {
    let bytes = Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:19091\r\n\r\n".utf8)
    guard case let .complete(request) = try RielaHTTPRequestParser().parse(bytes) else {
      throw CocoaError(.fileReadUnknown)
    }
    return request
  }

  private func encodePathSegment(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private func jsonObject(_ response: RielaHTTPResponse) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }
}
#endif
