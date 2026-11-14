import RielaAddons
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleGatewayContainerCapabilityTests: XCTestCase {
  func testMailReadGrantsIncludeRequiredPermissionAndMailboxQueries() throws {
    let list = AppleGatewayContainerCapability(addonName: "riela/apple-mail-list")
    try list.validate(arguments: ["graphql", "--query", "query { permissions { mailFullDiskAccess } mailAccounts { id } mailboxes { id } mailMessages { totalCount } }"])
    let message = AppleGatewayContainerCapability(addonName: "riela/apple-mail-message")
    try message.validate(arguments: ["graphql", "--query", "query { permissions { mailFullDiskAccess } mailMessage(messageId: \"fixture\") { id } }"])
    XCTAssertThrowsError(try message.validate(arguments: ["graphql", "--query", "query { mailAccounts { id } }"]))
    XCTAssertThrowsError(try list.validate(arguments: ["graphql", "--query", "query { notes { id } }"]))
  }

  func testEveryFixedAppleCatalogEntryHasANativeDependencyGrant() {
    let descriptors = RielaBuiltinAddonCatalog.appleGatewayAddons + RielaBuiltinAddonCatalog.appleReminderReadAddons +
      RielaBuiltinAddonCatalog.appleReminderMutationAddons
    for descriptor in descriptors {
      XCTAssertTrue(AppleGatewayContainerCapability(addonName: descriptor.name).isSupported, descriptor.name)
    }
    XCTAssertFalse(AppleGatewayContainerCapability(addonName: "riela/unknown").isSupported)
  }

  func testReadGrantRejectsMutationsOtherDomainsAndExtraCommands() throws {
    let capability = AppleGatewayContainerCapability(addonName: "riela/apple-note-get")
    try capability.validate(arguments: ["graphql", "--query", "query N($id: ID!) { note(noteId: $id) { id name } }",
      "--variables", #"{"id":"note-1"}"#])
    let forbidden = [
      ["graphql", "--query", "mutation { deleteNote(noteId: \"note-1\") { success } }"],
      ["graphql", "--query", "query { note(noteId: \"note-1\") { id } mailMessages { id } }"],
      ["graphql", "--query", "query { note(noteId: \"note-1\") { id } }", "--config", "/private/config"],
      ["file", "download", "--key", "ungranted"],
      ["permissions", "request", "--domain", "notes"]
    ]
    for arguments in forbidden { XCTAssertThrowsError(try capability.validate(arguments: arguments)) }
  }

  func testMutationGrantCannotChangeOperationOrBatchSideEffects() throws {
    let capability = AppleGatewayContainerCapability(addonName: "riela/apple-reminder-alarms-set")
    let permitted = "mutation A($id: ID!, $alarms: [AlarmInput!]!) { setReminderAlarms(reminderId: $id, alarms: $alarms) { id } }"
    try capability.validate(arguments: ["graphql", "--query", permitted, "--variables", #"{"id":"r1","alarms":[]}"#])
    for document in [
      "mutation { deleteReminder(reminderId: \"r1\") { success } }",
      permitted + " mutation { deleteReminder(reminderId: \"r1\") { success } }",
      "mutation { setReminderAlarms(reminderId: \"r1\", alarms: []) { id } setReminderAlarms(reminderId: \"r2\", alarms: []) { id } }",
      "query { reminder(reminderId: \"r1\") { id } }"
    ] { XCTAssertThrowsError(try capability.validate(arguments: ["graphql", "--query", document])) }
  }

  func testAliasesFragmentsAndMalformedVariablesFailClosed() {
    let capability = AppleGatewayContainerCapability(addonName: "riela/apple-note-get")
    for document in [
      "query { alias: note(noteId: \"n\") { id } }",
      "query { ...F } fragment F on Query { note(noteId: \"n\") { id } }",
      "query { note(noteId: \"n\") { id } } mutation { deleteNote(noteId: \"n\") { success } }"
    ] { XCTAssertThrowsError(try capability.validate(arguments: ["graphql", "--query", document])) }
    XCTAssertThrowsError(try capability.validate(arguments: ["graphql", "--query", "query { note { id } }", "--variables", "[]"]))
  }
}
