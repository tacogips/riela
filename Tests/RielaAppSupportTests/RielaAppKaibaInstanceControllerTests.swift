#if os(macOS)
import Foundation
import XCTest
@testable import RielaAppSupport
@testable import RielaKaibaSupport

final class RielaAppKaibaInstanceControllerTests: XCTestCase {
  func testAddDefaultAndRemovalUseTheSharedSafeCatalog() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let roots = KaibaBindingScanRoots(projectRootURL: root, homeURL: root, appRootURL: root)
    let controller = RielaAppKaibaInstanceController(homeURL: root, bindingScanRoots: roots)
    let first = try controller.add(.init(name: "Local", endpoint: "https://localhost", authentication: .unauthenticated))
    XCTAssertTrue(first.isDefault)
    XCTAssertEqual(try controller.list().map(\.id), [first.id])
    XCTAssertTrue(try controller.remove(id: first.id).instances.isEmpty)
  }

  func testUpdateEnablementAndDefaultUseSharedLifecycleRules() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let roots = KaibaBindingScanRoots(projectRootURL: root, homeURL: root, appRootURL: root)
    let controller = RielaAppKaibaInstanceController(homeURL: root, bindingScanRoots: roots)
    let first = try controller.add(.init(name: "Local", endpoint: "https://localhost", authentication: .unauthenticated))
    let second = try controller.add(.init(name: "Remote", endpoint: "https://example.com", authentication: .bearer(environmentVariable: "KAIBA_TOKEN")))
    var disabled = second
    disabled.enabled = false
    let updated = try controller.update(disabled, expected: second)
    XCTAssertEqual(updated.lastTest.status, .disabled)
    XCTAssertThrowsError(try controller.setDefault(id: updated.id))
    XCTAssertEqual(try controller.setDefault(id: first.id).first(where: { $0.isDefault })?.id, first.id)
  }

  func testRemovalReferencesMatchTheSharedScannerForIdenticalRoots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let appRoot = root.appendingPathComponent("app", isDirectory: true)
    let roots = KaibaBindingScanRoots(projectRootURL: project, homeURL: home, appRootURL: appRoot)
    let controller = RielaAppKaibaInstanceController(homeURL: home, bindingScanRoots: roots)
    let instance = try controller.add(.init(name: "Local", endpoint: "https://localhost", authentication: .unauthenticated))
    let workflowURL = project.appendingPathComponent(".riela/workflows/example/workflow.json")
    try FileManager.default.createDirectory(at: workflowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
    { "workflowId": "example", "nodes": [{
      "id": "search", "addon": { "name": "kaiba/note-search", "config": { "kaibaInstanceId": "\(instance.id)" } }
    }] }
    """.utf8).write(to: workflowURL)

    let appReferences = try controller.removalReferences(id: instance.id)
    let scannerReferences = try KaibaBindingScanner().references(to: instance.id, roots: roots)

    XCTAssertEqual(appReferences, scannerReferences)
    XCTAssertThrowsError(try controller.remove(id: instance.id)) { error in
      XCTAssertEqual(error as? RielaAppKaibaInstanceControllerError, .instanceInUse)
    }
  }
}
#endif
