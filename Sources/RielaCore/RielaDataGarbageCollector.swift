import Foundation
import RielaSQLite
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RielaGarbageCollectionConfiguration: Codable, Equatable, Sendable {
  public struct GarbageCollection: Codable, Equatable, Sendable {
    public var retentionDays: Int?

    public init(retentionDays: Int? = nil) {
      self.retentionDays = retentionDays
    }
  }

  public var gc: GarbageCollection

  public init(gc: GarbageCollection = GarbageCollection()) {
    self.gc = gc
  }

  private enum CodingKeys: String, CodingKey {
    case gc
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    gc = try container.decodeIfPresent(GarbageCollection.self, forKey: .gc) ?? GarbageCollection()
  }

  public static func load(
    homeDirectory: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) throws -> RielaGarbageCollectionConfiguration {
    var configuration = RielaGarbageCollectionConfiguration()
    let configurationURL = homeDirectory
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("config.json")
    if fileManager.fileExists(atPath: configurationURL.path) {
      configuration = try JSONDecoder().decode(
        RielaGarbageCollectionConfiguration.self,
        from: Data(contentsOf: configurationURL)
      )
    }
    if let rawValue = environment["RIELA_GC_RETENTION_DAYS"], !rawValue.isEmpty {
      guard let days = Int(rawValue), days > 0 else {
        throw RielaGarbageCollectionError.invalidRetentionDays(rawValue)
      }
      configuration.gc.retentionDays = days
    }
    if let days = configuration.gc.retentionDays, days <= 0 {
      throw RielaGarbageCollectionError.invalidRetentionDays(String(days))
    }
    return configuration
  }
}

public enum RielaGarbageCollectionScope: String, Codable, Equatable, Sendable {
  case user
  case project
  case all
}

public enum RielaGarbageCollectionDecision: String, Codable, Equatable, Sendable {
  case removed
  case wouldRemove
  case kept
  case skipped
}

public struct RielaGarbageCollectionItem: Codable, Equatable, Sendable {
  public var path: String
  public var decision: RielaGarbageCollectionDecision

  public init(path: String, decision: RielaGarbageCollectionDecision) {
    self.path = path
    self.decision = decision
  }
}

public struct RielaGarbageCollectionReport: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var dryRun: Bool
  public var retentionDays: Int?
  public var cutoff: Date?
  public var roots: [String]
  public var removedSessionCount: Int
  public var removedEntryCount: Int
  public var reclaimedBytes: Int64
  public var diagnostics: [String]
  public var handoverFiles: [RielaGarbageCollectionItem]
  public var handoverRefs: [RielaGarbageCollectionItem]

  public init(
    enabled: Bool,
    dryRun: Bool,
    retentionDays: Int?,
    cutoff: Date?,
    roots: [String],
    removedSessionCount: Int = 0,
    removedEntryCount: Int = 0,
    reclaimedBytes: Int64 = 0,
    diagnostics: [String] = [],
    handoverFiles: [RielaGarbageCollectionItem] = [],
    handoverRefs: [RielaGarbageCollectionItem] = []
  ) {
    self.enabled = enabled
    self.dryRun = dryRun
    self.retentionDays = retentionDays
    self.cutoff = cutoff
    self.roots = roots
    self.removedSessionCount = removedSessionCount
    self.removedEntryCount = removedEntryCount
    self.reclaimedBytes = reclaimedBytes
    self.diagnostics = diagnostics
    self.handoverFiles = handoverFiles
    self.handoverRefs = handoverRefs
  }
}

public enum RielaGarbageCollectionError: Error, Equatable, Sendable {
  case invalidRetentionDays(String)
}

extension RielaGarbageCollectionError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .invalidRetentionDays(value):
      "GC retention days must be a positive integer, received '\(value)'"
    }
  }
}

public struct RielaDataGarbageCollector {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func collect(
    retentionDays: Int?,
    scope: RielaGarbageCollectionScope,
    homeDirectory: URL,
    projectDirectory: URL,
    dryRun: Bool = false,
    now: Date = Date()
  ) -> RielaGarbageCollectionReport {
    let roots = collectionRoots(scope: scope, homeDirectory: homeDirectory, projectDirectory: projectDirectory)
    guard let retentionDays else {
      return RielaGarbageCollectionReport(
        enabled: false,
        dryRun: dryRun,
        retentionDays: nil,
        cutoff: nil,
        roots: roots.map(\.path)
      )
    }
    guard retentionDays > 0 else {
      return RielaGarbageCollectionReport(
        enabled: false,
        dryRun: dryRun,
        retentionDays: retentionDays,
        cutoff: nil,
        roots: roots.map(\.path),
        diagnostics: [RielaGarbageCollectionError.invalidRetentionDays(String(retentionDays)).localizedDescription]
      )
    }
    let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
    var report = RielaGarbageCollectionReport(
      enabled: true,
      dryRun: dryRun,
      retentionDays: retentionDays,
      cutoff: cutoff,
      roots: roots.map(\.path)
    )
    let projectStoreRoot = projectDirectory.appendingPathComponent(".riela", isDirectory: true).standardizedFileURL
    for root in roots {
      collect(
        root: root,
        cutoff: cutoff,
        dryRun: dryRun,
        report: &report
      )
    }
    if roots.contains(projectStoreRoot), !isSymbolicLink(projectStoreRoot) {
      collectHandoverRefs(
        projectDirectory: projectDirectory.standardizedFileURL,
        taskStoreRoot: projectStoreRoot,
        dryRun: dryRun,
        report: &report
      )
    }
    return report
  }

  private func collectionRoots(
    scope: RielaGarbageCollectionScope,
    homeDirectory: URL,
    projectDirectory: URL
  ) -> [URL] {
    let userRoot = homeDirectory.appendingPathComponent(".riela", isDirectory: true).standardizedFileURL
    let projectRoot = projectDirectory.appendingPathComponent(".riela", isDirectory: true).standardizedFileURL
    switch scope {
    case .user:
      return [userRoot]
    case .project:
      return [projectRoot]
    case .all:
      return userRoot == projectRoot ? [userRoot] : [userRoot, projectRoot]
    }
  }

  private func collect(
    root: URL,
    cutoff: Date,
    dryRun: Bool,
    report: inout RielaGarbageCollectionReport
  ) {
    guard fileManager.fileExists(atPath: root.path) else { return }
    guard !isSymbolicLink(root) else {
      report.diagnostics.append("refusing symbolic-link GC root: \(root.path)")
      return
    }
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let database = sessions
      .appendingPathComponent("runtime-records", isDirectory: true)
      .appendingPathComponent("runtime-message-log.sqlite")
    if fileManager.fileExists(atPath: database.path) {
      do {
        let databaseResult = try collectDatabase(
          at: database,
          cutoff: cutoff,
          dryRun: dryRun
        )
        report.removedSessionCount += databaseResult.sessionIds.count
        report.removedEntryCount += databaseResult.rowCount
      } catch {
        report.diagnostics.append("\(database.path): \(error.localizedDescription)")
      }
    }
    collectWorkflowHistory(
      at: root.appendingPathComponent("workflow-history", isDirectory: true),
      cutoff: cutoff,
      dryRun: dryRun,
      report: &report
    )
    collectDirectAgedChildren(
      at: root.appendingPathComponent("events/receipts", isDirectory: true),
      cutoff: cutoff,
      dryRun: dryRun,
      report: &report
    )
    for directory in ["artifacts", "logs"] {
      collectDirectAgedChildren(
        at: root.appendingPathComponent(directory, isDirectory: true),
        cutoff: cutoff,
        dryRun: dryRun,
        report: &report
      )
    }
    let sessionStore = root.appendingPathComponent("sessions", isDirectory: true)
    let runtimeRecords = sessionStore.appendingPathComponent("runtime-records", isDirectory: true)
    // File-sink packets live under `<session-store>/handovers` and under the Work Runtime
    // store root (`<session-store>/runtime-records/handovers`) that task code passes as storeRoot.
    for (parents, handovers) in [
      ([sessionStore], sessionStore.appendingPathComponent("handovers", isDirectory: true)),
      ([sessionStore, runtimeRecords], runtimeRecords.appendingPathComponent("handovers", isDirectory: true))
    ] {
      collectHandoverFiles(
        root: root,
        parents: parents,
        handovers: handovers,
        dryRun: dryRun,
        report: &report
      )
    }
  }

  private func collectHandoverFiles(
    root: URL,
    parents: [URL],
    handovers: URL,
    dryRun: Bool,
    report: inout RielaGarbageCollectionReport
  ) {
    guard fileManager.fileExists(atPath: handovers.path) else { return }
    if let symlinkParent = parents.first(where: { isSymbolicLink($0) }) {
      report.diagnostics.append("refusing handover files below symbolic-link directory: \(symlinkParent.path)")
      report.handoverFiles.append(.init(path: handovers.path, decision: .skipped))
      return
    }
    guard !isSymbolicLink(handovers),
          let taskDirectories = try? fileManager.contentsOfDirectory(
            at: handovers,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
          ) else {
      report.diagnostics.append("unable to safely enumerate handover files: \(handovers.path)")
      report.handoverFiles.append(.init(path: handovers.path, decision: .skipped))
      return
    }
    guard !taskDirectories.isEmpty else { return }

    let databaseURL = taskDatabaseURL(root: root)
    let taskStates: [String: String]
    do {
      taskStates = try readTaskStates(databaseURL: databaseURL)
    } catch {
      report.diagnostics.append("\(databaseURL.path): \(error.localizedDescription); handover files were left untouched")
      report.handoverFiles.append(contentsOf: taskDirectories.map {
        .init(path: $0.path, decision: .skipped)
      })
      return
    }

    for taskDirectory in taskDirectories {
      guard !isSymbolicLink(taskDirectory) else {
        report.diagnostics.append("refusing symbolic-link handover task directory: \(taskDirectory.path)")
        report.handoverFiles.append(.init(path: taskDirectory.path, decision: .skipped))
        continue
      }
      guard (try? taskDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        report.diagnostics.append("refusing non-directory handover task entry: \(taskDirectory.path)")
        report.handoverFiles.append(.init(path: taskDirectory.path, decision: .skipped))
        continue
      }
      let state = taskStates[taskDirectory.lastPathComponent]
      if let state, !Self.terminalTaskStates.contains(state) {
        report.handoverFiles.append(.init(path: taskDirectory.path, decision: .kept))
        continue
      }
      if remove(taskDirectory, dryRun: dryRun, report: &report) {
        report.handoverFiles.append(.init(
          path: taskDirectory.path,
          decision: dryRun ? .wouldRemove : .removed
        ))
      } else {
        report.handoverFiles.append(.init(path: taskDirectory.path, decision: .skipped))
      }
    }
  }

  private func collectHandoverRefs(
    projectDirectory: URL,
    taskStoreRoot: URL,
    dryRun: Bool,
    report: inout RielaGarbageCollectionReport
  ) {
    let repositoryCheck: ProcessResult
    do {
      repositoryCheck = try runGit(["rev-parse", "--git-dir"], in: projectDirectory)
    } catch {
      return
    }
    guard repositoryCheck.exitCode == 0 else { return }

    let listing: ProcessResult
    do {
      listing = try runGit(
        ["for-each-ref", "--format=%(refname)", "refs/riela/handovers/"],
        in: projectDirectory
      )
    } catch {
      report.diagnostics.append("unable to list local handover refs in \(projectDirectory.path): \(error.localizedDescription)")
      return
    }
    guard listing.exitCode == 0 else {
      report.diagnostics.append("unable to list local handover refs in \(projectDirectory.path): \(listing.stderr)")
      return
    }
    let refs = listing.stdout
      .split(whereSeparator: \.isNewline)
      .map(String.init)
    guard !refs.isEmpty else { return }

    let databaseURL = taskDatabaseURL(root: taskStoreRoot)
    let taskStates: [String: String]
    do {
      taskStates = try readTaskStates(databaseURL: databaseURL)
    } catch {
      report.diagnostics.append("\(databaseURL.path): \(error.localizedDescription); handover refs were left untouched")
      report.handoverRefs.append(contentsOf: refs.map {
        .init(path: $0, decision: .skipped)
      })
      return
    }

    for ref in refs {
      guard let taskId = Self.taskID(fromHandoverRef: ref) else {
        report.diagnostics.append("refusing malformed local handover ref: \(ref)")
        report.handoverRefs.append(.init(path: ref, decision: .skipped))
        continue
      }
      let state = taskStates[taskId]
      if let state, !Self.terminalTaskStates.contains(state) {
        report.handoverRefs.append(.init(path: ref, decision: .kept))
        continue
      }
      if !dryRun {
        do {
          let deletion = try runGit(["update-ref", "-d", ref], in: projectDirectory)
          guard deletion.exitCode == 0 else {
            report.diagnostics.append("unable to remove local handover ref \(ref): \(deletion.stderr)")
            report.handoverRefs.append(.init(path: ref, decision: .skipped))
            continue
          }
        } catch {
          report.diagnostics.append("unable to remove local handover ref \(ref): \(error.localizedDescription)")
          report.handoverRefs.append(.init(path: ref, decision: .skipped))
          continue
        }
      }
      report.handoverRefs.append(.init(path: ref, decision: dryRun ? .wouldRemove : .removed))
    }
  }

  private func taskDatabaseURL(root: URL) -> URL {
    root.appendingPathComponent("sessions/runtime-records/runtime-message-log.sqlite")
  }

  private func readTaskStates(databaseURL: URL) throws -> [String: String] {
    guard fileManager.fileExists(atPath: databaseURL.path) else {
      throw HandoverCollectionError.missingTaskDatabase
    }
    let options = SQLiteOpenOptions(
      enableWAL: false,
      busyTimeoutMilliseconds: 250,
      requireJSONB: false,
      waitForLocks: false
    )
    let database = try SQLiteDatabase.open(path: databaseURL.path, mode: .strictReadOnly, options: options)
    guard try database.tableExists("work_tasks") else {
      throw HandoverCollectionError.missingTaskTable
    }
    let rows = try database.query("SELECT task_id, state FROM work_tasks")
    return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
      guard let taskId = row["task_id"], let state = row["state"] else { return nil }
      return (taskId, state)
    })
  }

  private static func taskID(fromHandoverRef ref: String) -> String? {
    let prefix = "refs/riela/handovers/"
    guard ref.hasPrefix(prefix) else { return nil }
    let components = ref.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2, components.allSatisfy({ !$0.isEmpty }) else { return nil }
    return String(components[0])
  }

  private static let terminalTaskStates: Set<String> = ["succeeded", "failed", "cancelled", "superseded"]

  private func runGit(_ arguments: [String], in directory: URL) throws -> ProcessResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let output = ProcessOutputBuffer()
    let errorOutput = ProcessOutputBuffer()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = environment
    process.standardOutput = standardOutput
    process.standardError = standardError
    standardOutput.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      } else {
        output.append(data)
      }
    }
    standardError.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      } else {
        errorOutput.append(data)
      }
    }
    try process.run()
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.025)
    }
    if process.isRunning {
      process.terminate()
      let terminationDeadline = Date().addingTimeInterval(1)
      while process.isRunning && Date() < terminationDeadline {
        Thread.sleep(forTimeInterval: 0.025)
      }
      if process.isRunning {
        _ = kill(process.processIdentifier, SIGKILL)
      }
      process.waitUntilExit()
      standardOutput.fileHandleForReading.readabilityHandler = nil
      standardError.fileHandleForReading.readabilityHandler = nil
      throw HandoverCollectionError.gitTimedOut
    }
    process.waitUntilExit()
    standardOutput.fileHandleForReading.readabilityHandler = nil
    standardError.fileHandleForReading.readabilityHandler = nil
    return ProcessResult(
      stdout: output.string,
      stderr: errorOutput.string,
      exitCode: process.terminationStatus
    )
  }

  private func collectDatabase(
    at databaseURL: URL,
    cutoff: Date,
    dryRun: Bool
  ) throws -> (sessionIds: Set<String>, rowCount: Int) {
    let database = try SQLiteDatabase.open(path: databaseURL.path)
    let cutoffString = Self.dateString(cutoff)
    var sessionIds = Set<String>()
    if try database.tableExists("workflow_runtime_snapshots") {
      let rows = try database.query(
        "SELECT workflow_execution_id FROM workflow_runtime_snapshots WHERE updated_at < ?",
        bindings: [.text(cutoffString)]
      )
      sessionIds.formUnion(rows.compactMap { $0["workflow_execution_id"] })
    }
    if try database.tableExists("cli_workflow_sessions") {
      let rows = try database.query(
        "SELECT session_id FROM cli_workflow_sessions WHERE updated_at < ?",
        bindings: [.text(cutoffString)]
      )
      sessionIds.formUnion(rows.compactMap { $0["session_id"] })
    }
    guard !dryRun, !sessionIds.isEmpty else {
      return (sessionIds, sessionIds.count)
    }
    var removedRows = 0
    try database.transaction { database in
      for sessionId in sessionIds {
        for table in ["workflow_message_payload_index", "workflow_messages"] where try database.tableExists(table) {
          removedRows += try database.executeAndReturnChangedRowCount(
            "DELETE FROM \(table) WHERE workflow_execution_id = ?",
            bindings: [.text(sessionId)]
          )
        }
        if try database.tableExists("workflow_runtime_snapshots") {
          removedRows += try database.executeAndReturnChangedRowCount(
            "DELETE FROM workflow_runtime_snapshots WHERE workflow_execution_id = ?",
            bindings: [.text(sessionId)]
          )
        }
        if try database.tableExists("cli_workflow_sessions") {
          removedRows += try database.executeAndReturnChangedRowCount(
            "DELETE FROM cli_workflow_sessions WHERE session_id = ?",
            bindings: [.text(sessionId)]
          )
        }
        if try database.tableExists("loop_baselines") {
          removedRows += try database.executeAndReturnChangedRowCount(
            "DELETE FROM loop_baselines WHERE session_id = ?",
            bindings: [.text(sessionId)]
          )
        }
        if try database.tableExists("loop_concurrency_leases") {
          removedRows += try database.executeAndReturnChangedRowCount(
            "DELETE FROM loop_concurrency_leases WHERE session_id = ? AND heartbeat_at < ?",
            bindings: [.text(sessionId), .text(cutoffString)]
          )
        }
      }
    }
    return (sessionIds, removedRows)
  }

  private func collectWorkflowHistory(
    at root: URL,
    cutoff: Date,
    dryRun: Bool,
    report: inout RielaGarbageCollectionReport
  ) {
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    var snapshotRoots: [URL] = []
    for case let entry as URL in enumerator where entry.lastPathComponent == "snapshots" && !isSymbolicLink(entry) {
      snapshotRoots.append(entry)
      enumerator.skipDescendants()
    }
    for snapshots in snapshotRoots {
      collectDirectAgedChildren(at: snapshots, cutoff: cutoff, dryRun: dryRun, report: &report)
    }
  }

  private func collectDirectAgedChildren(
    at root: URL,
    cutoff: Date,
    dryRun: Bool,
    report: inout RielaGarbageCollectionReport
  ) {
    guard let entries = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    for entry in entries where isOlderThanCutoff(entry, cutoff: cutoff) {
      guard !isSymbolicLink(entry) else { continue }
      remove(entry, dryRun: dryRun, report: &report)
    }
  }

  private func isOlderThanCutoff(_ url: URL, cutoff: Date) -> Bool {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
    guard let values = try? url.resourceValues(forKeys: keys),
          let modifiedAt = values.contentModificationDate,
          modifiedAt < cutoff else {
      return false
    }
    guard values.isDirectory == true,
          let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
          ) else {
      return true
    }
    for case let child as URL in enumerator {
      guard let childValues = try? child.resourceValues(forKeys: keys) else { return false }
      if childValues.isSymbolicLink == true {
        enumerator.skipDescendants()
        continue
      }
      guard let childModifiedAt = childValues.contentModificationDate, childModifiedAt < cutoff else {
        return false
      }
    }
    return true
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  @discardableResult
  private func remove(
    _ url: URL,
    dryRun: Bool,
    report: inout RielaGarbageCollectionReport,
    countsAsSession: Bool = false
  ) -> Bool {
    let bytes = allocatedSize(of: url)
    do {
      if !dryRun {
        try fileManager.removeItem(at: url)
      }
      report.removedEntryCount += 1
      report.reclaimedBytes += bytes
      if countsAsSession {
        report.removedSessionCount += 1
      }
      return true
    } catch {
      report.diagnostics.append("\(url.path): \(error.localizedDescription)")
      return false
    }
  }

  private func allocatedSize(of url: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey]
    if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
      return Int64(values.fileAllocatedSize ?? 0)
    }
    guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
      return 0
    }
    var total: Int64 = 0
    for case let child as URL in enumerator {
      if let values = try? child.resourceValues(forKeys: keys), values.isRegularFile == true {
        total += Int64(values.fileAllocatedSize ?? 0)
      }
    }
    return total
  }

  private static func dateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

private struct ProcessResult {
  var stdout: String
  var stderr: String
  var exitCode: Int32
}

private final class ProcessOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func append(_ value: Data) {
    lock.lock()
    data.append(value)
    lock.unlock()
  }

  var string: String {
    lock.lock()
    defer { lock.unlock() }
    return String(bytes: data, encoding: .utf8) ?? ""
  }
}

private enum HandoverCollectionError: Error, LocalizedError {
  case missingTaskDatabase
  case missingTaskTable
  case gitTimedOut

  var errorDescription: String? {
    switch self {
    case .missingTaskDatabase:
      "task database is missing"
    case .missingTaskTable:
      "task table is missing"
    case .gitTimedOut:
      "git command exceeded the 10 second timeout"
    }
  }
}
