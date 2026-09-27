import XCTest
@testable import RielaAddons

final class RielaBuiltinAddonCatalogTests: XCTestCase {
  private let expectedNames = [
    "riela/chat-persona-router",
    "riela/chat-persona-memory-read",
    "riela/chat-persona-memory-write",
    "riela/memory-save",
    "riela/memory-load",
    "riela/gmail-digest",
    "riela/x-digest",
    "riela/gemini-sdk-worker",
    "riela/codex-sdk-worker",
    "riela/time-signal",
    "riela/gmail-gateway-read",
    "riela/x-gateway-read"
  ]

  func testIssue116BuiltinsHaveVersionOneDescriptors() {
    for name in expectedNames {
      XCTAssertEqual(RielaBuiltinAddonCatalog.descriptor(named: name),
                     RielaAddonDescriptor(name: name, version: "1"), name)
      XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: name, version: nil), name)
      XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: name, version: "1"), name)
      XCTAssertFalse(RielaBuiltinAddonCatalog.supports(name: name, version: "2"), name)
    }
  }

  func testCatalogNamesAreUniqueAndUnknownNamesFailClosed() {
    let names = RielaBuiltinAddonCatalog.all.map(\.name)
    XCTAssertEqual(Set(names).count, names.count)
    for name in ["riela/issue-116-unknown", "example/issue-116-unknown"] {
      XCTAssertNil(RielaBuiltinAddonCatalog.descriptor(named: name))
      XCTAssertFalse(RielaBuiltinAddonCatalog.supports(name: name, version: nil))
      XCTAssertFalse(RielaBuiltinAddonCatalog.supports(name: name, version: "1"))
    }
  }
}
