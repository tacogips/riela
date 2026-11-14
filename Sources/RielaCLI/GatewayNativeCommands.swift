import Foundation
#if canImport(NotionGatewayCore)
import NotionGatewayCore
#endif
import GoogleGatewayAuth
import GoogleServiceGatewayCore
import WrikeGatewayCore
#if canImport(GmailGatewayCore)
import GmailGatewayCore
#endif
#if canImport(XGatewayCore)
import XGatewayCore
#endif
#if canImport(AppleGatewayCore)
import AppleGatewayCore
#endif
#if canImport(GoogleDocumentsGatewayCore)
import GoogleDocumentsGatewayCore
#endif
#if canImport(GoogleAnalyticsGatewayCore)
import GoogleAnalyticsGatewayCore
#endif

func runNativeGatewayCLI(_ invocation: GatewayCLIInvocation, environment: [String: String]) async throws -> GatewayCLIOutput {
  switch invocation.gateway {
  case .googleService:
    return try await runGoogleGatewayCLI(invocation, product: .service, environment: environment) { arguments, prepared in
      let vault = OAuthCredentialVault(store: FileCredentialStore(environment: prepared))
      let result = await AuthAdapter(vault: vault).run(arguments: arguments, environment: prepared)
      return GatewayCLIOutput(exitCode: result.exitStatus,
        stdout: result.isError ? "" : result.output + "\n", stderr: result.isError ? result.output + "\n" : "")
    }
  case .wrike:
    let addon: BuiltinWrikeGatewayAddon = invocation.role == "admin" ? .admin : invocation.role == "writer" ? .write : .read
    let frame = try WrikeGatewayCore.GatewayComposition.makeCommandFrame(role: addon.role, definitions: addon.capabilities,
      environment: StaticEnvironmentReader(extra: environment))
    let result = await frame.run(arguments: invocation.arguments)
    return GatewayCLIOutput(exitCode: result.exitCode.rawValue, stdout: result.standardOutput, stderr: result.standardError)
  case .gmail:
    #if canImport(GmailGatewayCore)
    return try await runGoogleGatewayCLI(invocation, product: .gmail, environment: environment) { arguments, prepared in
      let mode: GmailGatewayCLIMode
      let policy: GmailAuthPolicy
      switch invocation.role {
      case "draft": mode = .draftGateway; policy = .persistent(requiredAccessMode: .readSend)
      case "sender": mode = .directSender; policy = .persistent(requiredAccessMode: .readSend)
      case "threads": mode = .mailboxThreads; policy = .legacy
      case "message-box": mode = .messageBox; policy = .legacy
      default: mode = .reader; policy = .persistent(requiredAccessMode: .read)
      }
      let result = await GmailGatewayCLI(mode: mode, authPolicy: policy).runPersistent(arguments: arguments, environment: prepared)
      return GatewayCLIOutput(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }
    #else
    return unavailableGateway(invocation.gateway)
    #endif
  case .x:
    #if canImport(XGatewayCore)
    let surface: XGatewaySurface = invocation.role == "writer" ? .write : .read
    let result = XGatewayCLI(commandName: "x-gateway-\(invocation.role)", surface: surface)
      .run(arguments: invocation.arguments, environment: environment)
    return GatewayCLIOutput(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    #else
    return unavailableGateway(invocation.gateway)
    #endif
  case .notion:
    #if canImport(NotionGatewayCore)
    let result = await NotionCLI.run(arguments: invocation.arguments,
      role: invocation.role == "writer" ? .writer : .reader, environment: environment)
    return GatewayCLIOutput(exitCode: result.exitCode, stdout: result.output + "\n")
    #else
    return unavailableGateway(invocation.gateway)
    #endif
  case .apple:
    #if canImport(AppleGatewayCore)
    do {
      let result = try AppleGatewayCommand(arguments: invocation.arguments, environment: environment,
        role: invocation.role == "reader" ? .reader : .full).runResult()
      return GatewayCLIOutput(exitCode: result.exitCode, stdout: result.output + "\n")
    } catch AppleGatewayCommand.Error.invalidUsage(let message) {
      return GatewayCLIOutput(exitCode: 2, stdout: "", stderr: message + "\n")
    } catch AppleGatewayCommand.Error.unknownArgument(let argument) {
      return GatewayCLIOutput(exitCode: 2, stdout: "", stderr: "Unknown argument: \(argument)\n")
    }
    #else
    return unavailableGateway(invocation.gateway)
    #endif
  case .googleAnalytics:
    #if canImport(GoogleAnalyticsGatewayCore)
    return try await runGoogleGatewayCLI(invocation, product: .analytics, environment: environment) { arguments, prepared in
      let addon: BuiltinGoogleAnalyticsGatewayAddon = invocation.role == "admin" ? .admin : invocation.role == "writer" ? .write : .read
      let frame = try GoogleAnalyticsGatewayCore.GatewayComposition.makeCommandFrame(role: addon.role, definitions: addon.capabilities,
        environment: prepared)
      let result = await frame.run(arguments: arguments)
      return GatewayCLIOutput(exitCode: result.exitCode.rawValue, stdout: result.standardOutput, stderr: result.standardError)
    }
    #else
    return unavailableGateway(invocation.gateway)
    #endif
  case .googleDocs, .googleSheets, .googleDrive:
    #if canImport(GoogleDocumentsGatewayCore)
    let product: GatewayAuthProduct = invocation.gateway == .googleDocs ? .docs : invocation.gateway == .googleSheets ? .sheets : .drive
    return try await runGoogleGatewayCLI(invocation, product: product, environment: environment) { arguments, prepared in
      let addon: BuiltinGoogleDocumentsGatewayAddon
      switch invocation.gateway {
      case .googleDocs: addon = invocation.role == "writer" ? .docsWrite : .docsRead
      case .googleSheets: addon = invocation.role == "writer" ? .sheetWrite : .sheetRead
      default: addon = invocation.role == "writer" ? .driveWrite : .driveRead
      }
      let result = GoogleDocumentsGatewayCore.GatewayCommandRunner(role: addon.role, environment: prepared).run(arguments: arguments)
      return GatewayCLIOutput(exitCode: result.exitCode, stdout: result.stdout + "\n")
    }
    #else
    return unavailableGateway(invocation.gateway)
    #endif
  }
}

/// Use the same provider selection, shared client registration, and cleanup
/// protocol as each Google SDK executable, without calling its exit()/main().
private func runGoogleGatewayCLI(
  _ invocation: GatewayCLIInvocation,
  product: GatewayAuthProduct,
  environment: [String: String],
  operation: ([String], [String: String]) async throws -> GatewayCLIOutput
) async throws -> GatewayCLIOutput {
  let preparation: GatewayPreparation
  do {
    preparation = try GatewayAuthBootstrap().prepare(arguments: invocation.arguments, environment: environment,
      product: product, role: invocation.role)
  } catch let error as GatewayAuthError {
    return GatewayCLIOutput(exitCode: 4, stdout: "", stderr: error.description + "\n")
  }
  switch preparation {
  case let .handled(output):
    return GatewayCLIOutput(exitCode: 0, stdout: output + "\n")
  case let .invoke(prepared):
    var result = try await operation(prepared.arguments, prepared.environment)
    result.exitCode = prepared.complete(exitCode: result.exitCode)
    return result
  }
}

private func unavailableGateway(_ gateway: BuiltinGatewayCLI) -> GatewayCLIOutput {
  GatewayCLIOutput(exitCode: 1, stdout: "", stderr: "Gateway \(gateway.rawValue) is not linked on this platform.\n")
}
