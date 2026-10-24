import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleGatewayContainerCapabilityTests: XCTestCase {
  #if os(macOS)
  func testHostPreparesOperationForGuestWithoutReexpandingArgumentData() throws {
    let root = URL(fileURLWithPath: "/tmp/fixture")
    let source = "event-{{privateValue}}"
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/apple-gateway-graphql", config: [
        "operation": .string("event"), "arguments": .object(["eventId": .string("{{input.id}}")]),
        "selection": .array([.string("id")]), "configPath": .string("/tmp/fixture/config-{{input.config}}"),
        "writeRetry": .object(["initialWaitSeconds": .integer(7), "maxRetries": .string("{{input.retries}}")])
      ]), variables: ["privateValue": .string("must-not-expand")],
      resolvedInputPayload: ["id": .string(source), "config": .string("{{literal}}"), "retries": .integer(0)])
    let expected = try AppleGatewayAdminContext(input: input, currentDirectory: root).arguments(for: .graphql)
    let prepared = try prepareAppleGatewayContainerOperation(input, workingDirectory: root)
    XCTAssertNil(prepared.addon.config?["operation"])
    XCTAssertNil(prepared.addon.inputs?["operation"])
    let guestArguments = try AppleGatewayAdminContext(input: prepared, currentDirectory: root).arguments(for: .graphql)
    XCTAssertEqual(guestArguments, expected)
    XCTAssertEqual(try gatewayWriteRetryEnvironment(prepared, prefix: "APPLE_GATEWAY_"),
                   try gatewayWriteRetryEnvironment(input, prefix: "APPLE_GATEWAY_"))
    XCTAssertTrue(guestArguments.contains { $0.contains(source) })
    XCTAssertFalse(guestArguments.contains { $0.contains("must-not-expand") })
    let capability = try AppleGatewayContainerCapability(input: prepared, workingDirectory: root, mounts: [])
    try capability.validate(arguments: guestArguments)
    var changed = guestArguments
    changed[changed.count - 1] = #"{"eventId":"different"}"#
    XCTAssertThrowsError(try capability.validate(arguments: changed))
  }

  func testConfigPathNamedLikeAnOptionDoesNotChangePreparedDocument() throws {
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/apple-gateway-graphql", config: [
        "operation": .string("calendars"), "arguments": .object([:]), "configPath": .string("--query")]))
    let root = URL(fileURLWithPath: "/tmp/fixture")
    let expected = try AppleGatewayAdminContext(input: input, currentDirectory: root).arguments(for: .graphql)
    let prepared = try prepareAppleGatewayContainerOperation(input, workingDirectory: root)
    XCTAssertEqual(try AppleGatewayAdminContext(input: prepared, currentDirectory: root).arguments(for: .graphql), expected)
  }

  func testContainerOperationPreservesEnvironmentAndBinaryRestrictions() {
    for addon in [
      WorkflowNodeAddonRef(name: "riela/apple-gateway-graphql", config: [
        "operation": .string("calendars"), "arguments": .object([:]), "binaryPath": .string("/bin/true")]),
      WorkflowNodeAddonRef(name: "riela/apple-gateway-graphql", config: [
        "operation": .string("calendars"), "arguments": .object([:])], env: ["TOKEN": .string("untrusted")])
    ] {
      XCTAssertThrowsError(try prepareAppleGatewayContainerOperation(
        .init(workflowId: "fixture", stepId: "read", nodeId: "read", addon: addon),
        workingDirectory: URL(fileURLWithPath: "/tmp/fixture")))
    }
  }
  #endif

  /// Apple Container X reads bound each SDK request by the node deadline, like
  /// the embedded and Docker/Podman readers.
  func testAppleContainerXReaderPassesTheNodeDeadlineToReaderArguments() async throws {
    let runner = DeadlineRecordingExecRunner()
    _ = try await AppleContainerGatewayProcess(executable: "/usr/local/bin/container", environment: [:],
      workingDirectory: URL(fileURLWithPath: "/tmp"), runner: runner)
      .run(image: "fixture", mounts: [], networkAllowed: false, gateway: .xRead, document: "query { accountMe { id } }",
           bindings: [:], deadline: Date().addingTimeInterval(5))
    let calls = await runner.arguments
    let exec = try XCTUnwrap(calls.first { $0.first == "exec" })
    XCTAssertEqual(exec.firstIndex(of: "--retry").map { exec[$0 + 1] }, "0")
    let timeout = try XCTUnwrap(exec.firstIndex(of: "--timeout-ms").flatMap { Int(exec[$0 + 1]) })
    XCTAssertGreaterThan(timeout, 0)
    XCTAssertLessThanOrEqual(timeout, 5_000)
  }

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

private actor DeadlineRecordingExecRunner: LocalProcessRunning {
  var arguments: [[String]] = []
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    arguments.append(configuration.arguments)
    return .init(stdout: "{}", stderr: "", terminationStatus: 0)
  }
}
