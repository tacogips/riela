import Foundation
import XCTest
@testable import RielaKaibaSupport

final class KaibaRedactionTests: XCTestCase {
  func testBearerValueNeverCrossesPersistedOrReflectedInstanceBoundary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let token = "kaiba-redaction-sentinel-token"
    let instance = KaibaInstance(
      name: "Remote",
      endpoint: "https://kaiba.example.test",
      authentication: .bearer(environmentVariable: "KAIBA_TOKEN"),
      isDefault: true
    )
    let store = KaibaInstanceStore(homeURL: root)
    _ = try KaibaClientFactory().makeClient(instance: instance, environment: ["KAIBA_TOKEN": token])
    try store.save(.init(instances: [instance]))

    XCTAssertFalse(try String(contentsOf: store.fileURL).contains(token))
    XCTAssertFalse(String(reflecting: try store.load()).contains(token))
  }
}
