import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class InstanceIdentityNormalizationTests: XCTestCase {
  func testAppProfileLookupAndPrecedence() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/identity-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let workflow = root.appendingPathComponent("workflow")
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    try Data(#"{"workflowId":"wf"}"#.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    for profile in ["a", "b"] {
      let directory = home.appendingPathComponent(".riela/rielaapp/profiles/\(profile)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let state: [String: Any] = ["preferences": ["instance": ["sourceIdentity": "selected-workflow:\(workflow.path)"]]]
      try JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("daemon-workflows.json"))
    }
    let project = FileWorkflowInstanceStore(rootDirectory: root.appendingPathComponent("project").path)
    let user = FileWorkflowInstanceStore(rootDirectory: root.appendingPathComponent("user").path)
    let store = ScopedWorkflowInstanceStore(
      project: project, user: user, appProfiles: AppProfileWorkflowInstanceStore(homeDirectory: home)
    )
    XCTAssertThrowsError(try store.findRecord(identity: "instance"))
    let app = try XCTUnwrap(store.findRecord(identity: "instance", profile: "b"))
    XCTAssertEqual(app.scope, "app:b")
    XCTAssertEqual(app.instance.workflowId, "wf")
    try project.save(WorkflowInstanceDefinition(identity: "instance", workflowId: "project"))
    XCTAssertEqual(try store.findRecord(identity: "instance")?.scope, "project")
  }

  func testAppIdentityCommandsRespectScopeAndDoNotWrite() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/identity-cli-\(UUID().uuidString)")
    let home = root.appendingPathComponent("home")
    let project = root.appendingPathComponent("project")
    let appRoot = home.appendingPathComponent(".riela/rielaapp")
    defer { try? FileManager.default.removeItem(at: root) }
    for profile in ["a", "b"] {
      let directory = appRoot.appendingPathComponent("profiles/\(profile)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(#"{"preferences":{"instance":{"sourceIdentity":"user-workflow:wf"}}}"#.utf8)
        .write(to: directory.appendingPathComponent("daemon-workflows.json"))
    }
    let environment = ["HOME": home.path, "RIELA_APP_ROOT": appRoot.path]
    let cli = RielaCLIApplication()
    let base = ["--cwd", project.path, "--output", "json"]
    let ambiguous = await cli.run(["instance", "show", "instance"] + base, environment: environment)
    XCTAssertNotEqual(ambiguous.exitCode, .success)
    XCTAssertTrue(ambiguous.stdout.contains("ambiguous"), ambiguous.stdout)
    let shown = await cli.run(["instance", "show", "instance", "--profile", "b"] + base, environment: environment)
    XCTAssertEqual(shown.exitCode, .success, shown.stdout + shown.stderr)
    let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(record["scope"] as? String, "app:b")
    for action in ["update", "remove"] {
      let result = await cli.run(["instance", action, "instance"] + base, environment: environment)
      XCTAssertNotEqual(result.exitCode, .success)
      XCTAssertTrue(result.stdout.contains("instance_app_scope_read_only"), result.stdout)
      XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".riela/instances.json").path))
    }
    let projectStore = FileWorkflowInstanceStore(rootDirectory: project.appendingPathComponent(".riela").path)
    try projectStore.save(WorkflowInstanceDefinition(identity: "instance", workflowId: "project"))
    let preferred = await cli.run(["instance", "show", "instance"] + base, environment: environment)
    XCTAssertEqual(preferred.exitCode, .success, preferred.stdout + preferred.stderr)
    let preferredRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preferred.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(preferredRecord["scope"] as? String, "project")
  }

}
