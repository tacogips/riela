import Foundation
import RielaAddonSupport
import RielaCore
import RielaMemory
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// A snapshot and its retention set are observed under the same writer lease.
/// This synchronizes protection only; it never updates a head or acknowledges work.
struct SnapshotCacheReconciliation {
  struct Binding {
    let lockName: String
    let exchange: RielaCacheExchange
    let scopeFrom: JSONValue
    let referencesFrom: JSONValue
    let initialValue: JSONValue
  }
  let directory: URL
  let bindings: [String: Binding]

  init(_ raw: JSONValue, memoryIds: Set<String>, resolver: BuiltinWorkflowAddonResolver, workflowId: String) throws {
    guard case let .object(config) = raw, Set(config.keys) == ["lockDirectory", "bindings"],
      case let .string(path)? = config["lockDirectory"], !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"),
      case let .object(rows)? = config["bindings"], Set(rows.keys) == memoryIds, rows.count <= 4096 else { throw snapshotCacheInvalid() }
    directory = URL(fileURLWithPath: path, relativeTo: resolver.workingDirectory).standardizedFileURL.resolvingSymlinksInPath()
    var result: [String: Binding] = [:], locks = Set<Data>(), scopes = Set<String>()
    var policies: [String: CachePolicy] = [:], protections: [String: Bool] = [:]
    for (memory, raw) in rows {
      guard case let .object(row) = raw, Set(row.keys) == ["lockName", "cache", "scopeFrom", "referencesFrom", "initialValue"],
        case let .string(lock)? = row["lockName"], lock.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,190}\.lock\z"#, options: .regularExpression) != nil,
        locks.insert(Data(lock.utf8)).inserted, let cache = row["cache"], let scope = row["scopeFrom"], let refs = row["referencesFrom"], let initial = row["initialValue"] else { throw snapshotCacheInvalid() }
      _ = try JSONDataTransform.lookup(.null, pointer: scope); _ = try JSONDataTransform.lookup(.null, pointer: refs)
      let exchange = try resolver.cacheReadExchange(cache, workflowId: workflowId)
      let physical = try cacheReadPolicyKey(exchange.store.databasePath(cacheId: exchange.cacheId))
      if let old = policies[physical], old.ttlSeconds != exchange.policy.ttlSeconds || old.maxBytes != exchange.policy.maxBytes { throw snapshotCacheInvalid() }
      policies[physical] = exchange.policy
      let scoped = physical + "\0" + exchange.scope
      guard scopes.insert(scoped).inserted else { throw snapshotCacheInvalid() }
      if let old = protections[physical], old != exchange.capacityProtection { throw snapshotCacheInvalid() }
      protections[physical] = exchange.capacityProtection
      let binding = Binding(lockName: lock, exchange: exchange, scopeFrom: scope, referencesFrom: refs, initialValue: initial)
      try Self.validateScope(initial, binding: binding)
      result[memory] = binding
    }
    bindings = result
  }

  func read<T>(memoryId: String, context: AdapterExecutionContext, operation: (Binding) throws -> T) throws -> T {
    guard let binding = bindings[memoryId] else { throw snapshotCacheInvalid() }
    try checkSnapshotWork(context)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard parent >= 0 else { throw snapshotCacheInvalid() }
    defer { close(parent) }
    let file = openat(parent, binding.lockName, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw snapshotCacheInvalid() }
    defer { close(file) }
    var status = stat()
    guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
      status.st_uid == getuid(), fchmod(file, 0o600) == 0 else { throw snapshotCacheInvalid() }
    let end = min(context.deadline ?? .distantFuture, Date().addingTimeInterval(5))
    while flock(file, LOCK_EX | LOCK_NB) != 0 {
      let failure = errno
      try checkSnapshotWork(context)
      guard [EINTR, EAGAIN, EWOULDBLOCK].contains(failure), Date() < end else { throw snapshotCacheInvalid() }
      Thread.sleep(forTimeInterval: 0.005)
    }
    defer { _ = flock(file, LOCK_UN) }
    try checkSnapshotWork(context)
    var named = stat()
    guard fstatat(parent, binding.lockName, &named, AT_SYMLINK_NOFOLLOW) == 0,
      named.st_dev == status.st_dev, named.st_ino == status.st_ino else { throw snapshotCacheInvalid() }
    return try operation(binding)
  }

  static func reconcile(_ raw: JSONValue, binding: Binding, context: AdapterExecutionContext) throws {
    try validateScope(raw, binding: binding)
    guard let refs = try JSONDataTransform.lookup(raw, pointer: binding.referencesFrom) else { throw snapshotCacheInvalid() }
    try checkSnapshotWork(context)
    _ = try binding.exchange.reconcile(memoryJSONValue(from: refs))
    try checkSnapshotWork(context)
  }

  private static func validateScope(_ raw: JSONValue, binding: Binding) throws {
    guard let references = try JSONDataTransform.lookup(raw, pointer: binding.referencesFrom) else { throw snapshotCacheInvalid() }
    let supplied = try JSONDataTransform.lookup(raw, pointer: binding.scopeFrom)
    // A legacy empty journal has no references or scope to retarget. The
    // explicitly authored cache binding still owns its empty retention set.
    if supplied == nil, references == .object([:]) { return }
    guard case let .string(scope)? = supplied,
      Data(scope.utf8) == Data(binding.exchange.scope.utf8) else { throw snapshotCacheInvalid() }
  }
}

private func snapshotCacheInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid locked snapshot cache reconciliation") }
