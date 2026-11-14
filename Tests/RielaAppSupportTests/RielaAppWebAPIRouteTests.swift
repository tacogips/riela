#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCore
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

  func testEncodedConfigurationUpdatePreservesBlankSecretsAndSupportsExplicitClear() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let path = "/api/v1/instances/\(encodePathSegment(identity))/configuration"

    let update = await fixture.app.webAPIResponse(
      for: try request(path: path, body: [
        "expectedRevision": 1,
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
      for: try request(path: path, body: ["expectedRevision": 1]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(conflict.status, 409)
    let conflictError = try XCTUnwrap(try jsonObject(conflict)["error"] as? [String: Any])
    XCTAssertEqual(conflictError["code"] as? String, "revision_conflict")
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

  private func makeFixture() throws -> (app: RielaApp, root: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let app = RielaApp()
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

  private func request(path: String, body: [String: Any]) throws -> RielaHTTPRequest {
    RielaHTTPRequest(
      method: "PUT",
      path: path,
      headers: ["Content-Type": "application/json"],
      body: try JSONSerialization.data(withJSONObject: body)
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
