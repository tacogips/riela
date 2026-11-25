import Foundation
import RielaCore
import RielaServer
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct RemoteRecord: Codable, Equatable, Sendable {
  let name: String
  let address: String
  let serverId: String
  let serverName: String
  let grantId: String
  let scope: RielaAPIKeyStore.Scope
  let addedAt: Date
  var lastSeenAt: Date?
  var lastKnown: RemoteLastKnown?
}

struct RemoteRegistryState: Codable, Sendable {
  var version = 1
  var active = "local"
  var remotes: [RemoteRecord] = []
}

struct RemoteRegistry: Sendable {
  let root: URL

  init(environment: [String: String]) {
    if let directory = environment["RIELA_CREDENTIAL_DIR"], !directory.isEmpty {
      root = URL(fileURLWithPath: directory, isDirectory: true)
    } else {
      let home = CLIRuntimeEnvironment.homeDirectory(environment: environment)
      let stateHome = environment["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home + "/.local/state"
      root = URL(fileURLWithPath: stateHome, isDirectory: true)
        .appendingPathComponent("riela/credentials", isDirectory: true)
    }
  }

  func list() throws -> RemoteRegistryState {
    try transaction { $0 }
  }

  func record(name: String) throws -> RemoteRecord {
    try transaction { try Self.record(in: $0, name: name) }
  }

  func token(name: String) throws -> String {
    try credentials(name: name).token
  }

  func credentials(name: String) throws -> (record: RemoteRecord, token: String) {
    try transaction { state in
      let record = try Self.record(in: state, name: name)
      try privateDirectory(tokens, create: false)
      guard let data = try RielaAPIKeyStore.readRegularFile(tokenFile(name)),
            let token = String(data: data, encoding: .utf8), Self.validToken(token) else {
        throw Self.unavailable
      }
      return (record, token)
    }
  }

  func requireAvailable(name: String) throws {
    try Self.validate(name: name)
    try transaction { state in
      guard !state.remotes.contains(where: { $0.name == name }) else {
        throw BotStoreError(code: "remote_exists", message: "A remote with that name already exists")
      }
    }
  }

  func add(record: RemoteRecord, token: String) throws {
    try Self.validate(name: record.name)
    guard Self.validToken(token) else { throw Self.unavailable }
    _ = try RielaPairingAddress.validate(record.address)
    try transaction(create: true) { state in
      guard !state.remotes.contains(where: { $0.name == record.name }) else {
        throw BotStoreError(code: "remote_exists", message: "A remote with that name already exists")
      }
      try privateDirectory(tokens, create: true)
      let file = tokenFile(record.name)
      try RielaAPIKeyStore.persist(Data(token.utf8), to: file)
      state.remotes.append(record)
      state.remotes.sort { $0.name < $1.name }
      do {
        try persist(state)
      } catch {
        if (try? readState().remotes.contains { $0.name == record.name }) == false {
          try? FileManager.default.removeItem(at: file)
        }
        throw error
      }
    }
  }

  func remove(name: String) throws {
    try transaction { state in
      _ = try Self.record(in: state, name: name)
      try privateDirectory(tokens, create: false)
      state.remotes.removeAll { $0.name == name }
      if state.active == name { state.active = "local" }
      try persist(state)
      let file = tokenFile(name)
      guard unlink(file.path) == 0 || errno == ENOENT else { throw Self.unavailable }
    }
  }

  func use(name: String) throws {
    try transaction { state in
      if name != "local" { _ = try Self.record(in: state, name: name) }
      guard state.active != name else { return }
      state.active = name
      try persist(state)
    }
  }

  func touchLastSeen(name: String, at time: Date, grantId: String? = nil) throws {
    try update(name: name, grantId: grantId) { record in
      if record.lastSeenAt.map({ $0 >= time }) != true { record.lastSeenAt = time }
    }
  }

  func updateLastKnown(name: String, lastKnown: RemoteLastKnown, grantId: String? = nil) throws {
    try update(name: name, grantId: grantId) { record in
      if record.lastKnown.map({ $0.observedAt >= lastKnown.observedAt }) != true { record.lastKnown = lastKnown }
    }
  }

  private func update(name: String, grantId: String?, _ body: (inout RemoteRecord) -> Void) throws {
    try transaction { state in
      guard let index = state.remotes.firstIndex(where: { $0.name == name }),
            grantId == nil || state.remotes[index].grantId == grantId else { return }
      body(&state.remotes[index])
      try persist(state)
    }
  }

  private var tokens: URL { root.appendingPathComponent("remotes", isDirectory: true) }
  private var metadata: URL { root.appendingPathComponent("remotes.json") }
  private func tokenFile(_ name: String) -> URL { tokens.appendingPathComponent(name + ".token") }

  private func persist(_ state: RemoteRegistryState) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try RielaAPIKeyStore.persist(encoder.encode(state), to: metadata)
  }

  private func readState() throws -> RemoteRegistryState {
    guard let data = try RielaAPIKeyStore.readRegularFile(metadata) else { return RemoteRegistryState() }
    let state = try JSONDecoder().decode(RemoteRegistryState.self, from: data)
    let names = Set(state.remotes.map(\.name))
    guard state.version == 1, names.count == state.remotes.count,
          state.active == "local" || names.contains(state.active) else { throw Self.unavailable }
    for record in state.remotes {
      try Self.validate(name: record.name)
      _ = try RielaPairingAddress.validate(record.address)
    }
    return state
  }

  private func transaction<Value>(
    create: Bool = false, _ body: (inout RemoteRegistryState) throws -> Value
  ) throws -> Value {
    do {
      var state = RemoteRegistryState()
      if try !privateDirectory(root, create: create) { return try body(&state) }
      let lock = root.appendingPathComponent("remotes.lock")
      let descriptor = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
      guard descriptor >= 0 else { throw Self.unavailable }
      defer { close(descriptor) }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), fchmod(descriptor, 0o600) == 0 else { throw Self.unavailable }
      while flock(descriptor, LOCK_EX) != 0 {
        guard errno == EINTR else { throw Self.unavailable }
      }
      state = try readState()
      return try body(&state)
    } catch let error as BotStoreError {
      throw error
    } catch {
      throw Self.unavailable
    }
  }

  @discardableResult
  private func privateDirectory(_ directory: URL, create: Bool) throws -> Bool {
    if create {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    }
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 {
      guard errno == ENOENT, !create else { throw Self.unavailable }
      return false
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
          info.st_mode & 0o777 == 0o700 || fchmod(descriptor, 0o700) == 0 else { throw Self.unavailable }
    return true
  }

  private static func record(in state: RemoteRegistryState, name: String) throws -> RemoteRecord {
    guard let record = state.remotes.first(where: { $0.name == name }) else {
      throw BotStoreError(code: "remote_not_found", message: "The selected remote does not exist")
    }
    return record
  }

  private static func validate(name: String) throws {
    let allowed = name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    guard (1...63).contains(name.utf8.count), name.utf8.first != 45, allowed,
          name != "local", name != "unverified" else {
      throw BotStoreError(code: "remote_name_invalid", message: "Choose a lowercase remote name using letters, digits or hyphens")
    }
  }

  static func validToken(_ token: String) -> Bool {
    !token.isEmpty && token.utf8.count <= 249 && token.utf8.allSatisfy { (33...126).contains($0) }
  }

  private static var unavailable: BotStoreError {
    BotStoreError(code: "remote_registry_unavailable", message: "The remote credential registry is unavailable")
  }
}
