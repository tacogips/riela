import RielaCore
import RielaKaibaSupport

/// Projects validated, value-free compatibility diagnostics into add-on output.
enum KaibaLegacyCompatibility {
  static func diagnostics(
    input: WorkflowAddonExecutionInput,
    environment: [String: String],
    resolvedClient: KaibaExecutionSnapshot.ResolvedClient?
  ) throws -> [String] {
    guard let resolvedClient else { return [] }
    do {
      return try KaibaLegacyInputCompatibility.diagnostics(
        addon: input.addon,
        environment: environment,
        instance: resolvedClient.instance
      )
    } catch KaibaLegacyInputCompatibility.Error.connectionMismatch {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(KaibaLegacyInputCompatibility.connectionMismatch). "
          + KaibaLegacyInputCompatibility.connectionMismatchRecoveryInstruction
      )
    }
  }

  static func applying(
    _ diagnostics: [String],
    to output: AdapterExecutionOutput
  ) -> AdapterExecutionOutput {
    guard !diagnostics.isEmpty else { return output }
    var output = output
    output.payload["kaibaCompatibilityDiagnosticCodes"] = .array(diagnostics.map(JSONValue.string))
    return output
  }
}
