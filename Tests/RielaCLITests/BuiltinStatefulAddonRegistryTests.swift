import RielaAddons
import RielaCore
import XCTest
@testable import RielaCLI

final class BuiltinStatefulAddonRegistryTests: XCTestCase {
  func testRegistrationsAreUniqueAndDeclaredInThePublicCatalog() {
    let names = BuiltinStatefulAddonRegistry.registrations.map(\.name)
    XCTAssertEqual(Set(names).count, names.count)
    XCTAssertTrue(Set(names).isSubset(of: Set(RielaBuiltinAddonCatalog.all.map(\.name))))
    XCTAssertEqual(Set(BuiltinStatefulAddonRegistry.handlers.keys), Set(names))
  }

  func testUnknownNodeIsLeftToTheOtherAddonResolvers() async throws {
    let input = WorkflowAddonExecutionInput(workflowId: "registry", stepId: "lookup", nodeId: "lookup",
      addon: .init(name: "test/unregistered", version: "1"), variables: [:])
    let result = try await BuiltinWorkflowAddonResolver(environment: [:]).executeStatefulAddonIfSupported(input, context: .init())
    XCTAssertNil(result)
  }
}
