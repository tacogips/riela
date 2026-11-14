import Foundation
import RielaAppSupport
import RielaCore
import RielaGraphQL
import XCTest
@testable import RielaCLI

/// Console reads on GraphQL (CSP-6). The shared provider in `RielaAppSupport`
/// is what both `riela serve` and the desktop host expose, replacing the
/// deleted `/api/v1/instances` and `/api/v1/ops/overview` routes.
final class SurfaceParityConsoleReadTests: XCTestCase {
  @MainActor
  func testProviderProjectsInstancesIncludingSourcelessPreferences() {
    var state = RielaAppDaemonWorkflowState()
    state.preferences["orphan"] = RielaAppDaemonWorkflowPreference(
      identity: "orphan",
      sourceIdentity: "missing-source",
      active: true
    )
    let provider = Self.provider(state: state)

    let payload = provider.consoleInstanceList()
    XCTAssertEqual(payload.profile, "default")
    XCTAssertEqual(payload.revision, 7)
    XCTAssertEqual(payload.items.map(\.id), ["orphan"])
    XCTAssertEqual(payload.items.first?.status, "needsSource")
    XCTAssertEqual(payload.items.first?.sourceKind, "missing")

    let detail = provider.consoleInstanceDetail(identity: "orphan")
    XCTAssertEqual(detail.item?.id, "orphan")
    XCTAssertNil(provider.consoleInstanceDetail(identity: "absent").item)
  }

  @MainActor
  func testOpsOverviewProjectsProfileAndRevision() {
    let overview = Self.provider(state: RielaAppDaemonWorkflowState()).opsOverviewPayload()
    XCTAssertEqual(overview.profile, "default")
    XCTAssertEqual(overview.revision, 7)
    XCTAssertTrue(overview.workflows.isEmpty)
    XCTAssertTrue(overview.instances.isEmpty)
    XCTAssertFalse(overview.workflowsTruncated)
  }

  func testConsoleExecutorAnswersTheThreeReadsAndRefusesUntrustedDocuments() async throws {
    let executor = ConsoleGraphQLDocumentExecutor(provider: StubConsoleProvider())

    let list = await executor.execute(GraphQLDocumentRequest(
      query: "query C { consoleInstances { profile revision items { id status } } }",
      isLocallyTrusted: true
    ))
    XCTAssertNil(list.body["errors"])
    XCTAssertEqual(Self.string(list, path: ["consoleInstances", "items", "0", "id"]), "instance-a")

    let detail = await executor.execute(GraphQLDocumentRequest(
      query: #"query C { consoleInstance(identity: "instance-a") { item { id } } }"#,
      isLocallyTrusted: true
    ))
    XCTAssertEqual(Self.string(detail, path: ["consoleInstance", "item", "id"]), "instance-a")

    let overview = await executor.execute(GraphQLDocumentRequest(
      query: "query C { opsOverview { profile runs { sessionId } } }",
      isLocallyTrusted: true
    ))
    XCTAssertEqual(Self.string(overview, path: ["opsOverview", "profile"]), "default")

    let untrusted = await executor.execute(GraphQLDocumentRequest(
      query: "query C { consoleInstances { profile } }",
      isLocallyTrusted: false
    ))
    XCTAssertEqual(Self.errorCode(untrusted), "CONSOLE_UNAVAILABLE")
  }

  func testConsoleFieldsAreRejectedAsMutations() async {
    let executor = ConsoleGraphQLDocumentExecutor(provider: StubConsoleProvider())
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "mutation C { opsOverview { profile } }",
      isLocallyTrusted: true
    ))
    XCTAssertEqual(Self.errorCode(response), "INVALID_CONSOLE_READ")
  }

  func testCatalogAndExecutorAgreeOnTheConsoleReads() {
    let declared = SurfaceCatalog.operations(inFamily: "console")
      .filter { $0.isImplemented(on: .graphql) }
      .compactMap { $0.graphql?.field }
    XCTAssertEqual(Set(declared), ConsoleGraphQLDocumentExecutor.queryFields)
  }

  // MARK: - Helpers

  @MainActor
  private static func provider(state: RielaAppDaemonWorkflowState) -> RielaConsoleGraphQLProvider {
    RielaConsoleGraphQLProvider(
      profile: .default,
      state: state,
      instances: [],
      sources: [],
      revision: 7,
      sessionStoreRoot: NSTemporaryDirectory(),
      runtimeSnapshot: { _ in .init(status: .stopped, detail: "Inactive") },
      environment: { _ in [:] }
    )
  }

  private static func string(_ response: GraphQLDocumentExecutionResponse, path: [String]) -> String? {
    var value = response.body["data"]
    for key in path {
      if case let .array(items)? = value, let index = Int(key), items.indices.contains(index) {
        value = items[index]
        continue
      }
      guard case let .object(object)? = value else { return nil }
      value = object[key]
    }
    guard case let .string(result)? = value else { return nil }
    return result
  }

  private static func errorCode(_ response: GraphQLDocumentExecutionResponse) -> String? {
    guard case let .array(errors)? = response.body["errors"],
          case let .object(first)? = errors.first,
          case let .object(extensions)? = first["extensions"],
          case let .string(code)? = extensions["code"] else { return nil }
    return code
  }
}

private struct StubConsoleProvider: GraphQLConsoleProviding {
  func consoleInstances() async throws -> GraphQLConsoleInstanceListPayload {
    GraphQLConsoleInstanceListPayload(profile: "default", revision: 1, items: [Self.instance])
  }

  func consoleInstance(identity: String) async throws -> GraphQLConsoleInstancePayload {
    GraphQLConsoleInstancePayload(
      profile: "default",
      revision: 1,
      item: identity == Self.instance.id ? Self.instance : nil
    )
  }

  func opsOverview() async throws -> GraphQLOpsOverviewPayload {
    GraphQLOpsOverviewPayload(profile: "default", revision: 1)
  }

  static let instance = GraphQLConsoleInstanceDTO(
    id: "instance-a",
    sourceId: "source-a",
    isDefault: true,
    name: "Instance A",
    workflowId: "workflow-a",
    source: "/workflows/workflow-a",
    sourceKind: "directory",
    status: "stopped",
    statusDetail: "Inactive",
    active: false,
    enabledAtLaunch: false
  )
}
