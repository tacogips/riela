import Foundation
import RielaServer

struct PasskeyCommand {
  static let help = """
  Riela remote console Passkey administration (run on the server)

  Usage:
    riela auth invite <user>              Issue a one-use registration link (15 minutes).
    riela auth users                      List users and public credential IDs as JSON.
    riela auth revoke-user <user>          Disable the user, invitations and all sessions.
    riela auth revoke-key <credential-id>  Revoke one Passkey and its sessions.

  Set RIELA_WEB_ORIGIN=https://riela.example for both this command and `riela serve`.
  RIELA_WEB_AUTH_ROOT overrides the default ~/.riela/web-auth store.
  Reuse `invite <user>` to add a backup Passkey or recover after revoking a lost key.
  Registered users have full console operator access. Local mode needs no registration.
  Registration links grant access: share them privately. Private keys never reach Riela.
  RIELA_WEB_TOKEN no longer authenticates remote console requests.
  """

  func run(arguments: [String]) -> CLICommandResult {
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
      return CLICommandResult(exitCode: .success, stdout: Self.help + "\n")
    }
    do {
      let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
      let configuration = try RielaPasskeyConfiguration(origin: environment[RielaPasskeyConfiguration.originEnvironmentKey] ?? "")
      let home = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true)
      let store = RielaPasskeyStore(root: RielaPasskeyConfiguration.storeRoot(home: home, environment: environment), origin: configuration.origin)
      switch arguments.first {
      case PasskeyClientAction.invite.rawValue where arguments.count == 2:
        return CLICommandResult(exitCode: .success, stdout: try store.invite(name: arguments[1]) + "\n")
      case PasskeyClientAction.users.rawValue where arguments.count == 1:
        let users = try store.users().map { user in
          PasskeyUserListing(name: user.name, enabled: user.enabled, credentials: user.credentials.map { .init(id: $0.id, revoked: $0.revoked) })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return CLICommandResult(exitCode: .success, stdout: (String(data: try encoder.encode(users), encoding: .utf8) ?? "[]") + "\n")
      case PasskeyClientAction.revokeUser.rawValue where arguments.count == 2:
        try store.revokeUser(name: arguments[1])
      case PasskeyClientAction.revokeKey.rawValue where arguments.count == 2:
        try store.revokeCredential(id: arguments[1])
      default:
        return CLICommandResult(exitCode: .usage, stderr: Self.help)
      }
      return CLICommandResult(exitCode: .success, stdout: "Revoked. Existing sessions using this user or key are no longer accepted.\n")
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: error.localizedDescription)
    }
  }
}

private struct PasskeyUserListing: Encodable {
  struct Key: Encodable { let id: String; let revoked: Bool }
  let name: String
  let enabled: Bool
  let credentials: [Key]
}
