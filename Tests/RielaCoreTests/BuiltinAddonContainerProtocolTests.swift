import Foundation
import XCTest
@testable import RielaCore

final class BuiltinAddonContainerProtocolTests: XCTestCase {
  func testCapturedKaibaInstanceCannotCrossBindingOrOperationScope() throws {
    let selected = BuiltinAddonKaibaInstance(id: "11111111-1111-4111-8111-111111111111", name: "Selected",
      endpoint: "https://kaiba.example/graphql", credentialEnvironmentVariable: "KAIBA_TOKEN",
      allowInsecureHTTP: false, allowRemoteUnauthenticated: false)
    var input = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n",
      addon: .init(name: "kaiba/note-get", config: ["kaibaInstanceId": .string(selected.id)]))
    let request = BuiltinAddonContainerRequest(operation: .execute, input: input, kaibaInstance: selected)
    try request.validate()
    var bridged = request
    bridged.nativeKaibaBridgeDirectory = "/tmp/" + UUID().uuidString
    try bridged.validate()
    bridged.nativeKaibaBridgeDirectory = "relative/" + UUID().uuidString
    XCTAssertThrowsError(try bridged.validate())
    bridged.nativeKaibaBridgeDirectory = "/tmp/" + UUID().uuidString
    bridged.kaibaInstance = nil
    XCTAssertThrowsError(try bridged.validate())
    XCTAssertEqual(try JSONDecoder().decode(BuiltinAddonContainerRequest.self, from: JSONEncoder().encode(request)), request)
    input.addon.config = ["kaibaInstanceId": .string("other")]
    XCTAssertThrowsError(try BuiltinAddonContainerRequest(operation: .execute, input: input, kaibaInstance: selected).validate())
    input.addon.name = "riela/time-signal"
    XCTAssertThrowsError(try BuiltinAddonContainerRequest(operation: .execute, input: input, kaibaInstance: selected).validate())
    XCTAssertThrowsError(try BuiltinAddonContainerRequest(operation: .acknowledge,
      finalizationToken: .init(value: "token"), kaibaInstance: selected).validate())
  }

  func testEmptyContainerSelectionRoundTripsAndKeepsNativeReferencesCompatible() throws {
    let decoder = JSONDecoder()
    let addon = try decoder.decode(WorkflowNodeAddonRef.self, from: Data(#"{"name":"riela/time-signal","container":{}}"#.utf8))
    XCTAssertEqual(addon.container, .init())
    XCTAssertEqual(try decoder.decode(WorkflowNodeAddonRef.self, from: JSONEncoder().encode(addon)), addon)
    XCTAssertNil(try decoder.decode(WorkflowNodeAddonRef.self, from: Data(#"{"name":"riela/time-signal"}"#.utf8)).container)
  }

  func testInvalidContainerChoicesAreRejected() {
    for container in [#"{"runtime":"bogus"}"#, #"{"networkPolicy":"bogus"}"#, #"{"image":""}"#,
      #"{"mounts":[{"source":"/","target":"/host"}]}"#,
      #"{"mounts":[{"source":"repo","target":"/mount"},{"source":"another","target":"/mount/../mount"}]}"#] {
      XCTAssertThrowsError(try JSONDecoder().decode(WorkflowAddonContainerExecution.self, from: Data(container.utf8)))
    }
  }

  func testRuntimeIdentityAttachmentsAndControlTokenSurviveProtocolRoundTrip() throws {
    let input = WorkflowAddonExecutionInput(workflowId: "workflow", stepId: "step", nodeId: "node",
      addon: .init(name: "riela/git-commit", version: "1"), variables: ["value": .integer(3)],
      resolvedInputPayload: ["input": .bool(true)],
      attachments: ["document": .init(id: "document", mediaType: "text/plain", sizeBytes: 3, sha256: "runtime-hash", contentText: "abc")],
      executionIdentity: .init(workflowExecutionId: "runtime-session", stepExecutionId: "runtime-step",
        operationExecutionId: "runtime-step", attempt: 1))
    let request = BuiltinAddonContainerRequest(operation: .execute, input: input, deadline: Date(timeIntervalSince1970: 1_800_000_000))
    let decoded = try JSONDecoder().decode(BuiltinAddonContainerRequest.self, from: JSONEncoder().encode(request))
    XCTAssertEqual(decoded, request)
    try decoded.validate()
    let output = AdapterExecutionOutput(provider: "builtin", model: "test", promptText: "prompt", completionPassed: false,
      when: ["always": true, "retry": true], payload: ["value": .integer(4)], usage: .init(totalTokens: 7),
      runtimeFinalizationToken: .init(value: "runtime-finalization"))
    let reply = try JSONDecoder().decode(BuiltinAddonContainerReply.self, from: JSONEncoder().encode(BuiltinAddonContainerReply(output: output)))
    XCTAssertNil(reply.output?.runtimeFinalizationToken, "public output JSON intentionally omits the token")
    XCTAssertEqual(try reply.validatedOutput(for: .execute), output)
  }

  func testControlRequestsAndContradictoryRepliesFailClosed() throws {
    XCTAssertThrowsError(try BuiltinAddonContainerRequest(operation: .execute).validate())
    XCTAssertThrowsError(try BuiltinAddonContainerRequest(operation: .acknowledge).validate())
    XCTAssertThrowsError(try BuiltinAddonContainerRequest(operation: .terminal, workflowExecutionId: "session", stepExecutionIds: [""]).validate())
    let nested = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n", addon: .init(name: "riela/time-signal", container: .init()))
    XCTAssertThrowsError(try BuiltinAddonContainerRequest(operation: .execute, input: nested).validate())
    var request = BuiltinAddonContainerRequest(operation: .acknowledge, finalizationToken: .init(value: "token"))
    request.protocolVersion = 2
    XCTAssertThrowsError(try request.validate())
    let output = AdapterExecutionOutput(provider: "test", model: "test", promptText: "", completionPassed: true, payload: [:])
    XCTAssertThrowsError(try BuiltinAddonContainerReply(output: output,
      failure: .init(AdapterExecutionError(.providerError, "failed"))).validatedOutput(for: .execute))
    XCTAssertThrowsError(try BuiltinAddonContainerReply().validatedOutput(for: .execute))
    XCTAssertThrowsError(try BuiltinAddonContainerReply(output: output).validatedOutput(for: .acknowledge))
  }

  func testRetryableErrorsRetainDuration() throws {
    let error = AdapterExecutionError(.providerError, "retry", isRetryable: true, retryAfter: .milliseconds(250))
    let failure = try JSONDecoder().decode(BuiltinAddonContainerFailure.self, from: JSONEncoder().encode(BuiltinAddonContainerFailure(error)))
    XCTAssertEqual(try failure.executionError(), error)
  }
}
