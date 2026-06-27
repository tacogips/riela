#if os(macOS)
public enum RielaAppImportPreferencePolicy {
  public static func preference(
    identity: String,
    existingPreference: RielaAppDaemonWorkflowPreference?,
    replacedExisting: Bool,
    startsImmediately: Bool
  ) -> RielaAppDaemonWorkflowPreference {
    if replacedExisting, let existingPreference {
      return existingPreference
    }
    return .imported(identity: identity, startsImmediately: startsImmediately)
  }

  public static func shouldStartAfterImport(
    preference: RielaAppDaemonWorkflowPreference,
    startsImportedCandidates: Bool
  ) -> Bool {
    startsImportedCandidates && preference.available && preference.active
  }
}
#endif
