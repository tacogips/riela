import XCTest
@testable import RielaAddons

final class RoutineAddonCatalogTests: XCTestCase {
  func testRouteProvenanceIsExplicitAndVersionBound() {
    let chat = RielaBuiltinAddonCatalog.descriptor(named: "riela/chat-reply-worker")
    XCTAssertEqual(chat?.version, "1")
    XCTAssertEqual(chat?.outputProvenance?.forwardsPayload, true)
    XCTAssertTrue(chat?.outputProvenance?.removedPayload.contains("_rielaInput") == true)
    XCTAssertTrue(chat?.outputProvenance?.overwrittenPayload.contains("status") == true)
    XCTAssertNil(RielaBuiltinAddonCatalog.descriptor(named: "riela/kv-get")?.outputProvenance)
    XCTAssertFalse(RielaBuiltinAddonCatalog.supports(name: "riela/chat-reply-worker", version: "2"))
    for name in ["riela/codex-sdk-worker", "riela/claude-sdk-worker", "riela/cursor-sdk-worker"] {
      let output = RielaBuiltinAddonCatalog.descriptor(named: name)?.outputProvenance
      XCTAssertNil(output?.forwardsPayload)
      XCTAssertEqual(output?.booleanOverwrites, ["liveExecution"])
      XCTAssertTrue(output?.removedPayload.contains("inputFilterSkipped") == true)
    }
    XCTAssertNil(RielaBuiltinAddonCatalog.descriptor(named: "riela/gemini-sdk-worker")?.outputProvenance)
  }

  func testRoutineAddonsAreCataloged() {
    let expected = [
      "riela/routine-create",
      "riela/routine-complete",
      "riela/routine-get",
      "riela/routine-list",
      "riela/routine-update-status",
      "riela/routine-delete"
    ]
    XCTAssertEqual(RielaBuiltinAddonCatalog.routineAddons.map(\.name), expected)
    for name in expected {
      XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: name, version: "1"), name)
      XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: name, version: nil), name)
      XCTAssertFalse(RielaBuiltinAddonCatalog.supports(name: name, version: "2"), name)
    }
  }
}
