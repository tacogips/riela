import Foundation
import GmailGatewayCore
import RielaAddonSupport
import RielaCore

/// Built-in add-ons that run the sibling gmail-gateway package's CLI surface
/// inside this process. The tier is a mode the gateway enforces (reader is
/// read-only, draft turns sendMessage/replyMessage/forwardMessage into provider
/// drafts, sender performs direct sends), and each add-on pins one mode, so the
/// workflow cannot escalate through inputs or payload data.
///
/// These are distinct from `riela/gmail-gateway-read` / `riela/gmail-gateway`,
/// which are container-backed add-ons resolved outside this process.
enum BuiltinGmailGatewayCLIAddon: String {
  case reader = "riela/gmail-gateway-reader"
  case draft = "riela/gmail-gateway-draft"
  case sender = "riela/gmail-gateway-sender"

  var mode: GmailGatewayCLIMode {
    switch self {
    case .reader:
      .reader
    case .draft:
      .draftGateway
    case .sender:
      .directSender
    }
  }

  var tier: String {
    switch self {
    case .reader:
      "gmail-gateway-reader"
    case .draft:
      "gmail-gateway-draft"
    case .sender:
      "gmail-gateway-sender"
    }
  }

  /// gmail-gateway derives credential variable names from config credential
  /// ids (`GMAIL_GATEWAY_CREDENTIAL_<SUFFIX>_...`), so the allowlist is a
  /// shape check instead of a fixed set: the config path variable, the
  /// credential-directory variable, plus the four credential-material forms
  /// for any credential suffix.
  static func isAllowedTargetEnvironmentName(_ name: String) -> Bool {
    if name == "GMAIL_GATEWAY_CONFIG" || name == "GMAIL_GATEWAY_CREDENTIAL_DIR" {
      return true
    }
    let prefix = "GMAIL_GATEWAY_CREDENTIAL_"
    guard name.hasPrefix(prefix) else {
      return false
    }
    let remainder = name.dropFirst(prefix.count)
    let credentialSuffixes = [
      "_OAUTH_CLIENT_SECRET_PATH",
      "_OAUTH_CLIENT_SECRET_JSON",
      "_TOKEN_STORE_PATH",
      "_TOKEN_STORE_JSON"
    ]
    guard let suffix = credentialSuffixes.first(where: { remainder.hasSuffix($0) }) else {
      return false
    }
    let credentialPart = remainder.dropLast(suffix.count)
    return !credentialPart.isEmpty && credentialPart.allSatisfy { character in
      character == "_" || character.isNumber || (character.isLetter && character.isUppercase)
    }
  }

  var descriptor: LocalGatewayGraphQLDescriptor {
    let mode = mode
    let tier = tier
    return LocalGatewayGraphQLDescriptor(
      providerName: "gmail-gateway",
      payloadNamespaceKey: "gmailGateway",
      tier: tier,
      // gmail-gateway rejects GraphQL variables; values render into the
      // document text instead.
      acceptsVariables: false,
      isAllowedEnvironmentTarget: { Self.isAllowedTargetEnvironmentName($0) },
      run: { _, document, _, environment in
        let result = GmailGatewayCLI(mode: mode).run(
          arguments: ["graphql", "--query", document],
          environment: environment
        )
        guard !result.stdout.isEmpty else {
          throw AdapterExecutionError(
            .providerError,
            "gmail-gateway \(tier) failed with exit code \(result.exitCode): \(appleGatewayCompactText(result.stderr))"
          )
        }
        return result.stdout
      }
    )
  }
}

extension BuiltinWorkflowAddonResolver {
  func executeGmailGatewayCLIAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinGmailGatewayCLIAddon,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    try await LocalGatewayGraphQLEngine(
      environment: environment,
      descriptor: operation.descriptor,
      runnerOverride: localGatewayGraphQLRunner
    ).execute(input, context: context)
  }
}
