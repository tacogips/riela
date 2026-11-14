import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaKaibaSupport

final class KaibaInstanceCommandTests: XCTestCase {
  func testFixedFailureMatrixAndDefaultLifecycleContracts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let environment = ["HOME": home.path]
    let app = RielaCLIApplication()

    await assertFailureCode("kaiba_instance_not_found", app, ["kaiba", "instance", "show", "missing"], environment)
    await assertFailureCode(
      "invalid_kaiba_instance_name",
      app,
      ["kaiba", "instance", "add", "bad\nname", "--endpoint", "https://localhost", "--allow-unauthenticated"],
      environment
    )
    await assertFailureCode(
      "invalid_endpoint",
      app,
      ["kaiba", "instance", "add", "Bad endpoint", "--endpoint", "ftp://localhost", "--allow-unauthenticated"],
      environment
    )
    await assertFailureCode(
      "invalid_authentication_policy",
      app,
      ["kaiba", "instance", "add", "Bad auth", "--endpoint", "https://localhost", "--api-key-env", "TOKEN", "--allow-unauthenticated"],
      environment
    )

    let firstID = try await addInstance(named: "Alpha", app: app, environment: environment)
    let secondID = try await addInstance(named: "Beta", app: app, environment: environment)
    await assertFailureCode(
      "duplicate_kaiba_instance_name",
      app,
      ["kaiba", "instance", "add", "alpha", "--endpoint", "https://localhost", "--allow-unauthenticated"],
      environment
    )
    await assertFailureCode(
      "default_replacement_required",
      app,
      ["kaiba", "instance", "remove", firstID],
      environment
    )

    let selected = await app.run(
      ["kaiba", "instance", "set-default", secondID, "--output", "json"],
      environment: environment
    )
    XCTAssertEqual(selected.exitCode, .success, selected.stderr)
    let disabled = await app.run(
      ["kaiba", "instance", "update", firstID, "--disable", "--output", "json"],
      environment: environment
    )
    XCTAssertEqual(disabled.exitCode, .success, disabled.stderr)
    await assertFailureCode(
      "disabled_kaiba_instance",
      app,
      ["kaiba", "instance", "set-default", firstID],
      environment
    )

    let project = root.appendingPathComponent("project", isDirectory: true)
    let malformed = project.appendingPathComponent(".riela/workflows/broken/workflow.json")
    try FileManager.default.createDirectory(
      at: malformed.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{".utf8).write(to: malformed)
    await assertFailureCode(
      "kaiba_binding_scan_failed",
      app,
      ["kaiba", "instance", "remove", firstID, "--working-dir", project.path],
      environment
    )

    let invalidHome = root.appendingPathComponent("invalid-home", isDirectory: true)
    let catalogURL = invalidHome.appendingPathComponent(".riela/kaiba/instances.json")
    try FileManager.default.createDirectory(
      at: catalogURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: catalogURL)
    await assertFailureCode(
      "invalid_kaiba_instance_store",
      app,
      ["kaiba", "instance", "list"],
      ["HOME": invalidHome.path]
    )
    await assertFailureCode(
      "kaiba_instance_store_unavailable",
      app,
      ["kaiba", "instance", "add", "Unavailable", "--endpoint", "https://localhost", "--allow-unauthenticated"],
      ["HOME": "/dev/null"]
    )
  }

  func testReadinessFailureMatrixAndStaleCompletion() async throws {
    for expectation in [
      (KaibaInstanceLastTestStatus.authFailed, "auth_failed"),
      (.connectionFailed, "connection_failed"),
      (.incompatible, "incompatible_kaiba_instance")
    ] {
      let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: home) }
      let environment = ["HOME": home.path]
      let app = RielaCLIApplication(
        kaibaInstanceCommandRunner: KaibaInstanceCommandRunner { _, _ in
          KaibaInstanceLastTest(status: expectation.0, code: expectation.1, attemptedAt: Date())
        }
      )
      let id = try await addInstance(named: "Probe", app: app, environment: environment)
      await assertFailureCode(
        expectation.1,
        app,
        ["kaiba", "instance", "test", id],
        environment
      )
    }

    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let environment = ["HOME": home.path]
    let staleApp = RielaCLIApplication(
      kaibaInstanceCommandRunner: KaibaInstanceCommandRunner { instance, _ in
        let store = KaibaInstanceStore(homeURL: home)
        _ = try store.mutate { catalog in
          var updated = catalog
          let index = try XCTUnwrap(
            updated.instances.firstIndex { $0.id == instance.id }
          )
          updated.instances[index].endpoint = "https://localhost:8443/graphql"
          return updated
        }
        return KaibaInstanceLastTest(status: .ready, attemptedAt: Date())
      }
    )
    let staleID = try await addInstance(
      named: "Stale",
      app: staleApp,
      environment: environment
    )
    await assertFailureCode(
      "kaiba_instance_changed",
      staleApp,
      ["kaiba", "instance", "test", staleID],
      environment
    )
  }

  func testRemoveScansBindingsAndForceReportsAffectedReferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let appRoot = root.appendingPathComponent("app", isDirectory: true)
    let app = RielaCLIApplication()
    let environment = ["HOME": home.path]
    let defaults = [
      "kaiba", "instance", "add", "Default", "--endpoint", "https://localhost",
      "--allow-unauthenticated", "--output", "json"
    ]
    let defaultResult = await app.run(defaults, environment: environment)
    XCTAssertEqual(defaultResult.exitCode, .success, defaultResult.stderr)

    let added = await app.run([
      "kaiba", "instance", "add", "Bound", "--endpoint", "https://localhost",
      "--allow-unauthenticated", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(added.exitCode, .success, added.stderr)
    let addedPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(added.stdout.utf8)) as? [String: Any])
    let instance = try XCTUnwrap(addedPayload["instance"] as? [String: Any])
    let id = try XCTUnwrap(instance["id"] as? String)

    let source = project.appendingPathComponent(".riela/workflows/example/workflow.json")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    let workflow = """
    { "workflowId": "example", "nodes": [
      { "id": "node", "addon": { "name": "kaiba/note-search", "config": { "kaibaInstanceId": "\(id)" } } }
    ] }
    """
    try Data(workflow.utf8).write(to: source)
    let scanOptions = ["--working-dir", project.path, "--app-root", appRoot.path, "--output", "json"]

    let blocked = await app.run(["kaiba", "instance", "remove", id] + scanOptions, environment: environment)
    XCTAssertEqual(blocked.exitCode, .usage)
    let blockedPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(blocked.stderr.utf8)) as? [String: Any])
    XCTAssertEqual(blockedPayload["code"] as? String, "kaiba_instance_in_use")
    XCTAssertEqual(blockedPayload["message"] as? String, "The Kaiba instance is still bound to workflow nodes.")
    XCTAssertEqual(blockedPayload["nextAction"] as? String, "Update the bindings or repeat remove with --force.")

    let forced = await app.run(["kaiba", "instance", "remove", id, "--force"] + scanOptions, environment: environment)
    XCTAssertEqual(forced.exitCode, .success, forced.stderr)
    let forcedPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(forced.stdout.utf8)) as? [String: Any])
    let references = try XCTUnwrap(forcedPayload["affectedReferences"] as? [[String: Any]])
    XCTAssertEqual(references.count, 1)
    XCTAssertEqual(references[0]["workflowId"] as? String, "example")
    XCTAssertEqual(references[0]["nodeId"] as? String, "node")

    let textAdded = await app.run([
      "kaiba", "instance", "add", "Bound Text", "--endpoint", "https://localhost",
      "--allow-unauthenticated", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(textAdded.exitCode, .success, textAdded.stderr)
    let textAddedPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(textAdded.stdout.utf8)) as? [String: Any])
    let textInstance = try XCTUnwrap(textAddedPayload["instance"] as? [String: Any])
    let textID = try XCTUnwrap(textInstance["id"] as? String)
    let textWorkflow = workflow.replacingOccurrences(of: id, with: textID)
    try Data(textWorkflow.utf8).write(to: source)
    let forcedText = await app.run([
      "kaiba", "instance", "remove", textID, "--force", "--working-dir", project.path, "--app-root", appRoot.path
    ], environment: environment)
    XCTAssertEqual(forcedText.exitCode, .success, forcedText.stderr)
    XCTAssertEqual(
      forcedText.stdout,
      "Removed \(textID) Bound Text\nAFFECTED: project - example node definition \(source.path)\n"
    )
  }

  func testListAndAddUseInjectedHomeWithoutPersistingCredentialValue() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let app = RielaCLIApplication()
    let empty = await app.run(["kaiba", "instance", "list", "--output", "json"], environment: ["HOME": home.path])
    XCTAssertEqual(empty.exitCode, .success, empty.stderr)
    let emptyPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(empty.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(emptyPayload["status"] as? String, "ok")
    XCTAssertEqual(emptyPayload["operation"] as? String, "list")
    XCTAssertTrue((emptyPayload["instances"] as? [Any])?.isEmpty == true)

    let added = await app.run([
      "kaiba", "instance", "add", "Local", "--endpoint", "https://localhost:8080",
      "--api-key-env", "KAIBA_TOKEN", "--output", "json"
    ], environment: ["HOME": home.path, "KAIBA_TOKEN": "sentinel-token-value"])
    XCTAssertEqual(added.exitCode, .success, added.stderr)
    XCTAssertFalse(added.stdout.contains("sentinel-token-value"))

    let list = await app.run(["kaiba", "instance", "list", "--output", "json"], environment: ["HOME": home.path])
    XCTAssertEqual(list.exitCode, .success, list.stderr)
    XCTAssertTrue(list.stdout.contains("KAIBA_TOKEN"))
    XCTAssertFalse(list.stdout.contains("sentinel-token-value"))

    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(added.stdout.utf8)) as? [String: Any]
    )
    XCTAssertEqual(payload["status"] as? String, "ok")
    let instance = try XCTUnwrap(payload["instance"] as? [String: Any])
    let id = try XCTUnwrap(instance["id"] as? String)
    let text = await app.run(["kaiba", "instance", "show", id], environment: ["HOME": home.path])
    XCTAssertEqual(text.exitCode, .success, text.stderr)
    XCTAssertTrue(text.stdout.hasPrefix("DEFAULT: yes\nENABLED: yes\nNAME: Local\n"))

    let contradictory = await app.run([
      "kaiba", "instance", "update", id, "--enable", "--disable"
    ], environment: ["HOME": home.path])
    XCTAssertEqual(contradictory.exitCode, .usage, "stdout=\(contradictory.stdout) stderr=\(contradictory.stderr)")

    let unknown = await app.run(["kaiba", "instance", "show", id, "--unknown", "--output", "json"], environment: ["HOME": home.path])
    XCTAssertEqual(unknown.exitCode, .usage)
    let unknownPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(unknown.stderr.utf8)) as? [String: Any])
    XCTAssertEqual(unknownPayload["code"] as? String, "invalid_usage")

    let invalidBeforeStore = await app.run(
      ["kaiba", "instance", "show", "anything", "--unknown", "--output", "json"],
      environment: ["HOME": home.path]
    )
    XCTAssertEqual(invalidBeforeStore.exitCode, .usage)
    let invalidBeforeStorePayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(invalidBeforeStore.stderr.utf8)) as? [String: Any]
    )
    XCTAssertEqual(invalidBeforeStorePayload["code"] as? String, "invalid_usage")

    let contradictoryBeforeStore = await app.run(
      ["kaiba", "instance", "update", "anything", "--enable", "--disable", "--output", "json"],
      environment: ["HOME": "/dev/null"]
    )
    XCTAssertEqual(contradictoryBeforeStore.exitCode, .usage)
    let contradictoryBeforeStorePayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contradictoryBeforeStore.stderr.utf8)) as? [String: Any]
    )
    XCTAssertEqual(contradictoryBeforeStorePayload["code"] as? String, "invalid_usage")

    let invalidBooleanBeforeStore = await app.run(
      ["kaiba", "instance", "update", "anything", "--allow-insecure-http", "invalid", "--output", "json"],
      environment: ["HOME": "/dev/null"]
    )
    XCTAssertEqual(invalidBooleanBeforeStore.exitCode, .usage)
    let invalidBooleanBeforeStorePayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(invalidBooleanBeforeStore.stderr.utf8)) as? [String: Any]
    )
    XCTAssertEqual(invalidBooleanBeforeStorePayload["code"] as? String, "invalid_usage")

    let invalidAddAuthenticationBeforeStore = await app.run(
      [
        "kaiba", "instance", "add", "anything", "--endpoint", "https://localhost",
        "--api-key-env", "KAIBA_TOKEN", "--allow-unauthenticated", "--output", "json"
      ],
      environment: ["HOME": "/dev/null"]
    )
    XCTAssertEqual(invalidAddAuthenticationBeforeStore.exitCode, .usage)
    let invalidAddAuthPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(invalidAddAuthenticationBeforeStore.stderr.utf8)) as? [String: Any]
    )
    XCTAssertEqual(invalidAddAuthPayload["code"] as? String, "invalid_authentication_policy")

    let malformedEndpoint = await app.run([
      "kaiba", "instance", "add", "Bad", "--endpoint", "ftp://localhost",
      "--allow-unauthenticated", "--output", "json"
    ], environment: ["HOME": home.path])
    XCTAssertEqual(malformedEndpoint.exitCode, .usage)
    let endpointPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(malformedEndpoint.stderr.utf8)) as? [String: Any])
    XCTAssertEqual(endpointPayload["code"] as? String, "invalid_endpoint")

    let parserFailure = await app.run(["kaiba", "unsupported", "--output", "json"], environment: ["HOME": home.path])
    XCTAssertEqual(parserFailure.exitCode, .usage)
    XCTAssertTrue(parserFailure.stdout.isEmpty)
    let parserPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parserFailure.stderr.utf8)) as? [String: Any])
    XCTAssertEqual(parserPayload["status"] as? String, "error")
    XCTAssertEqual(parserPayload["operation"] as? String, "instance")
    XCTAssertEqual(parserPayload["code"] as? String, "invalid_usage")

    let addedDisabled = await app.run([
      "kaiba", "instance", "add", "Disabled", "--endpoint", "https://localhost",
      "--allow-unauthenticated", "--output", "json"
    ], environment: ["HOME": home.path])
    let disabledPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(addedDisabled.stdout.utf8)) as? [String: Any]
    )
    let disabledInstance = try XCTUnwrap(disabledPayload["instance"] as? [String: Any])
    let disabledID = try XCTUnwrap(disabledInstance["id"] as? String)
    let disabledUpdate = await app.run(
      ["kaiba", "instance", "update", disabledID, "--disable"],
      environment: ["HOME": home.path]
    )
    XCTAssertEqual(disabledUpdate.exitCode, .success, disabledUpdate.stderr)
    let disabledTest = await app.run(
      ["kaiba", "instance", "test", disabledID],
      environment: ["HOME": home.path]
    )
    XCTAssertEqual(disabledTest.exitCode, .usage)
    let disabledShow = await app.run(
      ["kaiba", "instance", "show", disabledID, "--output", "json"],
      environment: ["HOME": home.path]
    )
    let disabledShowPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(disabledShow.stdout.utf8)) as? [String: Any]
    )
    let shownInstance = try XCTUnwrap(disabledShowPayload["instance"] as? [String: Any])
    let lastTest = try XCTUnwrap(shownInstance["lastTest"] as? [String: Any])
    XCTAssertEqual(lastTest["status"] as? String, "disabled")
    XCTAssertEqual(lastTest["code"] as? String, "disabled_kaiba_instance")

    let missingCredential = await app.run([
      "kaiba", "instance", "add", "Missing Credential", "--endpoint", "https://localhost",
      "--api-key-env", "MISSING_KAIBA_TOKEN", "--output", "json"
    ], environment: ["HOME": home.path])
    XCTAssertEqual(missingCredential.exitCode, .success, missingCredential.stderr)
    let missingPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(missingCredential.stdout.utf8)) as? [String: Any]
    )
    let missingInstance = try XCTUnwrap(missingPayload["instance"] as? [String: Any])
    let missingID = try XCTUnwrap(missingInstance["id"] as? String)
    let missingTest = await app.run(
      ["kaiba", "instance", "test", missingID, "--output", "json"],
      environment: ["HOME": home.path]
    )
    XCTAssertEqual(missingTest.exitCode, .usage)
    let failure = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(missingTest.stderr.utf8)) as? [String: Any])
    XCTAssertEqual(failure["code"] as? String, "missing_kaiba_credential")
    XCTAssertEqual(failure["instanceId"] as? String, missingID)
    XCTAssertEqual(failure["instanceName"] as? String, "Missing Credential")

    let missingShow = await app.run(
      ["kaiba", "instance", "show", missingID, "--output", "json"],
      environment: ["HOME": home.path]
    )
    let missingShowPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(missingShow.stdout.utf8)) as? [String: Any]
    )
    let missingShownInstance = try XCTUnwrap(missingShowPayload["instance"] as? [String: Any])
    let missingLastTest = try XCTUnwrap(missingShownInstance["lastTest"] as? [String: Any])
    XCTAssertEqual(missingLastTest["status"] as? String, "missing_credential")
    XCTAssertEqual(missingLastTest["code"] as? String, "missing_kaiba_credential")
  }

  private func addInstance(
    named name: String,
    app: RielaCLIApplication,
    environment: [String: String]
  ) async throws -> String {
    let result = await app.run([
      "kaiba", "instance", "add", name, "--endpoint", "https://localhost",
      "--allow-unauthenticated", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    )
    let instance = try XCTUnwrap(payload["instance"] as? [String: Any])
    return try XCTUnwrap(instance["id"] as? String)
  }

  private func failureCode(
    _ app: RielaCLIApplication,
    _ arguments: [String],
    _ environment: [String: String]
  ) async -> String? {
    let result = await app.run(arguments + ["--output", "json"], environment: environment)
    XCTAssertNotEqual(result.exitCode, .success, "stdout=\(result.stdout)")
    XCTAssertTrue(result.stdout.isEmpty)
    guard let payload = try? JSONSerialization.jsonObject(
      with: Data(result.stderr.utf8)
    ) as? [String: Any] else {
      XCTFail("expected JSON error, got: \(result.stderr)")
      return nil
    }
    return payload["code"] as? String
  }

  private func assertFailureCode(
    _ expected: String,
    _ app: RielaCLIApplication,
    _ arguments: [String],
    _ environment: [String: String]
  ) async {
    let actual = await failureCode(app, arguments, environment)
    XCTAssertEqual(actual, expected)
  }
}
