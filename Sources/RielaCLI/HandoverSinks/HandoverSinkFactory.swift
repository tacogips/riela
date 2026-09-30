import Foundation
import RielaCore
import RielaWork

enum HandoverSinkError: Error, Equatable, Sendable, CustomStringConvertible {
  case digestMismatch(expected: String, actual: String)
  case invalidConfiguration(String)
  case invalidLocator(String)
  case notFound(String)
  case conflictingContent(String)
  case commandFailed(Int32)
  case commandTimedOut
  case invalidCommandOutput
  case invalidPacketEncoding
  case packetBlockMissing
  case kaibaResponseInvalid(String)
  case gitCommandFailed(String)

  var description: String {
    switch self {
    case let .digestMismatch(expected, actual): "handover packet digest mismatch (expected \(expected), got \(actual))"
    case let .invalidConfiguration(message): "invalid handover sink configuration: \(message)"
    case let .invalidLocator(locator): "invalid handover sink locator: \(locator)"
    case let .notFound(locator): "handover sink content was not found: \(locator)"
    case let .conflictingContent(locator): "handover sink refuses to overwrite different content: \(locator)"
    case let .commandFailed(status): "handover sink command exited with status \(status)"
    case .commandTimedOut: "handover sink command timed out"
    case .invalidCommandOutput: "handover sink command returned an invalid id"
    case .invalidPacketEncoding: "handover packet is not valid UTF-8"
    case .packetBlockMissing: "Kaiba note does not contain a handover packet block"
    case let .kaibaResponseInvalid(detail): "invalid Kaiba handover response: \(detail)"
    case let .gitCommandFailed(detail): "git handover sink command failed: \(detail)"
    }
  }
}

enum HandoverSinkVerification {
  static func verify(bytes: Data, ref: HandoverSinkRef) throws -> HandoverPacket {
    let packet = try JSONCanonical.decoder().decode(HandoverPacket.self, from: bytes)
    let computed = try packet.canonicalDigest()
    guard packet.digest == computed else {
      throw HandoverSinkError.digestMismatch(expected: packet.digest, actual: computed)
    }
    guard ref.digest == computed else {
      throw HandoverSinkError.digestMismatch(expected: ref.digest, actual: computed)
    }
    return packet
  }
}

struct HandoverSinkContext: Sendable {
  let hostId: String
  let storeRoot: String
  let repositoryRoot: String?
  let store: WorkStore
  let environment: [String: String]
  // Command ids are opaque, so a command-backed packet reader needs the same argv as its writer.
  let commandArgv: [String]?
  let commandTimeoutSeconds: TimeInterval

  init(hostId: String, storeRoot: String, repositoryRoot: String? = nil, store: WorkStore,
       environment: [String: String] = [:], commandArgv: [String]? = nil, commandTimeoutSeconds: TimeInterval = 30) {
    self.hostId = hostId
    self.storeRoot = storeRoot
    self.repositoryRoot = repositoryRoot
    self.store = store
    self.environment = environment
    self.commandArgv = commandArgv
    self.commandTimeoutSeconds = commandTimeoutSeconds
  }
}

enum HandoverSinkFactory {
  static func mergedConfigs(task: WorkTask, workflow: WorkflowDefinition, cliKinds: [HandoverSinkKind]) -> [HandoverSinkConfig] {
    var result: [HandoverSinkConfig] = []
    var identities = Set<String>()
    let authored = (task.guardPolicy.handover?.sinks ?? []) + (workflow.handover?.sinks ?? [])
    for config in authored where config.kind != .store {
      let key = identity(for: config)
      if identities.insert(key).inserted { result.append(config) }
    }
    for kind in cliKinds where kind != .store {
      guard !result.contains(where: { $0.kind == kind }) else { continue }
      let config = HandoverSinkConfig(kind: kind)
      let key = identity(for: config)
      if identities.insert(key).inserted { result.append(config) }
    }
    return result
  }

  static func make(_ configs: [HandoverSinkConfig], context: HandoverSinkContext) throws -> [any HandoverSink] {
    try configs.compactMap { config in
      switch config.kind {
      case .store:
        return nil
      case .kaiba:
        guard let instanceId = nonEmpty(config.kaibaInstanceId) else {
          throw HandoverSinkError.invalidConfiguration("kaiba sink requires kaibaInstanceId")
        }
        return KaibaHandoverSink(client: KaibaAddonCatalogNoteClient(environment: context.environment), instanceId: instanceId,
                                 notebookId: config.notebookId)
      case .gitRef:
        guard let remote = nonEmpty(config.remote), let root = context.repositoryRoot else {
          throw HandoverSinkError.invalidConfiguration("gitRef sink requires remote and repositoryRoot")
        }
        return GitRefHandoverSink(repositoryRoot: root, remote: remote)
      case .file:
        if let configuredPath = config.path {
          guard URL(fileURLWithPath: configuredPath).path == configuredPath,
                configuredPath.hasPrefix("/") else {
            throw HandoverSinkError.invalidConfiguration("file sink path must be absolute")
          }
          return FileHandoverSink(root: configuredPath)
        }
        return FileHandoverSink(root: context.storeRoot)
      case .command:
        guard let argv = config.command, !argv.isEmpty else {
          throw HandoverSinkError.invalidConfiguration("command sink requires argv")
        }
        return CommandHandoverSink(argv: argv, timeoutSeconds: context.commandTimeoutSeconds, workingDirectory: context.storeRoot)
      }
    }
  }

  static func reader(for ref: HandoverSinkRef, context: HandoverSinkContext) throws -> any HandoverSink {
    switch ref.kind {
    case .store:
      return StoreHandoverSink(store: context.store, hostId: context.hostId)
    case .file:
      guard ref.locator.hasPrefix("/") else { throw HandoverSinkError.invalidLocator(ref.locator) }
      let url = URL(fileURLWithPath: ref.locator)
      guard url.lastPathComponent.hasSuffix(".json"), url.deletingLastPathComponent().lastPathComponent != "" else {
        throw HandoverSinkError.invalidLocator(ref.locator)
      }
      return FileHandoverSink(root: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path)
    case .gitRef:
      let fields = ref.locator.split(separator: " ", omittingEmptySubsequences: false)
      guard fields.count == 2, let root = context.repositoryRoot else {
        throw HandoverSinkError.invalidLocator(ref.locator)
      }
      return GitRefHandoverSink(repositoryRoot: root, remote: String(fields[0]))
    case .kaiba:
      let fields = ref.locator.split(separator: "/", omittingEmptySubsequences: false)
      guard fields.count == 2 else { throw HandoverSinkError.invalidLocator(ref.locator) }
      let instanceId = String(fields[0])
      return KaibaHandoverSink(client: KaibaAddonCatalogNoteClient(environment: context.environment), instanceId: instanceId)
    case .command:
      guard let argv = context.commandArgv, !argv.isEmpty else {
        throw HandoverSinkError.invalidConfiguration("command packet reader requires commandArgv")
      }
      return CommandHandoverSink(argv: argv, timeoutSeconds: context.commandTimeoutSeconds, workingDirectory: context.storeRoot)
    }
  }

  private static func identity(for config: HandoverSinkConfig) -> String {
    let target: String
    switch config.kind {
    case .store: target = ""
    case .kaiba: target = "\(config.kaibaInstanceId ?? "")/\(config.notebookId ?? "")"
    case .gitRef: target = config.remote ?? ""
    case .file: target = config.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? ""
    case .command: target = (config.command ?? []).joined(separator: "\u{0}")
    }
    return "\(config.kind.rawValue):\(target)"
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
