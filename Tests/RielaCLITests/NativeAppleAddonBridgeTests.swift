import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class NativeAppleAddonBridgeTests: XCTestCase {
  func testBodyMaterializationUsesOnlyHostIssuedKeyAndSharedOutput() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-body-materialization")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloads = root.appendingPathComponent("tmp/downloads")
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root),
      environment: ["RIELA_CONTAINER_RUNTIME": "docker"], workingDirectory: root, runner: BridgeGuestProcessRunner(),
      hostPlatform: .darwin, nativeAppleGatewayRunner: { arguments, _, _ in
        if arguments[0] == "graphql" {
          return .init(stdout: #"{"data":{"note":{"id":"fixture","bodyFile":{"downloadKey":"approved"}}}}"#, stderr: "")
        }
        XCTAssertEqual(Array(arguments.prefix(5)), ["file", "download", "--key", "approved", "--output-dir"])
        let path = arguments[5] + "/body.html"
        try Data("<p>body</p>".utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        return .init(stdout: #"{"files":[{"downloadKey":"approved","path":"\#(path)"}]}"#, stderr: "")
      })
    let output = try await NativeAddonPinnedDirectory.StagingContext.$root.withValue(root.deletingLastPathComponent()) {
      try await resolver.execute(.init(workflowId: "w", stepId: "s", nodeId: "n",
      addon: .init(name: "riela/apple-note-get", version: "1", config: ["noteId": .string("fixture"),
        "materializeBody": .bool(true), "downloadDir": .string(downloads.path)], container: .init())),
      context: .init(deadline: Date().addingTimeInterval(10)))
    }
    XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("body.html"), encoding: .utf8), "<p>body</p>")
    guard case let .object(note)? = output.payload["appleNote"], case let .object(body)? = note["body"] else { return XCTFail("missing materialized body") }
    XCTAssertEqual(body["materializedPath"], .string(downloads.appendingPathComponent("body.html").path))
    let input = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n", addon: .init(name: "riela/apple-note-get"))
    let capability = try AppleGatewayContainerCapability(input: input, workingDirectory: root, mounts: [])
    XCTAssertThrowsError(try capability.validateDependentDownload(["file", "download", "--key", "unapproved", "--output-dir", downloads.path], approvedKeys: ["approved"]))
  }

  func testAdministrativeAddonsRunInGuestWithBoundHostCommands() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-admin-guest")
    defer { try? FileManager.default.removeItem(at: root) }
    try "".write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    let downloads = root.appendingPathComponent("tmp/downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let cases: [NativeAdminTestCase] = [
      .init(operation: .schema, config: ["role": .string("reader")],
        arguments: ["schema", "print", "--role", "reader"], stdout: "type Query { fixture: String }"),
      .init(operation: .permissionsStatus, config: [:], arguments: ["permissions", "status", "--json"], stdout: "{}"),
      .init(operation: .permissionsRequest, config: ["domain": .string("notes")],
        arguments: ["permissions", "request", "--domain", "notes"], stdout: "{}"),
      .init(operation: .configValidate, config: ["configPath": .string("config.json")],
        arguments: ["config", "validate", "--config", root.appendingPathComponent("config.json").path], stdout: "valid"),
      .init(operation: .cachePrune, config: ["all": .bool(true)], arguments: ["cache", "prune", "--all"], stdout: "{}"),
      .init(operation: .fileDownload, config: ["keys": .array([.string("fixture-key")]), "outputDir": .string(downloads.path)],
        arguments: ["file", "download", "--key", "fixture-key", "--output-dir", downloads.path], stdout: "{}"),
      .init(operation: .graphql, config: ["query": .string("query { note(noteId: \"fixture\") { id } }")],
        arguments: ["graphql", "--query", "query { note(noteId: \"fixture\") { id } }"],
        stdout: #"{"data":{"note":{"id":"fixture"}}}"#)
    ]
    for item in cases {
      let operation = item.operation
      let config = item.config
      let expected = item.arguments
      let stdout = item.stdout
      let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root),
        environment: ["RIELA_CONTAINER_RUNTIME": "docker"], workingDirectory: root, runner: BridgeGuestProcessRunner(),
        hostPlatform: .darwin, nativeAppleGatewayRunner: { arguments, _, _ in
          if operation == .configValidate {
            XCTAssertEqual(Array(arguments.prefix(3)), ["config", "validate", "--config"])
            XCTAssertTrue(arguments[3].hasPrefix("/dev/fd/"))
            XCTAssertEqual(try String(contentsOfFile: arguments[3], encoding: .utf8), "")
          } else if operation == .fileDownload {
            XCTAssertEqual(Array(arguments.prefix(5)), ["file", "download", "--key", "fixture-key", "--output-dir"])
            XCTAssertTrue(arguments[5].contains("riela-native-"))
          } else {
            XCTAssertEqual(arguments, expected)
          }
          return .init(stdout: stdout, stderr: "")
        })
      let output = try await NativeAddonPinnedDirectory.StagingContext.$root.withValue(root.deletingLastPathComponent()) {
        try await resolver.execute(.init(workflowId: "w", stepId: "s", nodeId: "n",
        addon: .init(name: operation.rawValue, version: "1", config: config, container: .init())),
        context: .init(deadline: Date().addingTimeInterval(10)))
      }
      XCTAssertEqual(output.provider, "apple-gateway")
      XCTAssertTrue(output.completionPassed)
      XCTAssertEqual(output.payload["addon"], .string(operation.rawValue))
    }
  }

  func testContainerSelectionAutomaticallyWiresScopedNativeBridge() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("container-native-bridge-wiring")
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root),
      environment: ["RIELA_CONTAINER_RUNTIME": "docker"], workingDirectory: root, runner: BridgeGuestProcessRunner(),
      hostPlatform: .darwin, nativeAppleGatewayRunner: { arguments, _, _ in
        XCTAssertTrue(arguments[2].contains("deleteNote"))
        return .init(stdout: #"{"data":{"deleteNote":{"success":true}}}"#, stderr: "")
      })
    let output = try await resolver.execute(.init(workflowId: "w", stepId: "s", nodeId: "n",
      addon: .init(name: "riela/apple-note-delete", version: "1", config: ["noteId": .string("note-1")], container: .init())),
      context: .init(deadline: Date().addingTimeInterval(10)))
    XCTAssertEqual(output.payload["deleted"], .bool(true))
    let bridges = root.appendingPathComponent(".riela/addon-container-state/bridges")
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: bridges.path).isEmpty)
  }

  func testGuestAddonUsesScopedNativeDependencyAndProcessesOutput() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-apple-bridge")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let channel = try NativeAddonBridgeChannel(directory: directory)
    let bridge = NativeAppleAddonBridge(channel: channel, capability: .init(addonName: "riela/apple-note-delete"),
      environment: [:], deadline: Date().addingTimeInterval(10), runner: { arguments, _, _ in
        XCTAssertTrue(arguments[2].contains("deleteNote"))
        return .init(stdout: #"{"data":{"deleteNote":{"success":true}}}"#, stderr: "")
      })
    let input = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n",
      addon: .init(name: "riela/apple-note-delete", version: "1", config: ["noteId": .string("note-1")]))
    let output = try await withThrowingTaskGroup(of: AdapterExecutionOutput?.self) { group in
      group.addTask { try await bridge.serve(); return nil }
      group.addTask {
        let reply = await BuiltinAddonWorker.execute(.init(operation: .execute, input: input,
          deadline: Date().addingTimeInterval(10), nativeAppleBridgeDirectory: directory.path), environment: [:], workingDirectory: root)
        return try reply.validatedOutput(for: .execute)
      }
      defer { group.cancelAll() }
      let result = try await group.next()
      return try XCTUnwrap(result ?? nil)
    }
    XCTAssertEqual(output.provider, "apple-gateway")
    XCTAssertEqual(output.payload["deleted"], .bool(true))
    XCTAssertEqual(output.when["deleted"], true)
  }

  func testGuestCannotEscalateMutationGrantOrRepeatSideEffects() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-bridge-policy")
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = try NativeAddonBridgeChannel(directory: root)
    let bridge = NativeAppleAddonBridge(channel: channel, capability: .init(addonName: "riela/apple-note-create"),
      environment: [:], deadline: Date().addingTimeInterval(10), runner: { _, _, _ in .init(stdout: "ok", stderr: "") })
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await bridge.serve() }
      group.addTask {
        let allowed = ["graphql", "--query", "mutation { createNote(input: { name: \"test\" }) { id } }"]
        let forbidden = ["graphql", "--query", "mutation { deleteNote(noteId: \"other\") { success } }"]
        XCTAssertThrowsError(try channel.call(arguments: forbidden, deadline: Date().addingTimeInterval(5))) { error in
          XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
        }
        let first = try channel.call(arguments: allowed, deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(first.stdout, "ok")
        XCTAssertThrowsError(try channel.call(arguments: allowed, deadline: Date().addingTimeInterval(5))) { error in
          XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
        }
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  func testRequestSymlinkDoesNotReadHostFile() throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-bridge-symlink")
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = try NativeAddonBridgeChannel(directory: root)
    let id = UUID()
    let secret = root.appendingPathComponent("private.json")
    try Data(#"{"private":"must not read"}"#.utf8).write(to: secret)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(id.uuidString + ".request"), withDestinationURL: secret)
    XCTAssertThrowsError(try channel.request(id))
  }
}

private struct NativeAdminTestCase {
  var operation: BuiltinAppleGatewayAdminAddon
  var config: JSONObject
  var arguments: [String]
  var stdout: String
}

private struct BridgeGuestProcessRunner: LocalProcessRunning {
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    let request = try JSONDecoder().decode(BuiltinAddonContainerRequest.self, from: Data(stdin.utf8))
    XCTAssertNotNil(request.nativeAppleBridgeDirectory)
    let root = try XCTUnwrap(configuration.workingDirectoryURL)
    let reply = await BuiltinAddonWorker.execute(request, environment: [:], workingDirectory: root)
    let data = try JSONEncoder().encode(reply)
    let stdout = try XCTUnwrap(String(data: data, encoding: .utf8))
    return .init(stdout: stdout, stderr: "", terminationStatus: 0)
  }
}
