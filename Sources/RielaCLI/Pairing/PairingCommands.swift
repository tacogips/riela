import Foundation
import RielaCore
import RielaGraphQL
import RielaServer

enum ServePairingClientAction: String, CaseIterable {
  case mint, list, revoke
}

extension ScopedParityCommandRunner {
  func pairingResult(options: CLICommandOptions, parsed: ParsedParityOptions, homeDirectory: URL) throws -> CLICommandResult {
    guard let action = options.target.flatMap(ServePairingClientAction.init(rawValue:)) else {
      throw CLIUsageError("serve pairing requires mint, list, or revoke")
    }
    let store = serverAPIKeyStore(homeDirectory: homeDirectory)
    do {
      switch action {
      case .mint:
        guard let address = parsed.address else { throw CLIUsageError("serve pairing mint requires --address") }
        _ = try RielaPairingAddress.validate(address)
        let scope = try PairingService.scope(parsed.pairingScope)
        let code = try PairingService(store: store).mint(address: address, scope: scope)
        return CLICommandResult(exitCode: .success, stdout: code.terminalOutput)
      case .list:
        return try render(PairingService(store: store).grants(), options: options, text: renderGrants)
      case .revoke:
        guard let grantId = parsed.grant else { throw CLIUsageError("serve pairing revoke requires --grant") }
        return try render(PairingService(store: store).revoke(grantId: grantId), options: options, text: renderGrants)
      }
    } catch let error as RielaAPIKeyStore.StoreError {
      return CLICommandResult(exitCode: .failure, stderr: error.code)
    } catch let error as BotStoreError {
      return CLICommandResult(exitCode: .failure, stderr: error.code)
    }
  }

  private func renderGrants(_ result: PairingGrantListPayload) -> String {
    result.grants.map {
      let created = RoutineStore.timestamp($0.createdAt)
      let lastUsed = $0.lastUsedAt.map(RoutineStore.timestamp) ?? "-"
      let revoked = $0.revokedAt.map(RoutineStore.timestamp) ?? "-"
      return "\($0.grantId)\t\($0.clientName)\t\($0.scope)\t\(created)\t\(lastUsed)\t\(revoked)\n"
    }.joined()
  }
}
