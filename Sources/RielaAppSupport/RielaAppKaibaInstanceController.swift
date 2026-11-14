#if os(macOS)
import Foundation
import RielaKaibaSupport

/// Main-actor-friendly façade for the shared user-wide Kaiba catalog.  It
/// deliberately returns only persisted safe fields: a bearer value is resolved
/// by `KaibaClientFactory` at execution time and never crosses this boundary.
public struct RielaAppKaibaInstanceController: Sendable {
  public let store: KaibaInstanceStore
  public let bindingScanRoots: KaibaBindingScanRoots?

  public init(
    homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    bindingScanRoots: KaibaBindingScanRoots? = nil
  ) {
    store = KaibaInstanceStore(homeURL: homeURL)
    self.bindingScanRoots = bindingScanRoots
  }

  public init(store: KaibaInstanceStore, bindingScanRoots: KaibaBindingScanRoots? = nil) {
    self.store = store
    self.bindingScanRoots = bindingScanRoots
  }

  public func list() throws -> [KaibaInstance] {
    try store.load().instances.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  @discardableResult
  public func add(_ instance: KaibaInstance) throws -> KaibaInstance {
    let catalog = try store.mutate { current in
      var next = current
      var candidate = instance
      candidate.name = try KaibaInstanceValidation.normalizedName(candidate.name)
      if next.instances.isEmpty { candidate.isDefault = true }
      guard !next.instances.contains(where: {
        KaibaInstanceValidation.nameKey($0.name) == KaibaInstanceValidation.nameKey(candidate.name)
      }) else { throw KaibaInstanceStoreError.duplicateName }
      if candidate.isDefault {
        for index in next.instances.indices { next.instances[index].isDefault = false }
      }
      next.instances.append(candidate)
      return next
    }
    guard let created = catalog.instances.first(where: { $0.id == instance.id }) else {
      throw KaibaInstanceStoreError.missingInstance
    }
    return created
  }

  @discardableResult
  public func update(_ instance: KaibaInstance, expected: KaibaInstance) throws -> KaibaInstance {
    let catalog = try store.mutateInstance(id: instance.id, expected: expected) { current in
      var replacement = instance
      replacement = try KaibaInstanceLifecycle.applyingUpdate(from: current, to: replacement, at: Date())
      return replacement
    }
    guard let updated = catalog.instances.first(where: { $0.id == instance.id }) else {
      throw KaibaInstanceStoreError.missingInstance
    }
    return updated
  }

  @discardableResult
  public func setDefault(id: String) throws -> [KaibaInstance] {
    try store.mutate { current in
      var next = current
      guard let selected = next.instances.firstIndex(where: { $0.id == id }) else {
        throw KaibaInstanceStoreError.missingInstance
      }
      guard next.instances[selected].enabled else { throw KaibaInstanceStoreError.invalidInstance }
      for index in next.instances.indices { next.instances[index].isDefault = index == selected }
      return next
    }.instances
  }

  @discardableResult
  public func remove(id: String, force: Bool = false) throws -> RielaAppKaibaRemovalResult {
    guard let bindingScanRoots else { throw KaibaBindingScannerError.failed }
    let selected = try store.load().instances.first(where: { $0.id == id })
    guard let selected else { throw KaibaInstanceStoreError.missingInstance }
    var references: [KaibaBindingReference] = []
    let catalog = try store.mutate { current in
      var next = current
      guard let index = next.instances.firstIndex(where: { $0.id == id }) else {
        throw KaibaInstanceStoreError.missingInstance
      }
      guard next.instances[index] == selected else { throw KaibaInstanceStoreError.changedInstance }
      guard !(next.instances[index].isDefault && next.instances.count > 1) else {
        throw KaibaInstanceStoreError.defaultInvariant
      }
      references = try KaibaBindingScanner().references(to: id, roots: bindingScanRoots)
      guard force || references.isEmpty else { throw RielaAppKaibaInstanceControllerError.instanceInUse }
      next.instances.remove(at: index)
      return next
    }
    return .init(instances: catalog.instances, references: references)
  }

  /// Returns the affected workflow references before a destructive removal.
  /// A missing scan root is deliberately an error: the UI must fail closed
  /// rather than offer a removal action whose impact it cannot show.
  public func removalReferences(id: String) throws -> [KaibaBindingReference] {
    guard let bindingScanRoots else { throw KaibaBindingScannerError.failed }
    guard try store.load().instances.contains(where: { $0.id == id }) else {
      throw KaibaInstanceStoreError.missingInstance
    }
    return try KaibaBindingScanner().references(to: id, roots: bindingScanRoots)
  }

  /// Stores a generic readiness result only if the row has not been edited
  /// while the request was in flight.  Error text and server data are never
  /// copied into state.
  @discardableResult
  public func test(id: String, environment: [String: String]) async throws -> KaibaInstanceLastTest {
    let snapshot = try store.load()
    guard let instance = snapshot.instances.first(where: { $0.id == id }) else {
      throw KaibaInstanceStoreError.missingInstance
    }
    let result: KaibaInstanceLastTest
    if !instance.enabled {
      result = KaibaInstanceLifecycle.disabledResult(at: Date())
    } else {
      let client = try KaibaClientFactory().makeClient(instance: instance, environment: environment)
      result = try await KaibaReadinessService().test(client)
    }
    _ = try store.mutateInstance(id: id, expected: instance) { current in
      var updated = current
      updated.lastTest = result
      return updated
    }
    return result
  }
}

public struct RielaAppKaibaRemovalResult: Equatable, Sendable {
  public let instances: [KaibaInstance]
  public let references: [KaibaBindingReference]
}

public enum RielaAppKaibaInstanceControllerError: Error, Equatable, Sendable {
  case instanceInUse
}
#endif
