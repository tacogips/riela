#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

struct WorkflowActivationRecord: Codable, Equatable, Sendable {
  var origin: WorkflowOriginIdentity
  var updatedAt: Date
}

private struct WorkflowActivationDocument: Codable, Equatable, Sendable {
  var schemaVersion: Int
  var deactivated: [String: WorkflowActivationRecord]

  static let empty = WorkflowActivationDocument(schemaVersion: 1, deactivated: [:])
}

struct WorkflowActivationStoreHooks: Sendable {
  var afterStateRootPin: @Sendable () throws -> Void

  init(afterStateRootPin: @escaping @Sendable () throws -> Void = {}) {
    self.afterStateRootPin = afterStateRootPin
  }
}

struct WorkflowActivationStore: Sendable {
  private static let coordinatorLockKey = "riela.workflow-registry.activation-lock"
  private static let coordinatorRootKey = "riela.workflow-registry.activation-root"
  let hooks: WorkflowActivationStoreHooks

  init(hooks: WorkflowActivationStoreHooks = WorkflowActivationStoreHooks()) {
    self.hooks = hooks
  }

  static var coordinatorLockHeld: Bool {
    Thread.current.threadDictionary[coordinatorLockKey] as? Bool == true
  }

  static var coordinatorPinnedRoot: WorkflowMutableRegistryPinnedRoot? {
    Thread.current.threadDictionary[coordinatorRootKey] as? WorkflowMutableRegistryPinnedRoot
  }

  func state(for origin: WorkflowOriginIdentity) throws -> WorkflowActivationState {
    try withLock(create: false) { document in
      document.deactivated[origin.originId] == nil ? .active : .deactivated
    } ?? .active
  }

  func snapshot() throws -> [String: WorkflowActivationRecord] {
    try withLock(create: false, body: { $0.deactivated }) ?? [:]
  }

  func set(_ state: WorkflowActivationState, for origin: WorkflowOriginIdentity) throws {
    _ = try withLock(create: true) { document in
      var updated = document
      switch state {
      case .active:
        updated.deactivated.removeValue(forKey: origin.originId)
      case .deactivated:
        updated.deactivated[origin.originId] = WorkflowActivationRecord(origin: origin, updatedAt: Date())
      }
      try write(updated, pinned: try requirePinnedRoot())
      return ()
    }
  }

  func remove(origin: WorkflowOriginIdentity) throws {
    _ = try withLock(create: false) { document in
      guard document.deactivated[origin.originId] != nil else { return }
      var updated = document
      updated.deactivated.removeValue(forKey: origin.originId)
      try write(updated, pinned: try requirePinnedRoot())
    }
  }

  func withCoordinatorLock<T>(_ body: () throws -> T) throws -> T {
    if Self.coordinatorLockHeld {
      return try body()
    }
    let pinned = try statePinnedRoot(create: true)
    return try withFileLock(pinned: pinned) {
      try withThreadPinnedRoot(pinned) {
        let result = try body()
        try pinned.requireConfiguredPathIdentity()
        return result
      }
    }
  }

  func withCoordinatorReadLock<T>(_ body: () throws -> T) throws -> T {
    if Self.coordinatorLockHeld {
      return try body()
    }
    let pinned: WorkflowMutableRegistryPinnedRoot
    do {
      pinned = try statePinnedRoot(create: true)
    } catch {
      let home = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true)
      guard stateRootParentIsExplicitlyReadOnly(home: home) else { throw error }
      return try body()
    }
    return try withFileLock(pinned: pinned) {
      try withThreadPinnedRoot(pinned) {
        let result = try body()
        try pinned.requireConfiguredPathIdentity()
        return result
      }
    }
  }

  private func withLock<T>(
    create: Bool,
    body: (WorkflowActivationDocument) throws -> T
  ) throws -> T? {
    if let pinned = Self.coordinatorPinnedRoot {
      return try body(read(pinned: pinned))
    }
    let pinned: WorkflowMutableRegistryPinnedRoot
    do {
      pinned = try statePinnedRoot(create: create)
    } catch is WorkflowMutableRegistryRootAbsent {
      return nil
    }
    return try withFileLock(pinned: pinned) {
      try withThreadPinnedRoot(pinned) {
        let result = try body(read(pinned: pinned))
        try pinned.requireConfiguredPathIdentity()
        return result
      }
    }
  }

  private func withFileLock<T>(
    pinned: WorkflowMutableRegistryPinnedRoot,
    body: () throws -> T
  ) throws -> T {
    let descriptor = try pinned.openRegularFile(
      pinned.url.appendingPathComponent("activation.lock"),
      flags: O_RDWR | O_CREAT
    )
    defer { _ = close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else {
      throw WorkflowRegistryError(code: .registryIOFailure, message: "unable to acquire workflow activation lock")
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    try hooks.afterStateRootPin()
    try pinned.requireConfiguredPathIdentity()
    return try body()
  }

  private func withThreadPinnedRoot<T>(
    _ pinned: WorkflowMutableRegistryPinnedRoot,
    body: () throws -> T
  ) throws -> T {
    Thread.current.threadDictionary[Self.coordinatorLockKey] = true
    Thread.current.threadDictionary[Self.coordinatorRootKey] = pinned
    defer {
      Thread.current.threadDictionary.removeObject(forKey: Self.coordinatorRootKey)
      Thread.current.threadDictionary.removeObject(forKey: Self.coordinatorLockKey)
    }
    return try body()
  }

  private func statePinnedRoot(create: Bool) throws -> WorkflowMutableRegistryPinnedRoot {
    try WorkflowMutableRegistryPinnedRoot(
      homeDirectory: URL(
        fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(),
        isDirectory: true
      ),
      rootComponents: [".riela", "workflow-state"],
      create: create
    )
  }

  private func stateRootParentIsExplicitlyReadOnly(home: URL) -> Bool {
    let stateParent = home.appendingPathComponent(".riela", isDirectory: true)
    var status = stat()
    if lstat(stateParent.path, &status) != 0,
       lstat(home.path, &status) != 0 { return false }
    return status.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0
  }

  private func requirePinnedRoot() throws -> WorkflowMutableRegistryPinnedRoot {
    guard let pinned = Self.coordinatorPinnedRoot else {
      throw WorkflowRegistryError(
        code: .registryIOFailure,
        message: "workflow activation mutation requires a pinned state root"
      )
    }
    return pinned
  }

  private func read(pinned: WorkflowMutableRegistryPinnedRoot) throws -> WorkflowActivationDocument {
    let stateURL = pinned.url.appendingPathComponent("activation.json")
    guard let data = try pinned.readRegularIfPresent(stateURL) else { return .empty }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(WorkflowActivationDocument.self, from: data)
    guard document.schemaVersion == 1,
          document.deactivated.allSatisfy({ $0.key == $0.value.origin.originId }) else {
      throw WorkflowRegistryError(
        code: .registryIOFailure,
        message: "workflow activation state is malformed or unsupported"
      )
    }
    return document
  }

  private func write(
    _ document: WorkflowActivationDocument,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(document)
    let staging = pinned.url.appendingPathComponent(".activation-\(UUID().uuidString.lowercased()).json")
    let stateURL = pinned.url.appendingPathComponent("activation.json")
    try pinned.writeNewRegularFile(data, to: staging)
    do {
      try pinned.rename(staging, to: stateURL)
      try pinned.syncDirectory(pinned.url)
    } catch {
      try? pinned.unlink(staging)
      throw error
    }
  }
}

func workflowOriginIdentity(
  name: String,
  workflowId: String,
  scope: WorkflowScope,
  sourceKind: WorkflowSourceKind,
  provenance: WorkflowProvenance,
  locator: String
) -> WorkflowOriginIdentity {
  WorkflowOriginIdentity(
    scope: WorkflowRegistryScope(rawValue: scope.rawValue) ?? .auto,
    sourceKind: sourceKind == .package ? .package : .workflow,
    provenance: provenance,
    name: name,
    workflowId: workflowId,
    canonicalLocator: URL(fileURLWithPath: locator).resolvingSymlinksInPath().standardizedFileURL.path
  )
}
