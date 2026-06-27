#if os(macOS)
import Foundation
import XCTest

final class RielaAppInterfaceIdentifierTests: XCTestCase {
  func testWorkflowSourceColumnUsesOnlySourceIdentifier() throws {
    let root = try repositoryRoot()
    let controllerURL = root.appendingPathComponent(
      "Sources/RielaApp/DaemonWorkflowWindowController.swift"
    )
    let source = try String(contentsOf: controllerURL, encoding: .utf8)

    XCTAssertTrue(
      source.contains("NSUserInterfaceItemIdentifier(\"source\")"),
      "Workflow source column should use the canonical 'source' identifier."
    )
    XCTAssertFalse(
      source.contains("NSUserInterfaceItemIdentifier(\"sources\")"),
      "Do not keep a legacy 'sources' user-interface identifier."
    )
  }

  private func repositoryRoot() throws -> URL {
    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    while current.path != "/" {
      if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
        return current
      }
      current.deleteLastPathComponent()
    }
    throw NSError(
      domain: "RielaAppInterfaceIdentifierTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"]
    )
  }
}
#endif
