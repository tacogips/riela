import Foundation
import RielaCore
import RielaWork

public struct DistributedControllerConfiguration: Codable, Equatable, Sendable {
  public struct Worker: Codable, Equatable, Sendable {
    public var id: String
    public var groups: Set<String>
    public var tokenEnvironment: String
    public var maxCapacity: Int

    public init(id: String, groups: Set<String>, tokenEnvironment: String, maxCapacity: Int) {
      self.id = id
      self.groups = groups
      self.tokenEnvironment = tokenEnvironment
      self.maxCapacity = maxCapacity
    }
  }

  public static let environmentKey = "RIELA_CONTROLLER_CONFIG"
  public var host: String
  public var port: Int
  public var storePath: String
  public var workers: [Worker]

  public init(host: String, port: Int, storePath: String, workers: [Worker]) {
    self.host = host
    self.port = port
    self.storePath = storePath
    self.workers = workers
  }

  public func validate() throws {
    func name(_ value: String) -> Bool {
      !value.isEmpty && value.utf8.count <= 256 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    guard name(host), (1...65535).contains(port), !storePath.isEmpty,
      !storePath.utf8.contains(0), !workers.isEmpty,
      Set(workers.map(\.id)).count == workers.count,
      workers.allSatisfy({ worker in
        name(worker.id) && worker.groups.allSatisfy(name) && (1...1024).contains(worker.maxCapacity)
          && worker.tokenEnvironment.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
      }) else { throw DistributedWorkerTransportError.invalidConfiguration }
  }

  public static func load(from url: URL) throws -> Self {
    let bytes = try Data(contentsOf: url)
    guard bytes.count <= 1024 * 1024 else { throw DistributedWorkerTransportError.invalidConfiguration }
    let config = try JSONDecoder().decode(Self.self, from: bytes)
    try config.validate()
    return config
  }

  public func controller(relativeTo configURL: URL) throws -> DistributedJobController {
    guard !storePath.isEmpty else { throw DistributedWorkerTransportError.invalidConfiguration }
    return try DistributedJobController(fileURL: storeURL(relativeTo: configURL)) {
      guard try Self.load(from: configURL) == self else { throw DistributedWorkerError.staleControllerConfiguration }
    }
  }

  public func saveIfIdle(replacing previous: Self?, at configURL: URL) async throws {
    try validate()
    let controller = try previous?.controller(relativeTo: configURL)
      ?? DistributedJobController(fileURL: storeURL(relativeTo: configURL))
    try await controller.updateConfigurationIfIdle {
      if previous == nil, FileManager.default.fileExists(atPath: configURL.path) {
        throw DistributedWorkerError.staleControllerConfiguration
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(self).write(to: configURL, options: .atomic)
    }
  }

  private func storeURL(relativeTo configURL: URL) -> URL {
    storePath.hasPrefix("/") ? URL(fileURLWithPath: storePath)
      : configURL.deletingLastPathComponent().appendingPathComponent(storePath)
  }

  func credentials(environment: [String: String]) throws -> [DistributedWorkerCredential] {
    try workers.map { worker in
      guard let token = environment[worker.tokenEnvironment] else { throw DistributedWorkerTransportError.invalidConfiguration }
      return .init(workerId: worker.id, groups: worker.groups, token: token, maxCapacity: worker.maxCapacity)
    }
  }
}

/// Independent of web assets and AppKit. Both the menu app and CLI own this
/// same listener; local workflow child processes share only its locked store.
public final class DistributedControllerHost: Sendable {
  public let controller: DistributedJobController
  public let executor: QueuedDistributedNodeExecutor
  public let configuration: DistributedControllerConfiguration
  private let server: RielaLocalHTTPServer

  public init(
    configurationURL: URL,
    environment: [String: String],
    capabilityStoreRoot: String? = nil
  ) throws {
    let configuration = try DistributedControllerConfiguration.load(from: configurationURL)
    let controller = try configuration.controller(relativeTo: configurationURL)
    self.configuration = configuration
    self.controller = controller
    self.executor = QueuedDistributedNodeExecutor(controller: controller)
    let capabilityStore = capabilityStoreRoot.map(WorkStore.init(rootDirectory:))
    server = RielaLocalHTTPServer(routeHandler: try DistributedWorkerHTTPRouter(
      controller: controller,
      credentials: configuration.credentials(environment: environment),
      capabilitySnapshotSink: { snapshot in try capabilityStore?.saveHostSnapshot(snapshot) }
    ))
  }

  @discardableResult public func start() async throws -> Int {
    try await server.start(host: configuration.host, port: configuration.port)
  }

  public func stop() async { await server.stop() }
}
