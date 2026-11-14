import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class GatewayContainerImageIntegrationTests: XCTestCase {
  func testRealGmailImageExecutesOfflineAccountQueryWithMountedConfiguration() async throws {
    try requireLiveImages()
    let root = try makeRielaCLITestTemporaryDirectory("gmail-container-image")
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    [storage]
    cache_dir = "/tmp/cache"
    attachment_dir = "/tmp/attachments"
    allowed_send_attachment_roots = ["/tmp/send"]
    [[credentials]]
    id = "probe"
    provider = "gmail"
    access_mode = "read"
    oauth_client_secret_path = "/fixture/client.json"
    token_store_path = "/fixture/token.json"
    [[accounts]]
    id = "probe-account"
    provider = "gmail"
    email_address = "probe@example.invalid"
    credential_id = "probe"
    default_label_ids = ["INBOX"]
    """.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let input = WorkflowAddonExecutionInput(workflowId: "probe", stepId: "accounts", nodeId: "accounts",
      addon: .init(name: "riela/gmail-gateway-read", version: "1", config: [
        "queryTemplate": .string("query { accounts { id } }"), "networkPolicy": .string("denied"),
        "mounts": .array([.object(["source": .string(root.path), "target": .string("/fixture")])])
      ], env: ["GMAIL_GATEWAY_CONFIG": .object(["fromEnv": .string("CONFIG_PATH")])]))
    let output = try await ContainerGatewayAddonExecutor(environment: ["RIELA_CONTAINER_RUNTIME": "container", "CONFIG_PATH": "/fixture/config.toml"],
      workingDirectory: root, runner: FoundationLocalProcessRunner()).execute(input, gateway: .gmailRead,
        context: .init(deadline: Date().addingTimeInterval(300)))
    XCTAssertEqual(output.provider, "container-addon")
    guard case let .object(gateway)? = output.payload["gmailGateway"], case let .object(response)? = gateway["data"],
          case let .object(data)? = response["data"], case let .array(accounts)? = data["accounts"] else {
      return XCTFail("missing Gmail account response")
    }
    guard case let .object(account)? = accounts.first else { return XCTFail("missing configured account") }
    XCTAssertEqual(accounts.count, 1)
    XCTAssertEqual(account["id"], .string("probe-account"))
    XCTAssertEqual(account["isFallback"], .bool(false))
    XCTAssertEqual(account["emailAddress"], .string("probe@example.invalid"))
  }

  func testReaderImagesRejectMutationsWithoutNetworkOrCredentials() async throws {
    try requireLiveImages()
    let root = try makeRielaCLITestTemporaryDirectory("gateway-readonly-image")
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = try XCTUnwrap(ContainerRuntimeDiscovery(environment: ["RIELA_CONTAINER_RUNTIME": "container"]).configuredDriver())
    for gateway in [ContainerGatewayAddon.xRead, .gmailRead] {
      let query = gateway == .xRead ? "mutation { createPost(text: \"must not send\") { id } }" : "mutation { sendMessage { id } }"
      let arguments = driver.runArguments(image: gateway.defaultImage,
        options: .init(environment: [:], mounts: [], entrypoint: gateway.entrypoint, workingDirectory: nil,
          networkAllowed: false, readOnlyRootFilesystem: true)) + gateway.arguments(document: query)
      let result = try await FoundationLocalProcessRunner().run(configuration: .init(executableURL: URL(fileURLWithPath: driver.executable),
        arguments: arguments, environment: [:], workingDirectoryURL: root), stdin: "", deadline: Date().addingTimeInterval(300))
      XCTAssertNotEqual(result.terminationStatus, 0)
      XCTAssertTrue(result.stdout.lowercased().contains("mutation") || result.stderr.lowercased().contains("mutation"))
    }
  }

  private func requireLiveImages() throws {
    try XCTSkipUnless(RielaHostPlatform.current == .darwin, "Apple Container integration requires Darwin")
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RIELA_TEST_LIVE_GATEWAY_IMAGES"] == "1", "opt-in built gateway image integration")
  }
}
