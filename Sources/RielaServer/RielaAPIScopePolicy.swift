import RielaGraphQL

public enum RielaAPIScopePolicy {
  public static let adminMutationFields: Set<String> = Set([
    "mintPairingCode", "revokePairingGrant", "addRemote", "removeRemote", "useRemote",
    "saveProviderInstance", "removeProviderInstance", "removeBot"
  ]).union(RielaConfigGraphQLDocumentExecutor.mutationFields)

  public static func violation(scope: RielaAPIKeyStore.Scope, roots: [(root: String, field: String)]) -> String? {
    guard scope != .admin else { return nil }
    return roots.first { root in
      root.root == "Mutation" && (scope == .read || adminMutationFields.contains(root.field))
    }.map { "\($0.root).\($0.field)" }
  }
}
