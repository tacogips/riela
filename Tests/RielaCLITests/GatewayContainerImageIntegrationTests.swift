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
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
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
    var bindings: JSONObject = ["GMAIL_GATEWAY_CONFIG": .object(["fromEnv": .string("CONFIG_PATH")])]
    let credentials = syntheticCredentials(credentialID: "probe")
    for name in credentials.keys { bindings[name] = .object(["fromEnv": .string(name)]) }
    let input = WorkflowAddonExecutionInput(workflowId: "probe", stepId: "accounts", nodeId: "accounts",
      addon: .init(name: "riela/gmail-gateway-read", version: "1", config: [
        "queryTemplate": .string("query { accounts { id isFallback emailAddress } }"), "networkPolicy": .string("denied"),
        "mounts": .array([.object(["source": .string(root.path), "target": .string("/fixture")])])
      ], env: bindings))
    var environment = ProcessInfo.processInfo.environment.merging(credentials) { _, fixture in fixture }
    environment["RIELA_CONTAINER_RUNTIME"] = liveRuntime
    environment["CONFIG_PATH"] = "/fixture/config.toml"
    let output = try await ContainerGatewayAddonExecutor(environment: environment,
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
    let driver = try XCTUnwrap(ContainerRuntimeDiscovery(environment: ["RIELA_CONTAINER_RUNTIME": liveRuntime]).configuredDriver())
    for gateway in [ContainerGatewayAddon.xRead, .gmailRead] {
      let query = gateway == .xRead ? "mutation { createPost(text: \"must not send\") { id } }" : #"mutation { sendMessage(input: { accountId: "personal", to: ["a@example.test"], textBody: "x" }) { status } }"#
      let arguments = driver.runArguments(image: gateway.defaultImage,
        options: .init(environment: [:], mounts: [], entrypoint: gateway.entrypoint, workingDirectory: nil,
          networkAllowed: false, readOnlyRootFilesystem: true)) + gateway.arguments(document: query)
      let result = try await FoundationLocalProcessRunner().run(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [driver.executable] + arguments, environment: [:], workingDirectoryURL: root), stdin: "", deadline: Date().addingTimeInterval(300))
      XCTAssertNotEqual(result.terminationStatus, 0)
      if gateway == .gmailRead {
        XCTAssertTrue(result.stdout.contains("CAPABILITY_DENIED"), result.stdout)
      } else {
        XCTAssertTrue(result.stdout.lowercased().contains("mutation") || result.stderr.lowercased().contains("mutation"), result.stdout + result.stderr)
      }
    }
  }

  func testGmailImageCreatesPrivateCredentialLifecycleLockWithReadOnlyRoot() async throws {
    try requireLiveImages()
    let root = try makeRielaCLITestTemporaryDirectory("gmail-container-lock")
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = try XCTUnwrap(ContainerRuntimeDiscovery(environment: ["RIELA_CONTAINER_RUNTIME": liveRuntime]).configuredDriver())
    // Synthetic credentials reach the production lock before a deliberately denied
    // network request. No provider credentials or external API calls are needed.
    let bindings = syntheticCredentials(credentialID: "gmail-personal")
    let script = """
    set -eu
    test "$(id -u)" = 10001
    if touch /root-write-probe 2>/dev/null; then exit 1; fi
    set +e
    gmail-gateway-reader graphql --query '{ threads(input: { accountId: "personal" }) { totalCount } }' >/tmp/result.json 2>/tmp/error.txt
    status=$?
    set -e
    test "$status" -ne 0
    test -f /tmp/riela-gmail/.local/state/gmail-gateway/auth-locks/gmail-personal-read.lock
    test "$(stat -c %a /tmp/riela-gmail)" = 700
    test "$(stat -c %a /tmp/riela-gmail/.local/state/gmail-gateway/auth-locks/gmail-personal-read.lock)" = 600
    if grep -q 'cannot lock persistent credential lifecycle\\|persistent credentials require re-login' /tmp/result.json /tmp/error.txt; then exit 1; fi
    printf 'private-credential-lock-ok'
    """
    let arguments = driver.runArguments(image: ContainerGatewayAddon.gmailRead.defaultImage,
      options: .init(environment: bindings, mounts: [], entrypoint: "/bin/sh", workingDirectory: nil,
        networkAllowed: false, readOnlyRootFilesystem: true, environmentValuesFromProcess: true, disablePersistentLogs: true))
    let result = try await FoundationLocalProcessRunner().run(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [driver.executable] + arguments + ["-c", script], environment: bindings, workingDirectoryURL: root),
      stdin: "", deadline: Date().addingTimeInterval(120))
    XCTAssertEqual(result.terminationStatus, 0, result.stderr)
    XCTAssertEqual(result.stdout, "private-credential-lock-ok")
  }

  func testXImageExposesIncrementalRecentSearchWithoutCredentials() async throws {
    try requireLiveImages()
    let root = try makeRielaCLITestTemporaryDirectory("x-incremental-schema")
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = try XCTUnwrap(ContainerRuntimeDiscovery(environment: ["RIELA_CONTAINER_RUNTIME": liveRuntime]).configuredDriver())
    let arguments = driver.runArguments(image: ContainerGatewayAddon.xRead.defaultImage,
      options: .init(environment: [:], mounts: [], entrypoint: "x-gateway-reader", workingDirectory: nil,
        networkAllowed: false, readOnlyRootFilesystem: true, disablePersistentLogs: true)) + ["graphql", "schema"]
    let result = try await FoundationLocalProcessRunner().run(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [driver.executable] + arguments, environment: [:], workingDirectoryURL: root), stdin: "", deadline: Date().addingTimeInterval(300))
    XCTAssertEqual(result.terminationStatus, 0, result.stderr)
    XCTAssertTrue(result.stdout.contains("searchPosts(query: String!, maxResults: Int, sinceId: String, nextToken: String"))
  }

  private func syntheticCredentials(credentialID: String) -> [String: String] {
    let suffix = credentialID.replacingOccurrences(of: "-", with: "_").uppercased()
    return [
      "GMAIL_GATEWAY_CREDENTIAL_\(suffix)_OAUTH_CLIENT_SECRET_JSON":
        #"{"installed":{"client_id":"fixture","client_secret":"fixture","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","redirect_uris":["http://localhost"]}}"#,
      // Fingerprint binds this synthetic token to the normalized client above.
      "GMAIL_GATEWAY_CREDENTIAL_\(suffix)_TOKEN_STORE_JSON":
        #"""
        {"schemaVersion":1,"provider":"gmail","credentialId":"\#(credentialID)",
        "clientFingerprint":"9d9d3413483b2cfc5665b9b3e83a757e9430a852bb4cb4e54b3eab261971f9e1",
        "accessMode":"read","accessToken":"fixture","refreshToken":null,"tokenType":"Bearer",
        "scope":"https://www.googleapis.com/auth/gmail.readonly","expiresAt":"2999-01-01T00:00:00Z","emailAddress":"probe@example.invalid"}
        """#
    ]
  }

  private var liveRuntime: String {
    ProcessInfo.processInfo.environment["RIELA_TEST_GATEWAY_RUNTIME"] ?? "container"
  }

  private func requireLiveImages() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RIELA_TEST_LIVE_GATEWAY_IMAGES"] == "1", "opt-in built gateway image integration")
    if liveRuntime == "container" {
      try XCTSkipUnless(RielaHostPlatform.current == .darwin, "Apple Container integration requires Darwin")
    }
  }
}
