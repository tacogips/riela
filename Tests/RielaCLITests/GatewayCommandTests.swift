import Foundation
import XCTest
import RielaCore
@testable import RielaCLI

final class GatewayCommandTests: XCTestCase {
  func testGatewaySurfaceCatalogMatchesDelegatedRoutes() {
    let commands = CLISurfaceEnumerator.commands().filter { $0.path.first == "gateway" }
    let catalog = SurfaceCatalog.operations(inFamily: "gateway")
    XCTAssertTrue(CLISurfaceEnumerator.violations(commands: commands, catalog: catalog).isEmpty)
    XCTAssertFalse(CLISurfaceEnumerator.unclassifiedRoutes().contains("gateway"))
  }

  func testParserPreservesNativeArgumentsUnderGatewayNamespace() throws {
    let native = ["gmail", "--role", "sender", "auth", "login", "--credential", "profile with spaces", "--no-open"]
    XCTAssertEqual(try RielaArgumentParser().parse(["gateway"] + native), .gateway(native))
    XCTAssertEqual(try RielaArgumentParser().parse(["gateway", "x", "auth", "scopes", "--json"]),
      .gateway(["x", "auth", "scopes", "--json"]))
  }

  func testEveryProviderAndRoleDispatchesNativeArgumentsAndExplicitEnvironment() async throws {
    let recorder = GatewayCLIRecorder()
    let command = GatewayCommand(runner: { invocation, environment in await recorder.run(invocation, environment: environment) })
    for gateway in BuiltinGatewayCLI.allCases where gateway.available {
      for role in gateway.roles {
        let result = await command.run([gateway.rawValue, "--role", role, "auth", "status", "--native-option=a b"],
          environment: ["SYNTHETIC_SOURCE": "fixture"])
        XCTAssertEqual(result.exitCode, .success)
        let call = await recorder.lastCall
        XCTAssertEqual(call?.0, .init(gateway: gateway, role: role, arguments: ["auth", "status", "--native-option=a b"]))
        XCTAssertEqual(call?.1, ["SYNTHETIC_SOURCE": "fixture"])
      }
    }
  }

  func testInvalidGatewayAndRoleDoNotInvokeSDK() async {
    let recorder = GatewayCLIRecorder()
    let command = GatewayCommand(runner: { invocation, environment in await recorder.run(invocation, environment: environment) })
    for arguments in [["unknown", "auth", "login"], ["gmail", "--role"], ["gmail", "--role", "admin", "auth", "login"],
                      ["list", "--unknown"], ["apple", "--role=sender", "permissions", "status"]] {
      let result = await command.run(arguments, environment: [:])
      XCTAssertEqual(result.exitCode, .usage)
    }
    let count = await recorder.count
    XCTAssertEqual(count, 0)
  }

  func testRoleIsOnlyInterpretedBeforeNativeCommandAndMissingCommandRequestsHelp() async throws {
    let recorder = GatewayCLIRecorder()
    let command = GatewayCommand(runner: { invocation, environment in await recorder.run(invocation, environment: environment) })
    _ = await command.run(["wrike", "auth", "status", "--role", "native-value"], environment: [:])
    var call = await recorder.lastCall
    XCTAssertEqual(call?.0.role, "reader")
    XCTAssertEqual(call?.0.arguments, ["auth", "status", "--role", "native-value"])
    _ = await command.run(["wrike", "--role=writer"], environment: [:])
    call = await recorder.lastCall
    XCTAssertEqual(call?.0.role, "writer")
    XCTAssertEqual(call?.0.arguments, ["--help"])
  }

  func testCatalogAndApplicationHelpKeepGatewayOwnershipVisible() async throws {
    let result = await RielaCLIApplication().run(["gateway", "list", "--json"])
    XCTAssertEqual(result.exitCode, .success)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    let gateways = try XCTUnwrap(object["gateways"] as? [[String: Any]])
    XCTAssertEqual(Set(gateways.compactMap { $0["name"] as? String }), Set(BuiltinGatewayCLI.allCases.map(\.rawValue)))
    XCTAssertTrue(gateways.allSatisfy { $0["execution"] as? String == "linked-sdk" })
    let help = await RielaCLIApplication().run(["gateway"])
    XCTAssertTrue(help.stdout.contains("owned by that gateway's linked SDK"))
    XCTAssertTrue(help.stdout.contains("'riela auth' remains"))
  }

  func testNativeFailurePreservesDiagnosticsWithoutUsingRielaSuspensionStatus() async {
    let result = await GatewayCommand(runner: { _, _ in
      GatewayCLIOutput(exitCode: 5, stdout: "provider-json\n", stderr: "provider-diagnostic\n")
    }).run(["wrike", "auth", "status"], environment: [:])
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertEqual(result.stdout, "provider-json\n")
    XCTAssertEqual(result.stderr, "provider-diagnostic\n")
  }

  func testRealLinkedGatewayHelpForEveryRoleNeedsNoExternalGatewayExecutable() async throws {
    for gateway in BuiltinGatewayCLI.allCases where gateway.available {
      for role in gateway.roles {
        let result = await GatewayCommand().run([gateway.rawValue, "--role", role, "--help"], environment: ["PATH": "/nonexistent"])
        XCTAssertEqual(result.exitCode, .success, "\(gateway.rawValue)/\(role): \(result.stderr)")
        XCTAssertFalse(result.stdout.isEmpty, "\(gateway.rawValue)/\(role)")
      }
    }
  }

  func testSharedGoogleClientBootstrapHelpIsAvailableThroughServiceGateway() async {
    let result = await GatewayCommand().run(["google-service", "clients", "register", "--help"], environment: ["PATH": "/nonexistent"])
    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stdout.contains("clients register"))
    XCTAssertTrue(result.stdout.contains("--product"))
  }

  #if os(macOS)
  func testNativeGmailPersistentStatusUsesInlineBindingAndDoesNotPrintTokens() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("gateway-auth-status")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = [
      "PATH": "/nonexistent", "HOME": root.path, "XDG_STATE_HOME": root.path,
      "GMAIL_GATEWAY_CREDENTIAL_DIR": root.path,
      "GMAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_OAUTH_CLIENT_SECRET_JSON":
        #"{"installed":{"client_id":"fixture","client_secret":"private-client-fixture","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","redirect_uris":["http://localhost"]}}"#,
      "GMAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_JSON":
        #"""
        {"schemaVersion":1,"provider":"gmail","credentialId":"gmail-personal",
        "clientFingerprint":"9d9d3413483b2cfc5665b9b3e83a757e9430a852bb4cb4e54b3eab261971f9e1",
        "accessMode":"read","accessToken":"private-access-fixture","refreshToken":null,"tokenType":"Bearer",
        "scope":"https://www.googleapis.com/auth/gmail.readonly","expiresAt":"2999-01-01T00:00:00Z","emailAddress":"probe@example.invalid"}
        """#
    ]
    let result = await GatewayCommand().run(["gmail", "auth", "status", "--credential", "gmail-personal"], environment: environment)
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains("ENVIRONMENT_JSON"), result.stdout)
    XCTAssertFalse((result.stdout + result.stderr).contains("private-access-fixture"))
    XCTAssertFalse((result.stdout + result.stderr).contains("private-client-fixture"))
  }

  func testNativeXHomeTimelineAcceptsBoundsBeforeAuthentication() async {
    let document = """
    { homeTimeline(startTime: "2026-10-16T15:00:00Z", endTime: "2026-10-17T15:00:00Z",
      sinceId: "123", untilId: "456", paginationToken: "page-two") { posts { id } pageInfo { nextToken } } }
    """
    let result = await GatewayCommand().run(["x", "graphql", "query", document, "--json"], environment: ["PATH": "/nonexistent"])
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("homeTimeline requires X_GW_TOKEN"), result.stderr)
    XCTAssertFalse(result.stderr.contains("Unsupported argument"), result.stderr)
  }

  func testNativeXAuthScopesDoesNotPrintCredentialValues() async {
    let result = await GatewayCommand().run(["x", "auth", "scopes", "--json"],
      environment: ["PATH": "/nonexistent", "X_GW_TOKEN": "private-x-fixture"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains("scope"), result.stdout)
    XCTAssertFalse((result.stdout + result.stderr).contains("private-x-fixture"))
  }
  #endif
}

private actor GatewayCLIRecorder {
  var count = 0
  var lastCall: (GatewayCLIInvocation, [String: String])?

  func run(_ invocation: GatewayCLIInvocation, environment: [String: String]) -> GatewayCLIOutput {
    count += 1
    lastCall = (invocation, environment)
    return GatewayCLIOutput(exitCode: 0, stdout: "native-output\n")
  }
}
