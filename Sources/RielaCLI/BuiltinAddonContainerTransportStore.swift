import Foundation
import RielaCore

/// Transport metadata only: runtime identities and environment values remain
/// owned by the runtime and credential provider respectively.
struct BuiltinAddonContainerInvocation: Codable, Equatable {
  var settings: WorkflowAddonContainerExecution
  var environmentBindings: JSONObject?
  var runtimeExecutable: String?
  var sandbox: WorkflowExecutionSandbox?
  var workerStateComponent: String?
}

struct BuiltinAddonContainerTransportStore {
  private struct Record: Codable {
    var version = 1
    var invocation: BuiltinAddonContainerInvocation
    var token: WorkflowAddonFinalizationToken?
    var workflowExecutionId: String?
    var acknowledged: Bool?
  }

  let workingDirectory: URL
  let rootDirectory: URL

  init(workingDirectory: URL, rootDirectory: URL? = nil) {
    self.workingDirectory = workingDirectory
    self.rootDirectory = rootDirectory ?? Self.defaultRoot(for: workingDirectory)
  }

  static func defaultRoot(for workspace: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    home.appendingPathComponent(".riela/addon-container-transports", isDirectory: true)
      .appendingPathComponent(sha256(Data(workspace.resolvingSymlinksInPath().standardizedFileURL.path.utf8)), isDirectory: true)
  }

  static func workerStateRoot(for controlDirectory: URL) -> URL {
    controlDirectory.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent("addon-container-state", isDirectory: true)
      .appendingPathComponent(controlDirectory.lastPathComponent, isDirectory: true)
  }

  static func validateIsolation(mountSources: [URL], controlDirectory: URL) throws {
    let authorities = [controlDirectory.deletingLastPathComponent(), workerStateRoot(for: controlDirectory).deletingLastPathComponent()]
      .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
    for source in mountSources {
      let path = source.resolvingSymlinksInPath().standardizedFileURL.path
      for authority in authorities {
        guard authority != path, !authority.hasPrefix(path.hasSuffix("/") ? path : path + "/"),
              !path.hasPrefix(authority + "/") else {
          throw AdapterExecutionError(.policyBlocked, "container workspace or mount exposes reserved runtime control or state storage; use a narrower workspace or mount")
        }
      }
    }
  }

  private var root: URL {
    rootDirectory
  }

  func record(_ invocation: BuiltinAddonContainerInvocation, token: WorkflowAddonFinalizationToken) throws {
    let url = tokenURL(token)
    if let existing = try read(url), existing.invocation != invocation {
      throw AdapterExecutionError(.invalidOutput, "container finalization token changed its execution transport")
    }
    if try isAcknowledged(token) { return }
    try write(Record(invocation: invocation, token: token), to: url)
  }

  func record(_ invocation: BuiltinAddonContainerInvocation, workflowExecutionId: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let key = sha256(try encoder.encode(invocation))
    try write(Record(invocation: invocation, workflowExecutionId: workflowExecutionId),
      to: workflowRoot(workflowExecutionId).appendingPathComponent(key + ".json"))
  }

  func invocation(for token: WorkflowAddonFinalizationToken) throws -> BuiltinAddonContainerInvocation? {
    guard let record = try read(tokenURL(token)) else { return nil }
    guard record.token == token else {
      throw AdapterExecutionError(.invalidOutput, "container finalization transport token mismatch")
    }
    return record.invocation
  }

  func invocations(workflowExecutionId: String) throws -> [BuiltinAddonContainerInvocation] {
    let directory = workflowRoot(workflowExecutionId)
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.map { url in
        guard let record = try read(url), record.workflowExecutionId == workflowExecutionId else {
          throw AdapterExecutionError(.invalidOutput, "container terminal transport identity mismatch")
        }
        return record.invocation
      }
  }

  func isAcknowledged(_ token: WorkflowAddonFinalizationToken) throws -> Bool {
    guard let record = try read(tokenURL(token)) else { return false }
    guard record.token == token else { throw AdapterExecutionError(.invalidOutput, "container transport token mismatch") }
    return record.acknowledged == true
  }

  func markAcknowledged(_ token: WorkflowAddonFinalizationToken) throws {
    guard var record = try read(tokenURL(token)), record.token == token else {
      throw AdapterExecutionError(.invalidOutput, "container finalization transport is missing")
    }
    record.acknowledged = true
    try write(record, to: tokenURL(token))
  }

  func remove(workflowExecutionId: String) throws {
    let directory = workflowRoot(workflowExecutionId)
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }

  private func tokenURL(_ token: WorkflowAddonFinalizationToken) -> URL {
    root.appendingPathComponent("tokens", isDirectory: true)
      .appendingPathComponent(sha256(Data(token.value.utf8)) + ".json")
  }

  private func workflowRoot(_ id: String) -> URL {
    root.appendingPathComponent("workflows", isDirectory: true).appendingPathComponent(sha256(Data(id.utf8)), isDirectory: true)
  }

  private func read(_ url: URL) throws -> Record? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      guard data.count <= BuiltinAddonContainerRequest.maximumRecordBytes else {
        throw AdapterExecutionError(.invalidOutput, "container transport record is too large")
      }
      let record = try JSONDecoder().decode(Record.self, from: data)
      guard record.version == 1 else {
        throw AdapterExecutionError(.invalidOutput, "unsupported container transport record")
      }
      try record.invocation.settings.validate()
      return record
    } catch {
      throw AdapterExecutionError(.invalidOutput, "invalid persisted container transport record")
    }
  }

  private func write(_ record: Record, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(record).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
