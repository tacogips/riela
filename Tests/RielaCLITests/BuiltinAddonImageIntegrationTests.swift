import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

/// Run after rebuilding the first-party worker image from current sources.
final class BuiltinAddonImageIntegrationTests: XCTestCase {
  private var workerImage: String {
    ProcessInfo.processInfo.environment["RIELA_TEST_BUILTIN_IMAGE"] ?? WorkflowAddonContainerExecution.defaultImage
  }

  func testDocumentConverterRunsNativeLibraryInsideRealGuest() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("converter-container")
    defer { try? FileManager.default.removeItem(at: root) }
    let document = root.appendingPathComponent("report.csv")
    try Data("name,value\nalpha,1\n".utf8).write(to: document)
    let output = try await makeResolver(root).execute(.init(workflowId: "fixture", stepId: "convert", nodeId: "convert",
      addon: .init(name: "riela/file-markdown-convert", version: "1",
        inputs: ["path": .string(document.path)],
        container: .init(image: workerImage, runtime: .appleContainer, networkPolicy: .denied))),
      context: .init(deadline: Date().addingTimeInterval(120)))
    XCTAssertEqual(output.payload["markdown"], .string("| name | value |\n| --- | --- |\n| alpha | 1 |\n"))
    XCTAssertEqual(output.payload["convertedCount"], .integer(1))
    XCTAssertEqual(output.provider, "anydoc-swift")
  }

  func testGoogleServiceSDKEnforcesCapabilityAndCredentialBoundariesInGuest() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("google-service-container")
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = makeResolver(root)
    let cases = [
      ("riela/google-service-gateway-read", "services.enable", "does not allow operation"),
      ("riela/google-service-gateway-write", "services.get", "does not allow operation"),
      ("riela/google-service-gateway-read", "services.get", "requires addon.env.GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"),
      ("riela/google-service-gateway-write", "services.enable", "requires addon.env.GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN")
    ]
    for (name, operation, message) in cases {
      do {
        _ = try await resolver.execute(.init(workflowId: "fixture", stepId: "service", nodeId: "service",
          addon: .init(name: name, version: "1", config: ["operation": .string(operation)],
            container: .init(image: workerImage, runtime: .appleContainer, networkPolicy: .denied))),
          context: .init(deadline: Date().addingTimeInterval(120)))
        XCTFail("guest must enforce Google Service capability and credential boundaries")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .policyBlocked)
        XCTAssertTrue(error.message.contains(message), error.message)
      }
    }
  }

  func testGoogleDocumentsRolesPlanRequestsWithoutCredentialsOrNetwork() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("documents-sdk-container")
    defer { try? FileManager.default.removeItem(at: root) }
    let cases: [String: (command: String, flags: JSONObject)] = [
      "riela/google-docs-gateway-read": ("document get", ["document-id": .string("fixture")]),
      "riela/google-docs-gateway-write": ("document create", ["title": .string("fixture")]),
      "riela/google-sheet-gateway-read": ("spreadsheet get", ["spreadsheet-id": .string("fixture")]),
      "riela/google-sheet-gateway-write": ("spreadsheet create", ["title": .string("fixture")]),
      "riela/google-drive-gateway-read": ("files get", ["file-id": .string("fixture")]),
      "riela/google-drive-gateway-write": ("folders create", ["name": .string("fixture")])
    ]
    for name in cases.keys.sorted() {
      let fixture = try XCTUnwrap(cases[name])
      var flags = fixture.flags
      flags["dry-run"] = .bool(true)
      let output = try await makeResolver(root).execute(.init(workflowId: "probe", stepId: "plan", nodeId: "plan",
        addon: .init(name: name, version: "1", config: ["command": .string(fixture.command), "argsTemplate": .object(flags)],
          container: .init(image: workerImage, runtime: .appleContainer, networkPolicy: .denied))),
        context: .init(deadline: Date().addingTimeInterval(300)))
      XCTAssertEqual(output.provider, "google-documents-gateway")
      guard case let .object(data)? = output.payload["data"], case let .object(meta)? = data["meta"] else { return XCTFail("missing dry-run plan") }
      XCTAssertEqual(data["dryRun"], .bool(true))
      XCTAssertEqual(meta["tokenLoaded"], .bool(false))
      XCTAssertEqual(meta["transportCalled"], .bool(false))
    }
  }

  func testGoogleAnalyticsSDKEnforcesTiersAndRequiresCredentialsInGuest() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("analytics-sdk-container")
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = makeResolver(root)
    try await assertGuestFailure(resolver, name: "riela/google-analytics-gateway-read",
      document: "mutation { gtmCreateContainer(parent: \"accounts/1\", container: { name: \"must not create\" }) { container { accountId } } }",
      contains: "requires the writer capability tier")
    try await assertGuestFailure(resolver, name: "riela/google-analytics-gateway-write",
      document: "mutation { gtmDeleteContainer(path: \"accounts/1/containers/2\") { success } }",
      contains: "requires the admin capability tier")
    try await assertGuestFailure(resolver, name: "riela/google-analytics-gateway-admin",
      document: "query { gtmAccount(path: \"accounts/1\") { accountId } }", contains: "No environment access token")
  }

  private func assertGuestFailure(_ resolver: BuiltinAddonContainerResolver, name: String, document: String, contains message: String) async throws {
    do {
      _ = try await resolver.execute(input(name, document: document), context: .init(deadline: Date().addingTimeInterval(300)))
      XCTFail("guest must enforce capability and credential boundaries")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertTrue(error.message.contains(message), error.message)
    }
  }

  func testAppleBodyFileMaterializesAcrossExplicitGuestMount() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("native-body-container")
    let downloads = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: downloads)
    }
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root),
      environment: [:], workingDirectory: root, nativeAppleGatewayRunner: { arguments, _, _ in
        if arguments[0] == "graphql" {
          return .init(stdout: #"{"data":{"note":{"id":"fixture","bodyFile":{"downloadKey":"approved"}}}}"#, stderr: "")
        }
        XCTAssertEqual(Array(arguments.prefix(5)), ["file", "download", "--key", "approved", "--output-dir"])
        let path = arguments[5] + "/body.html"
        try Data("<p>body</p>".utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        return .init(stdout: #"{"files":[{"downloadKey":"approved","path":"\#(path)"}]}"#, stderr: "")
      })
    let output = try await NativeAddonPinnedDirectory.StagingContext.$root.withValue(root.deletingLastPathComponent()) {
      try await resolver.execute(.init(workflowId: "probe", stepId: "body", nodeId: "body",
        addon: .init(name: "riela/apple-note-get", version: "1", config: ["noteId": .string("fixture"),
          "materializeBody": .bool(true), "downloadDir": .string("/tmp/native-downloads")],
          container: .init(image: workerImage, runtime: .appleContainer, networkPolicy: .denied,
            mounts: [.init(source: downloads.path, target: "/tmp/native-downloads", readOnly: false)]))),
        context: .init(deadline: Date().addingTimeInterval(300)))
    }
    XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("body.html"), encoding: .utf8), "<p>body</p>")
    guard case let .object(note)? = output.payload["appleNote"], case let .object(body)? = note["body"] else { return XCTFail("missing body output") }
    XCTAssertEqual(body["materializedPath"], .string("/tmp/native-downloads/body.html"))
  }

  func testAppleSchemaUsesRealNativeGatewayFromGuest() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("native-schema-container")
    defer { try? FileManager.default.removeItem(at: root) }
    let output = try await makeResolver(root).execute(.init(workflowId: "probe", stepId: "schema", nodeId: "schema",
      addon: .init(name: "riela/apple-gateway-schema", version: "1", config: ["role": .string("reader")],
        container: .init(image: workerImage, runtime: .appleContainer, networkPolicy: .denied))),
      context: .init(deadline: Date().addingTimeInterval(300)))
    XCTAssertEqual(output.provider, "apple-gateway")
    guard case let .object(gateway)? = output.payload["appleGateway"],
          case let .string(schema)? = gateway["schemaSDL"] else { return XCTFail("missing real native schema") }
    XCTAssertTrue(schema.contains("type Query"))
    XCTAssertEqual(gateway["role"], .string("reader"))
  }

  func testAppleAddonExecutesInRealGuestUsingScopedHostDependency() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("apple-api-container")
    defer { try? FileManager.default.removeItem(at: root) }
    // The add-on runs in the real guest; only the native API is substituted.
    // This verifies transport without deleting any real user data.
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root),
      environment: [:], workingDirectory: root, nativeAppleGatewayRunner: { arguments, _, _ in
        XCTAssertEqual(arguments[0], "graphql")
        XCTAssertTrue(arguments[2].contains("deleteNote"))
        return .init(stdout: #"{"data":{"deleteNote":{"success":true}}}"#, stderr: "")
      })
    let output = try await resolver.execute(.init(workflowId: "probe", stepId: "delete", nodeId: "delete",
      addon: .init(name: "riela/apple-note-delete", version: "1", config: ["noteId": .string("fixture-note")],
        container: .init(image: workerImage, runtime: .appleContainer, networkPolicy: .denied))),
      context: .init(deadline: Date().addingTimeInterval(300)))
    XCTAssertEqual(output.provider, "apple-gateway")
    XCTAssertEqual(output.payload["deleted"], .bool(true))
    XCTAssertEqual(output.when["deleted"], true)
  }

  func testGmailSDKModesExecuteOfflineInsideWorkerImage() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("gmail-sdk-container")
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = makeResolver(root)
    for name in ["riela/gmail-gateway-reader", "riela/gmail-gateway-draft", "riela/gmail-gateway-sender"] {
      let output = try await resolver.execute(input(name, document: "query { accounts { id } }"),
        context: .init(deadline: Date().addingTimeInterval(300)))
      XCTAssertEqual(output.provider, "gmail-gateway")
      guard case let .object(data)? = output.payload["data"], case let .array(accounts)? = data["accounts"],
            case let .object(account)? = accounts.first else { return XCTFail("missing guest account metadata") }
      XCTAssertEqual(account["id"], .string("personal"))
      guard case let .object(gateway)? = output.payload["gmailGateway"],
            case let .object(runtime)? = gateway["runtime"] else { return XCTFail("missing guest SDK provenance") }
      XCTAssertEqual(runtime["mode"], .string("in-process"))
      XCTAssertEqual(runtime["tier"], .string(String(name.dropFirst("riela/".count))))
    }
  }

  func testWrikeSDKCannotEscalateReaderOrWriterInsideWorkerImage() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("wrike-sdk-container")
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = makeResolver(root)
    let cases = [
      ("riela/wrike-gateway-read", "mutation { createTask(folderId: \"unused\", title: \"must not create\") { id } }", "writer"),
      ("riela/wrike-gateway-write", "mutation { deleteTask(taskId: \"must not delete\") { id } }", "admin")
    ]
    for (name, document, tier) in cases {
      do {
        _ = try await resolver.execute(input(name, document: document), context: .init(deadline: Date().addingTimeInterval(300)))
        XCTFail("guest must reject tier escalation")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .providerError)
        XCTAssertTrue(error.message.contains("requires the " + tier + " capability tier"), error.message)
      }
    }
    do {
      _ = try await resolver.execute(input("riela/wrike-gateway-admin", document: "query { account { id } }"),
        context: .init(deadline: Date().addingTimeInterval(300)))
      XCTFail("guest admin must require explicit credentials")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertTrue(error.message.contains("No Wrike credential is available"), error.message)
    }
  }

  private func input(_ name: String, document: String) -> WorkflowAddonExecutionInput {
    .init(workflowId: "probe", stepId: "gateway", nodeId: "gateway",
      addon: .init(name: name, version: "1", config: ["queryTemplate": .string(document)],
        container: .init(image: workerImage, runtime: .appleContainer, networkPolicy: .denied)))
  }

  private func makeResolver(_ root: URL) -> BuiltinAddonContainerResolver {
    BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self), primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root),
      environment: [:], workingDirectory: root)
  }

  private func requireImage() throws {
    try XCTSkipUnless(RielaHostPlatform.current == .darwin, "Apple Container integration requires Darwin")
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RIELA_TEST_LIVE_BUILTIN_IMAGE"] == "1", "opt-in rebuilt worker image integration")
  }
}
