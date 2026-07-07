import XCTest
@testable import RielaAddons
@testable import RielaCore

final class AddonExecutionContractsTests: XCTestCase {
  func testUnknownAddonFailsDeterministicallyWithoutInjectedResolver() async {
    let input = AddonExecutionInput(
      addonName: "third-party-addon",
      nodePayload: ["kind": .string("addon")],
      variables: ["dryRun": .bool(true)],
      source: .init(packageName: "pkg", addonName: "third-party-addon", sourcePath: "addons/addon"),
      options: .init(boundary: .async)
    )

    let result = await DeterministicAddonResolver().resolve(.init(input: input))

    guard case let .failed(diagnostics) = result else {
      return XCTFail("expected deterministic failure")
    }
    XCTAssertEqual(diagnostics.first?.code, "UNKNOWN_ADDON")
  }

  func testBuiltinAddonResolvesDeclarativelyWithoutRuntimeInternals() async throws {
    let input = AddonExecutionInput(
      addonName: "chat-reply",
      version: "1.0.0",
      nodePayload: ["message": .string("hello")],
      variables: [:],
      source: .init(addonName: "chat-reply", builtin: true),
      options: .init(boundary: .sync)
    )

    let result = await DeterministicAddonResolver().resolve(.init(input: input, allowedBuiltins: ["chat-reply"]))
    guard case let .resolved(output) = result else {
      return XCTFail("expected declarative resolution")
    }

    XCTAssertNil(output.candidatePayload)
    let encoded = String(data: try JSONEncoder().encode(input), encoding: .utf8)!
    XCTAssertFalse(encoded.contains("communicationId"))
    XCTAssertFalse(encoded.contains("candidatePath"))
    XCTAssertFalse(encoded.contains("WorkflowRuntimeStore"))
  }

  func testBuiltinCatalogContainsNoteAddons() {
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-notes-list", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-note-get", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-note-create", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-note-update-body", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-note-delete", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-note-move", version: nil))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-notifications-list", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-notification-post", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-notifications-dismiss", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-reminder-lists", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-reminders-list", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-reminder-get", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-reminder-list-create", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-reminder-create", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-reminder-update", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-reminder-delete", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-reminder-complete", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/apple-reminder-alarms-set", version: nil))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/calendar-list", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/event-search", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/event-get", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/event-create", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/event-update", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/event-delete", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/event-alarms-set", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/note-create", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/notebook-ingest-pages", version: nil))
    XCTAssertFalse(RielaBuiltinAddonCatalog.supports(name: "riela/note-create", version: "2"))
    XCTAssertFalse(RielaBuiltinAddonCatalog.supports(name: "riela/apple-note-get", version: "2"))
    XCTAssertFalse(RielaBuiltinAddonCatalog.supports(name: "riela/apple-notification-post", version: "2"))
    XCTAssertFalse(RielaBuiltinAddonCatalog.supports(name: "riela/apple-reminder-create", version: "2"))
    XCTAssertEqual(
      RielaBuiltinAddonCatalog.appleGatewayAddons.map(\.name),
      [
        "riela/apple-notes-list",
        "riela/apple-note-get",
        "riela/apple-note-create",
        "riela/apple-note-update-body",
        "riela/apple-note-delete",
        "riela/apple-note-move",
        "riela/apple-notifications-list",
        "riela/apple-notification-post",
        "riela/apple-notifications-dismiss",
        "riela/calendar-list",
        "riela/event-search",
        "riela/event-get",
        "riela/event-create",
        "riela/event-update",
        "riela/event-delete",
        "riela/event-alarms-set"
      ]
    )
    XCTAssertEqual(
      RielaBuiltinAddonCatalog.appleReminderReadAddons.map(\.name),
      [
        "riela/apple-reminder-lists",
        "riela/apple-reminders-list",
        "riela/apple-reminder-get"
      ]
    )
    XCTAssertEqual(
      RielaBuiltinAddonCatalog.appleReminderMutationAddons.map(\.name),
      [
        "riela/apple-reminder-list-create",
        "riela/apple-reminder-create",
        "riela/apple-reminder-update",
        "riela/apple-reminder-delete",
        "riela/apple-reminder-complete",
        "riela/apple-reminder-alarms-set"
      ]
    )
    XCTAssertEqual(
      RielaBuiltinAddonCatalog.noteAddons.map(\.name),
      [
        "riela/note-create",
        "riela/note-update",
        "riela/note-get",
        "riela/note-search",
        "riela/note-tag-apply",
        "riela/note-attach-file",
        "riela/note-graphql-document",
        "riela/note-comment-add",
        "riela/notebook-ingest-pages",
        "riela/note-conversation-save"
      ]
    )
  }

  func testAllowedBuiltinNamesDoNotAuthorizePackageAddons() async {
    let input = AddonExecutionInput(
      addonName: "chat-reply",
      nodePayload: ["message": .string("spoof")],
      source: .init(packageName: "third-party", addonName: "chat-reply", sourcePath: "addons/chat-reply", builtin: false)
    )

    let result = await DeterministicAddonResolver().resolve(.init(input: input, allowedBuiltins: ["chat-reply"]))

    guard case let .failed(diagnostics) = result else {
      return XCTFail("expected package add-on with built-in name to require an injected resolver")
    }
    XCTAssertEqual(diagnostics.first?.code, "UNKNOWN_ADDON")
  }

  func testAddonInputsDefaultMissingAttachmentsWhenDecodingLegacyJSON() throws {
    let addonExecutionJSON = """
    {
      "addonName": "native-runner",
      "nodePayload": { "prompt": "hello" },
      "variables": {},
      "source": { "packageName": "pkg", "addonName": "native-runner", "builtin": false }
    }
    """
    let addonInput = try JSONDecoder().decode(AddonExecutionInput.self, from: Data(addonExecutionJSON.utf8))
    XCTAssertEqual(addonInput.attachments, [:])
    XCTAssertEqual(addonInput.options.boundary, .async)

    let workflowAddonJSON = """
    {
      "workflowId": "workflow-a",
      "stepId": "step-a",
      "nodeId": "node-a",
      "addon": { "name": "native-runner" },
      "variables": {},
      "resolvedInputPayload": {}
    }
    """
    let workflowInput = try JSONDecoder().decode(WorkflowAddonExecutionInput.self, from: Data(workflowAddonJSON.utf8))
    XCTAssertEqual(workflowInput.attachments, [:])
  }
}
