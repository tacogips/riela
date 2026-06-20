#if os(macOS)
import Foundation
import RielaEvents
import RielaServer

public struct RielaAppDaemonEventSourceSummary: Equatable, Sendable {
  public var id: String
  public var kind: String

  public init(id: String, kind: String) {
    self.id = id
    self.kind = kind
  }
}

public struct RielaAppDaemonWorkflowCandidate: Identifiable, Equatable, Sendable {
  public var id: String
  public var workflowId: String
  public var displayName: String
  public var sourceDescription: String
  public var workflowDirectory: String
  public var workingDirectory: String
  public var eventRoot: String
  public var eventSources: [RielaAppDaemonEventSourceSummary]

  public init(
    id: String,
    workflowId: String,
    displayName: String,
    sourceDescription: String,
    workflowDirectory: String,
    workingDirectory: String,
    eventRoot: String,
    eventSources: [RielaAppDaemonEventSourceSummary]
  ) {
    self.id = id
    self.workflowId = workflowId
    self.displayName = displayName
    self.sourceDescription = sourceDescription
    self.workflowDirectory = workflowDirectory
    self.workingDirectory = workingDirectory
    self.eventRoot = eventRoot
    self.eventSources = eventSources
  }

  public var eventSourceSummary: String {
    eventSources.map { "\($0.id):\($0.kind)" }.joined(separator: ", ")
  }

  public var serveSelection: WorkflowServeSelection {
    .directDirectory(workflowDirectory, identifier: workflowId)
  }
}

public struct RielaAppDaemonWorkflowPreference: Codable, Equatable, Sendable {
  public var identity: String
  public var enabledAtLaunch: Bool
  public var active: Bool

  public init(identity: String, enabledAtLaunch: Bool = false, active: Bool = true) {
    self.identity = identity
    self.enabledAtLaunch = enabledAtLaunch
    self.active = active
  }
}

public struct RielaAppDaemonWorkflowState: Codable, Equatable, Sendable {
  public var version: Int
  public var preferences: [String: RielaAppDaemonWorkflowPreference]

  public init(version: Int = 1, preferences: [String: RielaAppDaemonWorkflowPreference] = [:]) {
    self.version = version
    self.preferences = preferences
  }

  public func preference(for identity: String) -> RielaAppDaemonWorkflowPreference {
    preferences[identity] ?? RielaAppDaemonWorkflowPreference(identity: identity)
  }
}

public struct RielaAppDaemonWorkflowStore: Sendable {
  public var stateURL: URL

  public init(stateURL: URL = Self.defaultStateURL()) {
    self.stateURL = stateURL
  }

  public func load() -> RielaAppDaemonWorkflowState {
    guard let data = try? Data(contentsOf: stateURL) else {
      return RielaAppDaemonWorkflowState()
    }
    return (try? JSONDecoder().decode(RielaAppDaemonWorkflowState.self, from: data)) ?? RielaAppDaemonWorkflowState()
  }

  public func save(_ state: RielaAppDaemonWorkflowState) throws {
    try FileManager.default.createDirectory(
      at: stateURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(state).write(to: stateURL, options: .atomic)
  }

  public static func defaultStateURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    return base
      .appendingPathComponent("RielaApp", isDirectory: true)
      .appendingPathComponent("daemon-workflows.json")
  }
}

public struct RielaAppDaemonWorkflowDiscovery: Sendable {
  private struct MinimalWorkflow: Decodable {
    var workflowId: String
  }

  private struct PackageManifest: Decodable {
    var kind: String?
    var workflowDirectory: String?
    var name: String?
  }

  private struct EventBinding: Decodable {
    var enabled: Bool?
    var sourceId: String
    var workflowName: String?
  }

  private struct EventSource: Decodable {
    var id: String
    var kind: String
  }

  public var homeDirectory: URL

  public init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
    self.homeDirectory = homeDirectory
  }

  public func discoverUserDaemonWorkflows() -> [RielaAppDaemonWorkflowCandidate] {
    var candidates: [RielaAppDaemonWorkflowCandidate] = []
    candidates.append(contentsOf: discoverUserWorkflowDirectories())
    candidates.append(contentsOf: discoverUserPackageWorkflows())
    return Dictionary(grouping: candidates, by: \.id)
      .compactMap { _, values in values.first }
      .sorted { lhs, rhs in
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
      }
  }

  private func discoverUserWorkflowDirectories() -> [RielaAppDaemonWorkflowCandidate] {
    let root = homeDirectory.appendingPathComponent(".riela/workflows", isDirectory: true)
    let directories = directoryChildren(root)
    return directories.compactMap { directory in
      candidate(
        workflowDirectory: directory,
        sourceDescription: "user workflow",
        identityPrefix: "user-workflow"
      )
    }
  }

  private func discoverUserPackageWorkflows() -> [RielaAppDaemonWorkflowCandidate] {
    let root = homeDirectory.appendingPathComponent(".riela/packages", isDirectory: true)
    return directoryChildren(root).compactMap { packageDirectory in
      let manifestURL = packageDirectory.appendingPathComponent("riela-package.json")
      guard
        let data = try? Data(contentsOf: manifestURL),
        let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data),
        manifest.kind == nil || manifest.kind == "workflow"
      else {
        return nil
      }
      let workflowRelativePath = manifest.workflowDirectory ?? "workflows/\(packageDirectory.lastPathComponent)"
      let workflowDirectory = packageDirectory
        .appendingPathComponent(workflowRelativePath, isDirectory: true)
        .standardizedFileURL
      return candidate(
        workflowDirectory: workflowDirectory,
        packageDirectory: packageDirectory,
        packageName: manifest.name ?? packageDirectory.lastPathComponent,
        sourceDescription: "user package",
        identityPrefix: "user-package"
      )
    }
  }

  private func candidate(
    workflowDirectory: URL,
    packageDirectory: URL? = nil,
    packageName: String? = nil,
    sourceDescription: String,
    identityPrefix: String
  ) -> RielaAppDaemonWorkflowCandidate? {
    let workflowURL = workflowDirectory.appendingPathComponent("workflow.json")
    guard
      let data = try? Data(contentsOf: workflowURL),
      let workflow = try? JSONDecoder().decode(MinimalWorkflow.self, from: data)
    else {
      return nil
    }
    guard let eventRoot = eventRoots(workflowDirectory: workflowDirectory, packageDirectory: packageDirectory)
      .first(where: { daemonEventSources(eventRoot: $0, workflowId: workflow.workflowId).isEmpty == false })
    else {
      return nil
    }
    let eventSources = daemonEventSources(eventRoot: eventRoot, workflowId: workflow.workflowId)
    let packagePart = packageName.map { ":\($0)" } ?? ""
    return RielaAppDaemonWorkflowCandidate(
      id: "\(identityPrefix)\(packagePart):\(workflow.workflowId)",
      workflowId: workflow.workflowId,
      displayName: workflow.workflowId,
      sourceDescription: sourceDescription,
      workflowDirectory: workflowDirectory.path,
      workingDirectory: workflowDirectory.deletingLastPathComponent().path,
      eventRoot: eventRoot.path,
      eventSources: eventSources
    )
  }

  private func daemonEventSources(eventRoot: URL, workflowId: String) -> [RielaAppDaemonEventSourceSummary] {
    let sources = decodeDirectory(eventRoot.appendingPathComponent("sources", isDirectory: true), as: EventSource.self)
    let bindings = decodeDirectory(eventRoot.appendingPathComponent("bindings", isDirectory: true), as: EventBinding.self)
      .filter { binding in
        binding.enabled != false && binding.workflowName == workflowId
      }
    let boundSourceIds = Set(bindings.map(\.sourceId))
    return sources
      .filter { boundSourceIds.contains($0.id) && Self.isDaemonSourceKind($0.kind) }
      .map { RielaAppDaemonEventSourceSummary(id: $0.id, kind: $0.kind) }
      .sorted { $0.id < $1.id }
  }

  private func eventRoots(workflowDirectory: URL, packageDirectory: URL?) -> [URL] {
    var roots = [
      workflowDirectory.appendingPathComponent(".riela-events", isDirectory: true),
      workflowDirectory.appendingPathComponent("event-templates/.riela-events", isDirectory: true)
    ]
    if let packageDirectory {
      roots.append(packageDirectory.appendingPathComponent(".riela-events", isDirectory: true))
      roots.append(packageDirectory.appendingPathComponent("event-templates/.riela-events", isDirectory: true))
    }
    return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  private func directoryChildren(_ root: URL) -> [URL] {
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    return children.filter { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
  }

  private func decodeDirectory<T: Decodable>(_ directory: URL, as type: T.Type) -> [T] {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    return files
      .filter { $0.pathExtension == "json" }
      .compactMap { file in
        guard let data = try? Data(contentsOf: file) else {
          return nil
        }
        return try? JSONDecoder().decode(type, from: data)
      }
  }

  public static func isDaemonSourceKind(_ rawKind: String) -> Bool {
    switch EventSourceKind(rawValue: rawKind) {
    case .cron, .chatSdk, .discordGateway, .fileChange, .telegramGateway, .matrix, .s3Repository, .sequentialList:
      true
    case .webhook, .custom:
      false
    }
  }
}

@MainActor
public final class RielaAppDaemonWorkflowRuntime {
  public struct RuntimeSnapshot: Equatable {
    public var status: WorkflowServeStatus
    public var detail: String

    public init(status: WorkflowServeStatus, detail: String) {
      self.status = status
      self.detail = detail
    }
  }

  private struct RunningWorkflow {
    var candidate: RielaAppDaemonWorkflowCandidate
    var controller: WorkflowServingController
    var snapshot: RuntimeSnapshot
    var monitorTask: Task<Void, Never>?
  }

  private let eventSourceFactory: any WorkflowServeEventSourceFactory
  private let monitorIntervalNanoseconds: UInt64
  private var runningWorkflows: [String: RunningWorkflow] = [:]

  public init(
    eventSourceFactory: any WorkflowServeEventSourceFactory = RielaAppDaemonProcessEventSourceFactory(),
    monitorIntervalNanoseconds: UInt64 = 2_000_000_000
  ) {
    self.eventSourceFactory = eventSourceFactory
    self.monitorIntervalNanoseconds = monitorIntervalNanoseconds
  }

  public func snapshot(for identity: String) -> RuntimeSnapshot {
    runningWorkflows[identity]?.snapshot ?? RuntimeSnapshot(status: .stopped, detail: "Inactive")
  }

  public func start(_ candidate: RielaAppDaemonWorkflowCandidate) async {
    if runningWorkflows[candidate.id]?.snapshot.status == .running {
      return
    }
    await startController(candidate, monitorTask: nil)
    scheduleMonitorIfNeeded(for: candidate.id)
  }

  public func refresh(identity: String) async {
    guard let running = runningWorkflows[identity] else {
      return
    }
    let state = await running.controller.currentState()
    runningWorkflows[identity]?.snapshot = snapshot(from: state)
    guard shouldRestart(state) else {
      return
    }
    _ = try? await running.controller.stop()
    await startController(running.candidate, monitorTask: running.monitorTask)
  }

  private func startController(
    _ candidate: RielaAppDaemonWorkflowCandidate,
    monitorTask: Task<Void, Never>?
  ) async {
    let controller = WorkflowServingController(dependencies: WorkflowServingDependencies(
      eventSourceFactory: eventSourceFactory
    ))
    runningWorkflows[candidate.id] = RunningWorkflow(
      candidate: candidate,
      controller: controller,
      snapshot: RuntimeSnapshot(status: .starting, detail: "Starting"),
      monitorTask: monitorTask
    )
    do {
      let state = try await controller.start(WorkflowServeStartRequest(
        selection: candidate.serveSelection,
        server: RielaServerConfiguration(port: Self.port(for: candidate.id)),
        workingDirectory: candidate.workingDirectory,
        sessionStoreRoot: defaultSessionStoreRoot(),
        eventRoot: candidate.eventRoot,
        startsEventSources: true
      ))
      runningWorkflows[candidate.id]?.snapshot = snapshot(from: state)
    } catch {
      runningWorkflows[candidate.id]?.snapshot = RuntimeSnapshot(status: .failed, detail: "\(error)")
    }
  }

  public func stop(identity: String) async {
    guard let running = runningWorkflows[identity] else {
      return
    }
    running.monitorTask?.cancel()
    do {
      let state = try await running.controller.stop()
      runningWorkflows[identity]?.snapshot = snapshot(from: state)
    } catch {
      runningWorkflows[identity]?.snapshot = RuntimeSnapshot(status: .failed, detail: "\(error)")
      return
    }
    runningWorkflows.removeValue(forKey: identity)
  }

  private func scheduleMonitorIfNeeded(for identity: String) {
    guard monitorIntervalNanoseconds > 0, runningWorkflows[identity]?.monitorTask == nil else {
      return
    }
    let interval = monitorIntervalNanoseconds
    let task = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        await self?.refresh(identity: identity)
      }
    }
    runningWorkflows[identity]?.monitorTask = task
  }

  private func shouldRestart(_ state: WorkflowServeState) -> Bool {
    guard state.status == .running, let generation = state.generation else {
      return false
    }
    return generation.eventSources.contains { $0.status != "running" }
  }

  private func snapshot(from state: WorkflowServeState) -> RuntimeSnapshot {
    let detail: String
    if let generation = state.generation {
      let sources = generation.eventSources.map { source in
        source.status == "running" ? source.sourceId : "\(source.sourceId):\(source.status)"
      }.joined(separator: ", ")
      detail = sources.isEmpty ? generation.endpoint : "\(generation.endpoint) [\(sources)]"
    } else {
      detail = state.diagnostics.first?.message ?? state.status.rawValue
    }
    return RuntimeSnapshot(status: state.status, detail: detail)
  }

  private func defaultSessionStoreRoot() -> String {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".riela/sessions", isDirectory: true)
      .path
  }

  private static func port(for identity: String) -> Int {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in identity.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return 18_000 + Int(hash % 20_000)
  }
}
#endif
