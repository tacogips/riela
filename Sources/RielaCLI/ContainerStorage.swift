import ArgumentParser
import CoreFoundation
import Foundation
#if os(Linux)
import Glibc
#endif
import RielaAdapters
import RielaCore

/// Opt-in disk-space policy for Riela-managed container builds (issue #195).
///
/// Configured under `containerStorage` in `.riela/config.json` (project keys
/// win over user keys) or through environment overrides. Nothing is enforced
/// or reclaimed unless a value is set.
struct ContainerStoragePolicy: Codable, Equatable, Sendable {
  /// Refuse to start a container add-on build/run when less than this much
  /// space is available on the Container data volume or the workspace volume.
  var minimumFreeMiB: Int?
  /// Apple Container only: after a Riela-managed image build (and before
  /// refusing work for low space), prune the shared BuildKit cache down to
  /// this size and return freed sparse-disk blocks to the host.
  var buildCacheBudgetMiB: Int?
  /// Upper bound for every inspection or cleanup command.
  var commandTimeoutSeconds: Int = 120

  static let configurationKeys: Set<String> = ["minimumFreeMiB", "buildCacheBudgetMiB", "commandTimeoutSeconds"]

  struct ConfigurationError: Error, CustomStringConvertible {
    var description: String
  }

  static func resolve(
    homeDirectory: String,
    projectDirectory: String?,
    environment: [String: String]
  ) throws -> ContainerStoragePolicy {
    var policy = ContainerStoragePolicy()
    let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? homeDirectory
    var files = [URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".riela/config.json")]
    if let projectDirectory {
      files.append(URL(fileURLWithPath: projectDirectory, isDirectory: true).appendingPathComponent(".riela/config.json"))
    }
    for url in files { try apply(url, to: &policy) }
    if let value = try integer(environment["RIELA_CONTAINER_MIN_FREE_MIB"], key: "RIELA_CONTAINER_MIN_FREE_MIB") {
      policy.minimumFreeMiB = value == 0 ? nil : value
    }
    if let value = try integer(environment["RIELA_CONTAINER_BUILD_CACHE_BUDGET_MIB"], key: "RIELA_CONTAINER_BUILD_CACHE_BUDGET_MIB") {
      policy.buildCacheBudgetMiB = value == 0 ? nil : value
    }
    if let value = try integer(environment["RIELA_CONTAINER_COMMAND_TIMEOUT_SECONDS"], key: "RIELA_CONTAINER_COMMAND_TIMEOUT_SECONDS") {
      policy.commandTimeoutSeconds = value
    }
    guard (1...3600).contains(policy.commandTimeoutSeconds) else {
      throw ConfigurationError(description: "containerStorage.commandTimeoutSeconds must be between 1 and 3600")
    }
    return policy
  }

  private static func apply(_ url: URL, to policy: inout ContainerStoragePolicy) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    } catch {
      throw ConfigurationError(description: "could not read container storage configuration at \(url.path): \(error)")
    }
    guard let root = object as? [String: Any], let raw = root["containerStorage"] else { return }
    guard let section = raw as? [String: Any] else {
      throw ConfigurationError(description: "containerStorage in \(url.path) must be an object")
    }
    let unknown = Set(section.keys).subtracting(configurationKeys)
    guard unknown.isEmpty else {
      throw ConfigurationError(description: "unknown containerStorage configuration key: \(unknown.sorted().joined(separator: ", "))")
    }
    if section.keys.contains("minimumFreeMiB") {
      policy.minimumFreeMiB = try configured(section["minimumFreeMiB"], key: "minimumFreeMiB", url: url)
    }
    if section.keys.contains("buildCacheBudgetMiB") {
      policy.buildCacheBudgetMiB = try configured(section["buildCacheBudgetMiB"], key: "buildCacheBudgetMiB", url: url)
    }
    if let timeout = try configured(section["commandTimeoutSeconds"], key: "commandTimeoutSeconds", url: url) {
      policy.commandTimeoutSeconds = timeout
    }
  }

  private static func configured(_ value: Any?, key: String, url: URL) throws -> Int? {
    if value == nil || value is NSNull { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue == number.doubleValue.rounded(), number.intValue >= 1 else {
      throw ConfigurationError(description: "containerStorage.\(key) in \(url.path) must be a positive integer or null")
    }
    return number.intValue
  }

  private static func integer(_ raw: String?, key: String) throws -> Int? {
    guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    guard let value = Int(raw), value >= 0 else {
      throw ConfigurationError(description: "\(key) must be a non-negative integer")
    }
    return value
  }
}

struct ContainerStorageCapacity: Codable, Equatable, Sendable {
  var path: String
  var availableBytes: Int64?
  var diagnostic: String?
}

struct ContainerStorageCommandOutcome: Codable, Equatable, Sendable {
  var arguments: [String]
  var exitCode: Int32?
  var timedOut: Bool
  var diagnostic: String?
}

struct ContainerStorageReport: Codable, Equatable, Sendable {
  /// `ok`, `low` (below `minimumFreeMiB`), or `unknown` (capacity unreadable).
  var status: String
  var runtime: String?
  var policy: ContainerStoragePolicy
  var capacity: [ContainerStorageCapacity]
  /// `container system df --format json` (images, containers, volumes).
  var usage: JSONObject?
  /// `running`, `stopped`, `absent` or `unknown` (Apple Container builder).
  var builder: String?
  var reclaim: [ContainerStorageCommandOutcome]?
  var diagnostics: [String]
}

/// Inspection and native reclamation for the container runtime's storage.
///
/// Reclamation is limited to the shared BuildKit cache: records not used by a
/// running build are pruned down to the budget (`buildctl prune --all
/// --keep-storage`), then `container clean buildkit` returns freed blocks of the
/// builder's sparse disk to the host. Images, user containers and named volumes
/// are never removed.
struct ContainerStorageMaintenance: Sendable {
  var driver: (any ContainerRuntimeDriver)?
  var policy: ContainerStoragePolicy
  var workingDirectory: URL
  var environment: [String: String]
  var runner: any LocalProcessRunning = FoundationLocalProcessRunner()
  var capacityProbe: @Sendable (String) throws -> Int64 = { path in
    #if os(macOS)
    let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let available = values.volumeAvailableCapacityForImportantUsage else {
      throw ContainerStoragePolicy.ConfigurationError(description: "available capacity is not reported")
    }
    return available
    #else
    var stats = statvfs()
    guard statvfs(path, &stats) == 0 else {
      throw ContainerStoragePolicy.ConfigurationError(description: "statvfs failed with errno \(errno)")
    }
    return Int64(stats.f_bavail) * Int64(stats.f_frsize)
    #endif
  }

  static let builderContainerId = "buildkit"

  var capacityPaths: [String] {
    var paths: [String] = []
    if driver?.kind == .appleContainer {
      let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
      let appRoot = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/com.apple.container").path
      if FileManager.default.fileExists(atPath: appRoot) { paths.append(appRoot) }
    }
    paths.append(workingDirectory.standardizedFileURL.path)
    return paths
  }

  /// Bounded: a stalled volume reports a diagnostic instead of hanging.
  func capacity() -> [ContainerStorageCapacity] {
    capacityPaths.map { path in
      let probe = capacityProbe
      do {
        let bytes = try BoundedSessionStoreIO.runBlocking(key: "capacity:" + path,
          timeout: TimeInterval(min(policy.commandTimeoutSeconds, 30))) { try probe(path) }
        return ContainerStorageCapacity(path: path, availableBytes: bytes, diagnostic: nil)
      } catch {
        return ContainerStorageCapacity(path: path, availableBytes: nil, diagnostic: "capacity unavailable: \(error)")
      }
    }
  }

  func status(of capacity: [ContainerStorageCapacity]) -> String {
    guard let minimum = policy.minimumFreeMiB else {
      return capacity.contains { $0.availableBytes == nil } ? "unknown" : "ok"
    }
    let threshold = Int64(minimum) * 1_048_576
    if capacity.contains(where: { ($0.availableBytes ?? Int64.max) < threshold }) { return "low" }
    return capacity.contains { $0.availableBytes == nil } ? "unknown" : "ok"
  }

  func report(reclaim: Bool, keepStorageMiB: Int?) async -> ContainerStorageReport {
    var diagnostics: [String] = []
    var reclaimed: [ContainerStorageCommandOutcome]?
    var builder: String?
    var usage: JSONObject?
    if let driver {
      if driver.kind == .appleContainer {
        builder = await builderState()
        if reclaim {
          if let budget = keepStorageMiB ?? policy.buildCacheBudgetMiB {
            reclaimed = await reclaimBuildCache(keepStorageMiB: budget, builderState: builder)
          } else {
            diagnostics.append("reclaim skipped: set --keep-storage-mib or containerStorage.buildCacheBudgetMiB")
          }
        }
        let df = await command(["system", "df", "--format", "json"])
        if df.outcome.exitCode == 0, let data = df.stdout.data(using: .utf8),
           let object = try? JSONDecoder().decode(JSONObject.self, from: data) {
          usage = object
        } else {
          diagnostics.append("container system df unavailable: " + (df.outcome.diagnostic ?? "exit \(df.outcome.exitCode.map(String.init) ?? "-")"))
        }
      } else {
        diagnostics.append("usage inspection and reclaim are implemented for apple-container; \(driver.kind.rawValue) is reported for capacity only")
      }
    } else {
      diagnostics.append("no container runtime found")
    }
    let capacity = capacity()
    diagnostics += capacity.compactMap(\.diagnostic)
    return ContainerStorageReport(status: status(of: capacity), runtime: driver?.kind.rawValue, policy: policy,
      capacity: capacity, usage: usage, builder: builder, reclaim: reclaimed, diagnostics: diagnostics)
  }

  func builderState() async -> String {
    let result = await command(["builder", "status", "--format", "json"])
    guard result.outcome.exitCode == 0 else { return result.outcome.timedOut ? "unknown" : "absent" }
    guard let data = result.stdout.data(using: .utf8),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return "unknown" }
    guard let row = rows.first else { return "absent" }
    return (row["status"] as? String) == "running" ? "running" : "stopped"
  }

  /// Prunes only build cache records no running build uses, then trims the
  /// builder's sparse disk. A stopped or absent builder holds no reclaimable
  /// runtime cache, so it is left alone rather than started.
  func reclaimBuildCache(keepStorageMiB: Int, builderState: String? = nil) async -> [ContainerStorageCommandOutcome] {
    guard driver?.kind == .appleContainer else { return [] }
    let state: String
    if let builderState { state = builderState } else { state = await self.builderState() }
    guard state == "running" else {
      return [ContainerStorageCommandOutcome(arguments: [], exitCode: nil, timedOut: false,
        diagnostic: "builder \(state); nothing to reclaim")]
    }
    let prune = await command(["exec", Self.builderContainerId, "buildctl", "prune", "--all",
      "--keep-storage", String(keepStorageMiB)])
    let clean = await command(["clean", Self.builderContainerId])
    return [prune.outcome, clean.outcome]
  }

  /// The low-space gate run before a container add-on build or run. When the
  /// space is low and a cache budget is configured, it reclaims once first.
  /// Throws a non-retryable, not-dispatched failure so callers never mistake
  /// the refusal for an executed (possibly side-effecting) attempt.
  func ensureCapacity(addonName: String) async throws {
    guard let minimum = policy.minimumFreeMiB else { return }
    var capacity = capacity()
    if status(of: capacity) == "low", let budget = policy.buildCacheBudgetMiB {
      _ = await reclaimBuildCache(keepStorageMiB: budget)
      capacity = self.capacity()
    }
    guard status(of: capacity) == "low" else { return }
    let detail = capacity.filter { ($0.availableBytes ?? Int64.max) < Int64(minimum) * 1_048_576 }
      .map { "\($0.path): \(($0.availableBytes ?? 0) / 1_048_576) MiB free" }.joined(separator: ", ")
    throw AdapterExecutionError(.providerError,
      "insufficient_disk_space: container add-on '\(addonName)' was not started; below containerStorage.minimumFreeMiB " +
        "(\(minimum) MiB) on \(detail). Free space or run `riela storage container --reclaim`.",
      isRetryable: false, effectOutcome: .notDispatched)
  }

  private func command(_ arguments: [String]) async -> (outcome: ContainerStorageCommandOutcome, stdout: String) {
    guard let driver else {
      return (ContainerStorageCommandOutcome(arguments: arguments, exitCode: nil, timedOut: false,
        diagnostic: "no container runtime"), "")
    }
    let invocation: (URL, [String]) = driver.executable.hasPrefix("/")
      ? (URL(fileURLWithPath: driver.executable), arguments)
      : (URL(fileURLWithPath: "/usr/bin/env"), [driver.executable] + arguments)
    let configuration = LocalProcessConfiguration(executableURL: invocation.0, arguments: invocation.1,
      environment: environment, workingDirectoryURL: workingDirectory)
    let deadline = Date().addingTimeInterval(TimeInterval(policy.commandTimeoutSeconds))
    do {
      let result = try await runner.run(configuration: configuration, stdin: "", deadline: deadline)
      let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      return (ContainerStorageCommandOutcome(arguments: arguments, exitCode: result.terminationStatus, timedOut: false,
        diagnostic: result.terminationStatus == 0 || stderr.isEmpty ? nil : String(stderr.prefix(400))), result.stdout)
    } catch {
      let timedOut = (error as? AdapterExecutionError)?.code == .timeout || Date() >= deadline
      return (ContainerStorageCommandOutcome(arguments: arguments, exitCode: nil, timedOut: timedOut,
        diagnostic: String(String(describing: error).prefix(400))), "")
    }
  }
}

struct ParsedContainerStorageArguments: ParsableArguments {
  @Flag(help: "Prune the BuildKit cache to the budget and return freed sparse-disk blocks.")
  var reclaim = false
  @Option(help: "Cache budget for --reclaim (defaults to containerStorage.buildCacheBudgetMiB).")
  var keepStorageMib: Int?
  @Option var workingDir: String?
  @Option var output = "json"
}

/// `riela storage container [--reclaim] [--keep-storage-mib N]`.
struct ContainerStorageCommandRunner {
  var environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  var makeMaintenance: (@Sendable (ContainerStorageMaintenance) -> ContainerStorageMaintenance)?

  static let usage = "riela storage container [--reclaim] [--keep-storage-mib <n>] [--working-dir <dir>] [--output json|text]"

  func run(_ arguments: [String]) async -> CLICommandResult {
    if arguments.contains("--help") || arguments.contains("-h") {
      return CLICommandResult(exitCode: .success, stdout: Self.helpText + "\n")
    }
    let parsed: ParsedContainerStorageArguments
    let policy: ContainerStoragePolicy
    do {
      do { parsed = try ParsedContainerStorageArguments.parse(arguments) } catch {
        throw CLIUsageError(ParsedContainerStorageArguments.message(for: error))
      }
      guard ["json", "text"].contains(parsed.output) else { throw CLIUsageError("storage container --output must be json or text") }
      if let keep = parsed.keepStorageMib, !(1...10_485_760).contains(keep) {
        throw CLIUsageError("--keep-storage-mib must be between 1 and 10485760")
      }
      if parsed.keepStorageMib != nil, !parsed.reclaim { throw CLIUsageError("--keep-storage-mib requires --reclaim") }
      let directory = parsed.workingDir ?? FileManager.default.currentDirectoryPath
      policy = try ContainerStoragePolicy.resolve(homeDirectory: CLIRuntimeEnvironment.homeDirectory(environment: environment),
        projectDirectory: directory, environment: environment)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .usage, stderr: String(describing: error))
    }
    let directory = URL(fileURLWithPath: parsed.workingDir ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let discovery = ContainerRuntimeDiscovery(environment: environment)
    var maintenance = ContainerStorageMaintenance(driver: discovery.configuredDriver() ?? discovery.selectedAvailableDriver(),
      policy: policy, workingDirectory: directory, environment: environment)
    if let makeMaintenance { maintenance = makeMaintenance(maintenance) }
    let report = await maintenance.report(reclaim: parsed.reclaim, keepStorageMiB: parsed.keepStorageMib)
    let exitCode: CLIExitCode = report.status == "low" ? .gateCheckFailed : .success
    if parsed.output == "text" {
      var lines = ["status: \(report.status)", "runtime: \(report.runtime ?? "none")"]
      lines += report.capacity.map { "free \($0.path): " + ($0.availableBytes.map { "\($0 / 1_048_576) MiB" } ?? "unknown") }
      if let builder = report.builder { lines.append("builder: \(builder)") }
      lines += (report.reclaim ?? []).map { "reclaim \($0.arguments.joined(separator: " ")): " +
        ($0.timedOut ? "timed out" : $0.exitCode.map { "exit \($0)" } ?? ($0.diagnostic ?? "skipped")) }
      lines += report.diagnostics.map { "note: \($0)" }
      return CLICommandResult(exitCode: exitCode, stdout: lines.joined(separator: "\n") + "\n")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return CLICommandResult(exitCode: exitCode,
      stdout: ((try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}") + "\n")
  }

  static var helpText: String {
    """
    Usage:
      \(usage)

    Report host free space for the Container data and workspace volumes, the
    runtime's image/container/volume usage, and the BuildKit builder state.
    Exit 3 when free space is below containerStorage.minimumFreeMiB.

    --reclaim prunes BuildKit cache records that no running build uses down to
    the budget (`container exec buildkit buildctl prune --all --keep-storage`),
    then returns freed sparse-disk blocks to the host (`container clean
    buildkit`). It never removes images, containers or named volumes, and never
    starts a stopped builder. The builder cache is shared by every build on this
    host, not only Riela's.

    Policy (.riela/config.json, project keys override user keys):
      {"containerStorage": {"minimumFreeMiB": 4096, "buildCacheBudgetMiB": 2048, "commandTimeoutSeconds": 120}}
    Environment overrides: RIELA_CONTAINER_MIN_FREE_MIB, RIELA_CONTAINER_BUILD_CACHE_BUDGET_MIB,
    RIELA_CONTAINER_COMMAND_TIMEOUT_SECONDS (0 disables a limit).
    """
  }
}
