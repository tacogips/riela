import Foundation
import XCTest
@testable import RielaCLI

final class KaibaInstanceCommandTests: XCTestCase {
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
}
