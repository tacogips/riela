import Foundation
import RielaAddonSupport
import RielaCore

/// Built-in add-ons that run the locally installed gmail-gateway CLI tier
/// binaries. The tier is compiled into each executable (reader is read-only,
/// draft turns sendMessage/replyMessage/forwardMessage into provider drafts,
/// sender performs direct sends), so each add-on pins one binary and the
/// workflow cannot escalate through inputs or payload data.
///
/// These are distinct from `riela/gmail-gateway-read` / `riela/gmail-gateway`,
/// which are container-backed add-ons resolved outside this process.
enum BuiltinGmailGatewayCLIAddon: String {
  case reader = "riela/gmail-gateway-reader"
  case draft = "riela/gmail-gateway-draft"
  case sender = "riela/gmail-gateway-sender"

  var executableName: String {
    switch self {
    case .reader:
      "gmail-gateway-reader"
    case .draft:
      "gmail-gateway-draft"
    case .sender:
      "gmail-gateway-sender"
    }
  }

  var executableEnvironmentName: String {
    switch self {
    case .reader:
      "GMAIL_GATEWAY_READER_BIN"
    case .draft:
      "GMAIL_GATEWAY_DRAFT_BIN"
    case .sender:
      "GMAIL_GATEWAY_SENDER_BIN"
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

  var descriptor: LocalGatewayGraphQLCLIDescriptor {
    LocalGatewayGraphQLCLIDescriptor(
      providerName: "gmail-gateway",
      payloadNamespaceKey: "gmailGateway",
      executableName: executableName,
      executableEnvironmentName: executableEnvironmentName,
      invocationStyle: .queryFlagInlineOnly,
      isAllowedEnvironmentTarget: { Self.isAllowedTargetEnvironmentName($0) }
    )
  }
}

extension BuiltinWorkflowAddonResolver {
  func executeGmailGatewayCLIAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinGmailGatewayCLIAddon,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    try LocalGatewayGraphQLCLIEngine(environment: environment, descriptor: operation.descriptor)
      .execute(input, context: context)
  }
}
