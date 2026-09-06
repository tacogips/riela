#if os(macOS)
import Foundation
import RielaAppSupport
import RielaKaibaSupport
import XCTest
@testable import RielaCLI

final class RielaAppKaibaInstanceJourneyTests: XCTestCase {
  func testIsolatedCLIAndAppCatalogBindingRepairJourney() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let appRoot = root.appendingPathComponent("app", isDirectory: true)
    let environment = ["HOME": home.path]
    let application = RielaCLIApplication()

    let empty = await application.run(["kaiba", "instance", "list", "--output", "json"], environment: environment)
    XCTAssertEqual(empty.exitCode, .success, empty.stderr)
    XCTAssertTrue(try instances(in: empty.stdout).isEmpty)

    let localID = try await add(
      application,
      name: "Local",
      options: ["--endpoint", "http://127.0.0.1:8787", "--allow-unauthenticated"],
      environment: environment
    )
    let remoteID = try await add(
      application,
      name: "Remote",
      options: ["--endpoint", "https://kaiba.example.test", "--api-key-env", "KAIBA_TOKEN"],
      environment: environment
    )
    let shown = await application.run(
      ["kaiba", "instance", "show", remoteID, "--output", "json"],
      environment: environment
    )
    XCTAssertEqual(shown.exitCode, .success, shown.stderr)
    XCTAssertEqual(try instances(in: shown.stdout).first?["name"] as? String, "Remote")
    let update = await application.run(
      ["kaiba", "instance", "update", remoteID, "--name", "Remote Updated", "--output", "json"],
      environment: environment
    )
    XCTAssertEqual(update.exitCode, .success, update.stderr)
    let defaultResult = await application.run(
      ["kaiba", "instance", "set-default", localID, "--output", "json"],
      environment: environment
    )
    XCTAssertEqual(defaultResult.exitCode, .success, defaultResult.stderr)

    let workflowURL = project.appendingPathComponent(".riela/workflows/repair/workflow.json")
    try FileManager.default.createDirectory(at: workflowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeBinding(remoteID, to: workflowURL)
    let roots = KaibaBindingScanRoots(projectRootURL: project, homeURL: home, appRootURL: appRoot)
    let appController = RielaAppKaibaInstanceController(homeURL: home, bindingScanRoots: roots)
    XCTAssertEqual(try appController.list().first(where: { $0.id == remoteID })?.name, "Remote Updated")

    let removeOptions = ["--working-dir", project.path, "--app-root", appRoot.path, "--output", "json"]
    let blocked = await application.run(["kaiba", "instance", "remove", remoteID] + removeOptions, environment: environment)
    XCTAssertEqual(blocked.exitCode, .usage)
    XCTAssertTrue(blocked.stderr.contains("kaiba_instance_in_use"))
    let forced = await application.run(["kaiba", "instance", "remove", remoteID, "--force"] + removeOptions, environment: environment)
    XCTAssertEqual(forced.exitCode, .success, forced.stderr)
    XCTAssertThrowsError(try KaibaInstanceResolver.resolve(bindingID: remoteID, catalog: appController.store.load()))

    let repairedID = try await add(
      application,
      name: "Repaired",
      options: ["--endpoint", "http://127.0.0.1:8787", "--allow-unauthenticated"],
      environment: environment
    )
    try writeBinding(repairedID, to: workflowURL)
    let catalog = try appController.store.load()
    let snapshot = try KaibaExecutionSnapshot(
      bindingIDs: [repairedID],
      catalog: catalog,
      environment: environment
    )
    XCTAssertEqual(try snapshot.client(bindingID: repairedID).instance.id, repairedID)
    try writeBinding(nil, to: workflowURL)
    let defaultSnapshot = try KaibaExecutionSnapshot(
      bindingIDs: [nil],
      catalog: appController.store.load(),
      environment: environment
    )
    XCTAssertEqual(try defaultSnapshot.client(bindingID: nil).instance.id, localID)
    try writeBinding(repairedID, to: workflowURL)
    XCTAssertEqual(try appController.removalReferences(id: repairedID).count, 1)
  }

  private func add(
    _ application: RielaCLIApplication,
    name: String,
    options: [String],
    environment: [String: String]
  ) async throws -> String {
    let result = await application.run(
      ["kaiba", "instance", "add", name] + options + ["--output", "json"],
      environment: environment
    )
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    return try XCTUnwrap(instances(in: result.stdout).first?["id"] as? String)
  }

  private func instances(in output: String) throws -> [[String: Any]] {
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    if let instance = payload["instance"] as? [String: Any] { return [instance] }
    return try XCTUnwrap(payload["instances"] as? [[String: Any]])
  }

  private func writeBinding(_ instanceID: String?, to url: URL) throws {
    let binding = instanceID.map { "\"kaibaInstanceId\":\"\($0)\"" } ?? ""
    let workflow = """
    {"workflowId":"repair","nodes":[{"id":"search","addon":{"name":"kaiba/note-search","config":{\(binding)}}}]}
    """
    try Data(workflow.utf8).write(to: url)
  }
}
#endif
