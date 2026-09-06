#if os(macOS)
import RielaKaibaSupport

/// A redacted, typed reason that a workflow cannot start its Kaiba nodes.
public enum RielaAppKaibaRecoveryAction: Equatable, Sendable {
  case openKaibaSettings
  case configureWorkflowEnvironment
  case selectEnabledInstance
  case repairLegacyConnectionConfiguration
  case testSelectedInstance

  public var instruction: String {
    switch self {
    case .openKaibaSettings: "Open Kaiba settings and repair the instance catalog."
    case .configureWorkflowEnvironment: "Configure the required credential environment variable for this workflow."
    case .selectEnabledInstance: "Select an enabled Kaiba instance for every Kaiba node."
    case .repairLegacyConnectionConfiguration:
      KaibaLegacyInputCompatibility.connectionMismatchRecoveryInstruction
    case .testSelectedInstance: "Test the selected Kaiba instance from Kaiba settings."
    }
  }
}
#endif
