import Foundation

/// Resolves only authored stable IDs. An invalid explicit binding never falls
/// back to the default instance, which prevents a stale workflow from silently
/// targeting a different Kaiba server.
public enum KaibaInstanceResolver {
  public static func resolve(
    bindingID: String?,
    catalog: KaibaInstanceCatalog
  ) throws -> KaibaInstance {
    let validated = try KaibaInstanceValidation.validated(catalog)
    let selected: KaibaInstance?
    if let bindingID {
      selected = validated.instances.first(where: { $0.id == bindingID })
      guard selected != nil else { throw KaibaInstanceStoreError.missingInstance }
    } else {
      selected = validated.instances.first(where: \.isDefault)
      guard selected != nil else { throw KaibaInstanceStoreError.defaultInvariant }
    }
    guard let instance = selected, instance.enabled else {
      throw KaibaInstanceStoreError.invalidInstance
    }
    return instance
  }
}
