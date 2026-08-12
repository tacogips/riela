#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCLI
import RielaCore
import RielaServer
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppWebAPIRouteTests: XCTestCase {
  private let identity = "project-workflow:/tmp/riela:review-loop"
  private let secret = "SENTINEL_SECRET_MUST_NOT_RENDER"

  func testPrivateAssistantPromptRequiresSessionEvidence() {
    let prompt = RielaApp().assistantSystemPrompt(workingDirectory: "/tmp/project")
    XCTAssertTrue(prompt.contains("Use RIELA_SESSION_STORE."))
    XCTAssertTrue(prompt.contains("must include the session ID and a link"))
    XCTAssertTrue(prompt.contains("RIELA_WEB_RUN_LINK_TEMPLATE"))
  }

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

  func testGlobalExecutionDetailLoadsProfileSessionWithoutWorkflowDefinitionOrInstance() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let sessionStore = fixture.root.appendingPathComponent("private-sessions", isDirectory: true)
    fixture.app.webSessionStoreRootOverride = sessionStore.path
    let now = Date()
    let session = WorkflowSession(
      workflowId: String(repeating: "private-workflow-", count: 32),
      sessionId: "private-session",
      status: .running,
      entryStepId: "work",
      currentStepId: "review",
      createdAt: now,
      updatedAt: now
    )
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: sessionStore.appendingPathComponent("runtime-records", isDirectory: true).path
    ).save(WorkflowRuntimePersistenceSnapshot(session: session))

    let response = await fixture.app.webAPIResponse(
      for: RielaHTTPRequest(method: "GET", path: "/api/v1/executions/private-session"),
      csrfToken: "csrf"
    )
    XCTAssertEqual(response.status, 200)
    let json = try jsonObject(response)
    XCTAssertEqual(json["instanceId"] as? String, "private")
    let returnedSession = try XCTUnwrap(json["session"] as? [String: Any])
    XCTAssertEqual(returnedSession["sessionId"] as? String, "private-session")
    XCTAssertEqual(returnedSession["status"] as? String, "running")
    XCTAssertEqual(returnedSession["currentStepId"] as? String, "review")
    XCTAssertEqual(returnedSession["workflowIdTruncated"] as? Bool, true)
    XCTAssertFalse(String(data: response.body, encoding: .utf8)?.contains(session.workflowId) ?? true)
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

  func testGraphQLConfigurationUpdatePreservesBlankSecretsAndSupportsExplicitClear() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let router = RielaAppWebRouter(app: fixture.app, assetRoot: fixture.root, configuredPort: 19_091)
    let mutation = """
      mutation Update($input: WorkflowInstanceConfigurationInput!) {
        updateWorkflowInstanceConfiguration(input: $input) { profile revision }
      }
      """
    let input: [String: Any] = [
      "expectedRevision": 1,
      "expectedProfile": fixture.app.daemonProfileName.rawValue,
      "identity": identity,
      "workingDirectory": "/tmp/updated",
      "environmentVariableUpdates": ["API_KEY": "", "OTHER_KEY": "replacement"],
      "environmentVariablesToClear": ["CLEAR_KEY"]
    ]
    let update = await router.response(for: graphQLRequest(
      csrfToken: router.csrfToken,
      query: mutation,
      operationName: "Update",
      variables: ["input": input]
    ))
    XCTAssertEqual(update.status, 200)
    XCTAssertFalse(String(data: update.body, encoding: .utf8)?.contains(secret) ?? true)
    XCTAssertEqual(fixture.app.daemonState.preferences[identity]?.environmentVariables["API_KEY"], secret)
    XCTAssertEqual(fixture.app.daemonState.preferences[identity]?.environmentVariables["OTHER_KEY"], "replacement")
    XCTAssertNil(fixture.app.daemonState.preferences[identity]?.environmentVariables["CLEAR_KEY"])

    let conflict = await router.response(for: graphQLRequest(
      csrfToken: router.csrfToken,
      query: mutation,
      operationName: "Update",
      variables: ["input": input]
    ))
    let errors = try XCTUnwrap(try jsonObject(conflict)["errors"] as? [[String: Any]])
    XCTAssertEqual((errors.first?["extensions"] as? [String: Any])?["code"] as? String, "REVISION_CONFLICT")
  }

  func testConfigurationUpdateRejectsStaleProfileBeforeMutatingSameIdentity() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = fixture.app.daemonState.preferences[identity]
    let router = RielaAppWebRouter(app: fixture.app, assetRoot: fixture.root, configuredPort: 19_091)
    let conflict = await router.response(for: graphQLRequest(
      csrfToken: router.csrfToken,
      profile: "previous-profile",
      query: "mutation Update($input: WorkflowInstanceConfigurationInput!) { updateWorkflowInstanceConfiguration(input: $input) { revision } }",
      operationName: "Update",
      variables: ["input": [
        "expectedRevision": fixture.app.webRevision,
        "expectedProfile": "previous-profile",
        "identity": identity,
        "workingDirectory": "/tmp/wrong-profile"
      ]]
    ))

    XCTAssertEqual(conflict.status, 409)
    XCTAssertEqual(try jsonObject(conflict)["error"] as? String, "profile_conflict")
    XCTAssertEqual(fixture.app.webRevision, 1)
    XCTAssertEqual(fixture.app.daemonState.preferences[identity], original)
  }

  func testConfigurationQueryIsGraphQLOnly() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let router = RielaAppWebRouter(app: fixture.app, assetRoot: fixture.root, configuredPort: 19_091)
    let response = await router.response(for: graphQLRequest(
      csrfToken: router.csrfToken,
      query: "query Config { configuration { profile revision profiles workflowDirectories assistant { vendor model } } }",
      operationName: "Config"
    ))
    XCTAssertEqual(response.status, 200)
    let data = try XCTUnwrap(try jsonObject(response)["data"] as? [String: Any])
    let configuration = try XCTUnwrap(data["configuration"] as? [String: Any])
    XCTAssertEqual(configuration["profile"] as? String, fixture.app.daemonProfileName.rawValue)
    for path in ["/api/v1/settings/assistant", "/api/v1/settings/appearance", "/api/v1/settings/web-server"] {
      let legacy = await fixture.app.webAPIResponse(for: RielaHTTPRequest(method: "GET", path: path), csrfToken: "csrf")
      XCTAssertEqual(legacy.status, 404)
    }
  }

  func testRouterRejectsMutationWithoutCSRFHeaders() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let router = RielaAppWebRouter(app: fixture.app, assetRoot: fixture.root, configuredPort: 19_091)
    let response = await router.response(for: graphQLRequest(
      csrfToken: nil,
      query: "mutation Update($input: WorkflowInstanceConfigurationInput!) { updateWorkflowInstanceConfiguration(input: $input) { revision } }",
      operationName: "Update",
      variables: ["input": [
        "expectedRevision": 1,
        "expectedProfile": fixture.app.daemonProfileName.rawValue,
        "identity": identity
      ]]
    ))
    XCTAssertEqual(response.status, 403)
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

  private func makeFixture() throws -> (app: RielaApp, root: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let app = RielaApp()
    app.appHomeDirectory = root
    app.profileStore = RielaAppProfileStore(appRootURL: root)
    try app.profileStore.prepareInitialProfile(.default, persistsSelection: false)
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
