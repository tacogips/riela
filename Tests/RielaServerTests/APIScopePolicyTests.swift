import RielaGraphQL
import XCTest
@testable import RielaServer

final class APIScopePolicyTests: XCTestCase {
  func testReadAllowsQueriesAndRejectsFirstMutation() {
    let query = (root: "Query", field: "bots")
    XCTAssertNil(RielaAPIScopePolicy.violation(scope: .read, roots: [query]))
    XCTAssertEqual(RielaAPIScopePolicy.violation(scope: .read, roots: [query, ("Mutation", "setBotPaused"), ("Mutation", "removeBot")]),
                   "Mutation.setBotPaused")
  }

  func testOperateAllowsOrdinaryMutationsAndReservesAdminMutations() {
    XCTAssertNil(RielaAPIScopePolicy.violation(scope: .operate, roots: [("Mutation", "setBotPaused")]))
    for field in ["removeBot", "mintPairingCode", "revokePairingGrant", "addRemote", "removeRemote", "useRemote",
                  "saveProviderInstance", "removeProviderInstance"] {
      XCTAssertEqual(RielaAPIScopePolicy.violation(scope: .operate, roots: [("Mutation", field)]), "Mutation.\(field)")
    }
  }

  func testAllCanonicalConfigurationMutationsRequireAdmin() {
    let fields = RielaConfigGraphQLDocumentExecutor.mutationFields
    XCTAssertFalse(fields.isEmpty)
    for field in fields {
      XCTAssertEqual(RielaAPIScopePolicy.violation(scope: .operate, roots: [("Mutation", field)]), "Mutation.\(field)")
    }
    let update = [("Mutation", "updateHTTPServerConfiguration")]
    XCTAssertEqual(RielaAPIScopePolicy.violation(scope: .operate, roots: update), "Mutation.updateHTTPServerConfiguration")
    XCTAssertNil(RielaAPIScopePolicy.violation(scope: .admin, roots: update + [("Mutation", "removeBot")]))
  }

  func testScopeComparisonOrdersPrivilege() {
    XCTAssertLessThan(RielaAPIKeyStore.Scope.read, .operate)
    XCTAssertLessThan(RielaAPIKeyStore.Scope.operate, .admin)
    XCTAssertLessThan(RielaAPIKeyStore.Scope.read, .admin)
    XCTAssertFalse(RielaAPIKeyStore.Scope.admin < .admin)
  }
}
