import XCTest
@testable import RielaKaibaSupport

final class KaibaInstanceResolverTests: XCTestCase {
  func testAbsentBindingUsesDefaultButUnknownExplicitBindingFailsClosed() throws {
    let instance = KaibaInstance(name: "Default", endpoint: "https://localhost", authentication: .unauthenticated, isDefault: true)
    let catalog = KaibaInstanceCatalog(instances: [instance])
    XCTAssertEqual(try KaibaInstanceResolver.resolve(bindingID: nil, catalog: catalog).id, instance.id)
    XCTAssertThrowsError(try KaibaInstanceResolver.resolve(bindingID: "00000000-0000-0000-0000-000000000000", catalog: catalog)) { error in
      XCTAssertEqual(error as? KaibaInstanceStoreError, .missingInstance)
    }
  }
}
