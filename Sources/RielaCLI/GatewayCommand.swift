import Foundation

/// Gateway names belong to the delegated SDK namespace, not Riela's own auth family.
enum BuiltinGatewayCLI: String, CaseIterable, Sendable {
  case gmail, x, apple, wrike, notion
  case googleService = "google-service"
  case googleAnalytics = "google-analytics"
  case googleDocs = "google-docs"
  case googleSheets = "google-sheets"
  case googleDrive = "google-drive"

  var roles: [String] {
    switch self {
    case .gmail: ["reader", "draft", "sender", "threads", "message-box"]
    case .x, .notion, .googleDocs, .googleSheets, .googleDrive: ["reader", "writer"]
    case .apple: ["full", "reader"]
    case .wrike, .googleAnalytics: ["reader", "writer", "admin"]
    case .googleService: ["auth"]
    }
  }

  var defaultRole: String { roles[0] }

  var authentication: String {
    switch self {
    case .gmail: "auth setup|login|status|logout|revoke (persistent reader/draft/sender; legacy threads/message-box)"
    case .x: "auth oauth2|verify|scopes; OAuth2 can store credentials with --store kinko"
    case .apple: "permissions status|request; macOS permissions rather than OAuth"
    case .notion: "NOTION_API_KEY from caller environment; connect target parent page to the Notion integration"
    case .wrike: "auth oauth2|status|logout"
    case .googleService: "clients register|setup|import|list|delete; consent, scopes, auth, oauth"
    case .googleAnalytics: "auth login|oauth2|status|logout; doctor"
    case .googleDocs, .googleSheets, .googleDrive: "auth login|status|logout|revoke"
    }
  }

  var available: Bool {
    #if os(macOS)
    true
    #else
    self == .wrike || self == .googleService || self == .gmail || self == .x
    #endif
  }
}

struct GatewayCLIInvocation: Equatable, Sendable {
  var gateway: BuiltinGatewayCLI
  var role: String
  var arguments: [String]
}

struct GatewayCLIOutput: Equatable, Sendable {
  var exitCode: Int32
  var stdout: String
  var stderr: String = ""
}

typealias NativeGatewayCLIRunner = @Sendable (GatewayCLIInvocation, [String: String]) async throws -> GatewayCLIOutput

public struct GatewayCommand: Sendable {
  var runner: NativeGatewayCLIRunner

  public init() { runner = runNativeGatewayCLI }

  init(runner: @escaping NativeGatewayCLIRunner) { self.runner = runner }

  public func run(_ arguments: [String], environment: [String: String]? = nil) async -> CLICommandResult {
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] {
      return CLICommandResult(exitCode: .success, stdout: Self.help)
    }
    if arguments.first == "list" {
      guard arguments == ["list"] || arguments == ["list", "--json"] else {
        return usage("Usage: riela gateway list [--json]")
      }
      return listing(json: arguments.contains("--json"))
    }
    guard let name = arguments.first, let gateway = BuiltinGatewayCLI(rawValue: name) else {
      return usage("Unknown gateway; run 'riela gateway list'.")
    }
    var nativeArguments = Array(arguments.dropFirst())
    var role = gateway.defaultRole
    if nativeArguments.first == "--role" {
      guard nativeArguments.count >= 2 else { return usage("--role requires a gateway role") }
      role = nativeArguments[1]
      nativeArguments.removeFirst(2)
    } else if nativeArguments.first?.hasPrefix("--role=") == true {
      role = String(nativeArguments.removeFirst().dropFirst("--role=".count))
    }
    guard gateway.roles.contains(role) else {
      return usage("Gateway \(name) roles: \(gateway.roles.joined(separator: ", "))")
    }
    guard gateway.available else {
      return CLICommandResult(exitCode: .failure, stderr: "Gateway \(name) is not linked on this platform; this SDK requires macOS.\n")
    }
    if nativeArguments.isEmpty { nativeArguments = ["--help"] }
    do {
      let result = try await runner(.init(gateway: gateway, role: role, arguments: nativeArguments),
        environment ?? CLIRuntimeEnvironment.mergedProcessEnvironment())
      // Native diagnostics stay intact; gateway errors use Riela's ordinary
      // failure status rather than colliding with its gate/suspension exit codes.
      return CLICommandResult(exitCode: result.exitCode == 0 ? .success : .failure,
        stdout: result.stdout, stderr: result.stderr)
    } catch {
      return CLICommandResult(exitCode: .failure,
        stderr: "Gateway \(name) could not initialize its native command; check its configuration and credentials.\n")
    }
  }

  private func usage(_ message: String) -> CLICommandResult {
    CLICommandResult(exitCode: .usage, stderr: message + "\n")
  }

  private func listing(json: Bool) -> CLICommandResult {
    if json {
      let rows: [[String: Any]] = BuiltinGatewayCLI.allCases.map {
        ["name": $0.rawValue, "roles": $0.roles, "defaultRole": $0.defaultRole,
         "available": $0.available, "authentication": $0.authentication, "execution": "linked-sdk"]
      }
      guard let data = try? JSONSerialization.data(withJSONObject: ["gateways": rows], options: [.sortedKeys]),
            let output = String(data: data, encoding: .utf8) else {
        return CLICommandResult(exitCode: .failure, stderr: "Could not encode gateway catalog.\n")
      }
      return CLICommandResult(exitCode: .success, stdout: output + "\n")
    }
    let rows = BuiltinGatewayCLI.allCases.map {
      "\($0.rawValue) [\($0.roles.joined(separator: "|"))]\($0.available ? "" : " (unavailable on this platform)")\n  \($0.authentication)"
    }
    return CLICommandResult(exitCode: .success, stdout: "Delegated builtin gateway commands (linked SDKs):\n" + rows.joined(separator: "\n") + "\n")
  }

  static let help = """
  Usage: riela gateway list [--json]
         riela gateway <name> [--role ROLE] <gateway-command> [gateway-options...]

  Commands after the gateway name are owned by that gateway's linked SDK.
  --role must precede the native command. Default roles are reader, Apple full,
  and Google Service auth. Run 'riela gateway list' for roles and auth operations.
  Native --help displays the gateway's original usage (including its binary name).
  No standalone gateway binary is launched. Browser/Kinko/gcloud helpers remain
  owned by the selected SDK authentication flow.

  Examples:
    riela gateway gmail auth login --credential gmail-personal
    riela gateway gmail auth status --credential gmail-personal
    riela gateway x auth oauth2 --store kinko
    riela gateway apple permissions status --json
    riela gateway google-service clients register --file /path/to/client.json
    riela gateway google-docs --role writer auth login --credential docs-writer

  'riela auth' remains Riela's own passkey authentication.

  """
}
