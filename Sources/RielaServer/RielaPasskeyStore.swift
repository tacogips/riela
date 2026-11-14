import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Public keys and hashed one-use invitations; no private keys or session tokens.
public struct RielaPasskeyStore: Sendable {
  public let root: URL
  public let origin: String

  public init(root: URL, origin: String) {
    self.root = root
    self.origin = origin
  }

  public struct User: Codable, Sendable {
    public let id: String
    public let name: String
    public var enabled: Bool
    public var credentials: [Credential]
  }

  public struct Credential: Codable, Sendable {
    public let id: String
    var publicKey: Data
    var signCount: UInt32
    var backupEligible: Bool
    public var revoked: Bool
  }

  struct Invitation: Codable {
    let userID: String
    let expiresAt: Date
  }

  struct State: Codable {
    var version = 1
    let origin: String
    var users: [User] = []
    var invitations: [String: Invitation] = [:]
  }

  public func invite(name: String, now: Date = Date()) throws -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf8.count <= 100, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw RielaPasskeyError.invalidRequest
    }
    let token = PasskeyEncoding.randomToken()
    try transaction { state in
      state.invitations = state.invitations.filter { $0.value.expiresAt > now }
      guard state.invitations.count < 256 else { throw RielaPasskeyError.capacity }
      let user: User
      if let existing = state.users.first(where: { $0.name == name }) {
        guard existing.enabled else { throw RielaPasskeyError.unauthorized }
        user = existing
      } else {
        user = User(id: PasskeyEncoding.randomToken(), name: name, enabled: true, credentials: [])
        state.users.append(user)
      }
      state.invitations[PasskeyEncoding.digest(token)] = Invitation(userID: user.id, expiresAt: now.addingTimeInterval(900))
    }
    return "\(origin)/#/auth/register/\(token)"
  }

  public func users() throws -> [User] { try transaction(write: false) { $0.users } }

  public func revokeUser(name: String) throws {
    try transaction { state in
      guard let index = state.users.firstIndex(where: { $0.name == name }) else { throw RielaPasskeyError.userNotFound }
      state.users[index].enabled = false
      let id = state.users[index].id
      state.invitations = state.invitations.filter { $0.value.userID != id }
    }
  }

  public func revokeCredential(id: String) throws {
    try transaction { state in
      for userIndex in state.users.indices {
        if let keyIndex = state.users[userIndex].credentials.firstIndex(where: { $0.id == id }) {
          state.users[userIndex].credentials[keyIndex].revoked = true
          return
        }
      }
      throw RielaPasskeyError.userNotFound
    }
  }

  func invitation(_ token: String, now: Date) throws -> User {
    try transaction(write: false) { state in
      guard let invite = state.invitations[PasskeyEncoding.digest(token)], invite.expiresAt > now,
            let user = state.users.first(where: { $0.id == invite.userID && $0.enabled }) else {
        throw RielaPasskeyError.expired
      }
      return user
    }
  }

  func credential(id: String) throws -> (User, Credential) {
    for user in try users() where user.enabled {
      if let key = user.credentials.first(where: { $0.id == id && !$0.revoked }) { return (user, key) }
    }
    throw RielaPasskeyError.unauthorized
  }

  func transaction<Value>(write: Bool = true, _ operation: (inout State) throws -> Value) throws -> Value {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let lockPath = root.appendingPathComponent("store.lock").path
    let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw RielaPasskeyError.storeUnavailable }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw RielaPasskeyError.storeUnavailable }
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    let file = root.appendingPathComponent("credentials.json")
    var state = State(origin: origin)
    if FileManager.default.fileExists(atPath: file.path) {
      state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
      guard state.version == 1, state.origin == origin else { throw RielaPasskeyError.configuration }
    }
    let result = try operation(&state)
    if write {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(state).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    return result
  }
}
