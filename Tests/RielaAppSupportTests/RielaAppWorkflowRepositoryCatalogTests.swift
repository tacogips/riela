#if os(macOS)
import XCTest
@testable import RielaAppSupport

final class RielaAppWorkflowRepositoryCatalogTests: XCTestCase {
  private var repositoryRoot: URL!

  override func setUpWithError() throws {
    repositoryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-app-marketplace-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let repositoryRoot {
      try? FileManager.default.removeItem(at: repositoryRoot)
    }
  }

  func testScanFindsStandaloneWorkflowsWithDescriptions() throws {
    try writeWorkflow(at: "beta-flow", workflowId: "beta-flow", description: "Second flow")
    try writeWorkflow(at: "nested/alpha-flow", workflowId: "alpha-flow", description: "First flow")

    let listings = RielaAppWorkflowRepositoryCatalogScanner.scan(
      repositoryRoot: repositoryRoot,
      repositoryId: "acme/workflows"
    )

    XCTAssertEqual(listings.map(\.workflowId), ["alpha-flow", "beta-flow"])
    XCTAssertEqual(listings.map(\.summary), ["First flow", "Second flow"])
    XCTAssertEqual(listings.map(\.relativePath), ["nested/alpha-flow", "beta-flow"])
    XCTAssertEqual(listings.map(\.kind), [.workflowDirectory, .workflowDirectory])
    XCTAssertEqual(listings.map(\.repositoryId), ["acme/workflows", "acme/workflows"])
    XCTAssertEqual(
      listings.map(\.installSourceURL.lastPathComponent),
      ["alpha-flow", "beta-flow"]
    )
  }

  func testScanListsPackageWorkflowWithManifestFallback() throws {
    try writeWorkflow(at: "packages/chat-bot/workflows/chat-bot", workflowId: "chat-bot", description: nil)
    try write(
      json: """
      {
        "name": "chat-bot",
        "version": "1.0.0",
        "description": "Package description",
        "workflow": {"title": "Chat Bot", "description": "Responds to chat messages"}
      }
      """,
      at: "packages/chat-bot/riela-package.json"
    )

    let listings = RielaAppWorkflowRepositoryCatalogScanner.scan(
      repositoryRoot: repositoryRoot,
      repositoryId: "acme/workflows"
    )

    XCTAssertEqual(listings.count, 1)
    let listing = try XCTUnwrap(listings.first)
    XCTAssertEqual(listing.kind, .packageWorkflow)
    XCTAssertEqual(listing.title, "Chat Bot")
    XCTAssertEqual(listing.summary, "Responds to chat messages")
    XCTAssertEqual(listing.packageName, "chat-bot")
    XCTAssertEqual(listing.relativePath, "packages/chat-bot")
    XCTAssertEqual(listing.installSourceURL.lastPathComponent, "chat-bot")
  }

  func testWorkflowDescriptionWinsOverManifestFallback() throws {
    try writeWorkflow(
      at: "packages/chat-bot/workflows/chat-bot",
      workflowId: "chat-bot",
      description: "Workflow description"
    )
    try write(
      json: """
      {"name": "chat-bot", "description": "Package description"}
      """,
      at: "packages/chat-bot/riela-package.json"
    )

    let listings = RielaAppWorkflowRepositoryCatalogScanner.scan(
      repositoryRoot: repositoryRoot,
      repositoryId: "acme/workflows"
    )

    XCTAssertEqual(listings.first?.summary, "Workflow description")
    XCTAssertEqual(listings.first?.title, "chat-bot")
  }

  func testScanListsOnlyRootWorkflowsWhenPackagesDeclareDependencies() throws {
    try writeWorkflow(at: "packages/parent/workflows/parent", workflowId: "parent", description: "Parent")
    try writeWorkflow(at: "packages/child/workflows/child", workflowId: "child", description: "Child")
    try write(
      json: #"{"name":"parent","dependencies":["child"]}"#,
      at: "packages/parent/riela-package.json"
    )
    try write(json: #"{"name":"child"}"#, at: "packages/child/riela-package.json")

    let listings = RielaAppWorkflowRepositoryCatalogScanner.scan(
      repositoryRoot: repositoryRoot,
      repositoryId: "acme/workflows"
    )

    XCTAssertEqual(listings.map(\.workflowId), ["parent"])
  }

  func testScanListsOnlyRootWorkflowsWhenTransitionsCallChildren() throws {
    try write(
      json: #"{"workflowId":"parent","steps":[{"transitions":[{"toStepId":"start","toWorkflowId":"child"}]}]}"#,
      at: "parent/workflow.json"
    )
    try writeWorkflow(at: "child", workflowId: "child", description: "Child")

    let listings = RielaAppWorkflowRepositoryCatalogScanner.scan(
      repositoryRoot: repositoryRoot,
      repositoryId: "acme/workflows"
    )

    XCTAssertEqual(listings.map(\.workflowId), ["parent"])
  }

  func testScanSkipsInvalidHiddenAndGitContent() throws {
    try writeWorkflow(at: "good-flow", workflowId: "good-flow", description: "ok")
    try write(json: "not json", at: "broken-flow/workflow.json")
    try write(json: #"{"description": "missing id"}"#, at: "no-id-flow/workflow.json")
    try write(json: #"{"workflowId": "hidden-flow"}"#, at: ".hidden/workflow.json")
    try write(json: #"{"workflowId": "git-flow"}"#, at: ".git/objects/workflow.json")

    let listings = RielaAppWorkflowRepositoryCatalogScanner.scan(
      repositoryRoot: repositoryRoot,
      repositoryId: "acme/workflows"
    )

    XCTAssertEqual(listings.map(\.workflowId), ["good-flow"])
  }

  func testScanIgnoresSymlinkedDirectories() throws {
    try writeWorkflow(at: "real-flow", workflowId: "real-flow", description: "ok")
    let outside = repositoryRoot.deletingLastPathComponent()
      .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: outside)
    }
    try Data(#"{"workflowId": "outside-flow"}"#.utf8)
      .write(to: outside.appendingPathComponent("workflow.json"))
    try FileManager.default.createSymbolicLink(
      at: repositoryRoot.appendingPathComponent("linked"),
      withDestinationURL: outside
    )

    let listings = RielaAppWorkflowRepositoryCatalogScanner.scan(
      repositoryRoot: repositoryRoot,
      repositoryId: "acme/workflows"
    )

    XCTAssertEqual(listings.map(\.workflowId), ["real-flow"])
  }

  func testLoaderCacheDirectoryNameIsSanitizedAndStable() throws {
    let reference = try RielaAppWorkflowRepositoryReference.parse(
      "https://github.com/tacogips/riela-packages/tree/main"
    )

    let name = RielaAppWorkflowRepositoryCatalogLoader.cacheDirectoryName(for: reference)

    XCTAssertEqual(name, "tacogips-riela-packages-main")
    let loader = RielaAppWorkflowRepositoryCatalogLoader(cacheRoot: repositoryRoot)
    XCTAssertEqual(loader.checkoutDirectory(for: reference).lastPathComponent, name)
  }

  private func writeWorkflow(at relativePath: String, workflowId: String, description: String?) throws {
    var payload: [String: Any] = ["workflowId": workflowId]
    if let description {
      payload["description"] = description
    }
    let data = try JSONSerialization.data(withJSONObject: payload)
    let directory = repositoryRoot.appendingPathComponent(relativePath, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appendingPathComponent("workflow.json"))
  }

  private func write(json: String, at relativePath: String) throws {
    let fileURL = repositoryRoot.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(json.utf8).write(to: fileURL)
  }
}
#endif
