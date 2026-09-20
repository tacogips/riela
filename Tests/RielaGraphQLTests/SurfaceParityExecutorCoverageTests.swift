import Foundation
import RielaCore
import XCTest
@testable import RielaGraphQL

/// Inventory of schema fields against the document executors that answer them.
///
/// This test recorded a gap the accepted design did not know about: a large
/// part of the published control-plane schema has no document executor, so a
/// `/graphql` request for those fields is answered with "selected GraphQL root
/// was not handled". The allowlist below is that gap, written down so it can
/// only shrink — every entry removed from it must be backed by an executor.
final class SurfaceParityExecutorCoverageTests: XCTestCase {
  /// Fields published by the schema that no document executor answers yet.
  /// Recorded 2026-09-21 while implementing control-surface parity; tracked in
  /// `impl-plans/active/control-surface-parity.md` (CSP follow-up F1).
  static let fieldsWithoutADocumentExecutor: Set<String> = [
    // Read services exist (`GraphQLRuntimeSnapshotQueryService`,
    // `GraphQLWorkflowInstanceService`) but are not wired to a document
    // executor, so `/graphql` cannot reach them.
    "Query.workflowInstances",
    "Query.workflowInstance",
    "Query.workflowSession",
    "Query.workflowSessions",
    "Query.sessionProgress",
    "Query.sessionHealth",
    "Query.loopEvidence",
    "Query.loopSessions",
    "Query.loopWorkflowStats",
    "Query.loopEvidenceDiff",
    "Query.managerSession",
    "Mutation.createWorkflowInstance",
    "Mutation.updateWorkflowInstance",
    "Mutation.deleteWorkflowInstance",
    // Only the `GraphQLControlPlaneServicing` protocol exists for these; no
    // implementation is in the tree.
    "Mutation.sendManagerMessage",
    "Mutation.replayCommunication",
    "Mutation.retryCommunicationDelivery"
  ]

  /// Fields every executor in the tree answers, keyed by root.
  static func executorFields() -> Set<String> {
    var fields: Set<String> = []
    func add(_ root: String, _ names: Set<String>) {
      fields.formUnion(names.map { "\(root).\($0)" })
    }
    add("Query", WorkflowRegistryGraphQLDocumentExecutor.queryFields)
    add("Mutation", WorkflowRegistryGraphQLDocumentExecutor.mutationFields)
    add("Query", RoutineGraphQLDocumentExecutor.queryFields)
    add("Mutation", RoutineGraphQLDocumentExecutor.mutationFields)
    add("Query", RielaConfigGraphQLDocumentExecutor.queryFields)
    add("Mutation", RielaConfigGraphQLDocumentExecutor.mutationFields)
    add("Query", SessionControlGraphQLDocumentExecutor.queryFields)
    add("Mutation", SessionControlGraphQLDocumentExecutor.mutationFields)
    add("Query", ConsoleGraphQLDocumentExecutor.queryFields)
    add("Mutation", ConsoleGraphQLDocumentExecutor.mutationFields)
    return fields
  }

  func testEverySchemaFieldIsEitherExecutedOrRecordedAsAKnownGap() {
    let published = SurfaceCatalog.declaredGraphQLFields
    let executed = Self.executorFields()
    let unexecuted = published.subtracting(executed)
    XCTAssertEqual(
      unexecuted,
      Self.fieldsWithoutADocumentExecutor,
      "the recorded executor gap is out of date; update the allowlist in the same change"
    )
  }

  /// An executor may not answer a field the schema does not publish.
  func testNoExecutorAnswersAFieldTheSchemaDoesNotPublish() {
    let extra = Self.executorFields().subtracting(SurfaceCatalog.declaredGraphQLFields)
    XCTAssertTrue(extra.isEmpty, "executors answer unpublished fields: \(extra.sorted())")
  }

  /// The gap may only shrink.
  func testTheRecordedGapDoesNotGrow() {
    XCTAssertLessThanOrEqual(
      Self.fieldsWithoutADocumentExecutor.count,
      17,
      "the executor gap grew; wire an executor instead of extending the allowlist"
    )
  }
}
