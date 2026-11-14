import Foundation
import RielaSQLite

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

  public init(
    enabled: Bool,
    dryRun: Bool,
    retentionDays: Int?,
    cutoff: Date?,
    roots: [String],
    removedSessionCount: Int = 0,
    removedEntryCount: Int = 0,
    reclaimedBytes: Int64 = 0,
    diagnostics: [String] = []
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
    for root in roots {
      collect(root: root, cutoff: cutoff, dryRun: dryRun, report: &report)
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
    var expiredSessionIds = Set<String>()
    if fileManager.fileExists(atPath: database.path) {
      do {
        let databaseResult = try collectDatabase(
          at: database,
          cutoff: cutoff,
          dryRun: dryRun
        )
        expiredSessionIds.formUnion(databaseResult.sessionIds)
        report.removedSessionCount += databaseResult.sessionIds.count
        report.removedEntryCount += databaseResult.rowCount
      } catch {
        report.diagnostics.append("\(database.path): \(error.localizedDescription)")
      }
    }
    collectLegacySessions(
      at: sessions,
      cutoff: cutoff,
      knownExpiredSessionIds: expiredSessionIds,
      dryRun: dryRun,
      report: &report
    )
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

  private func collectLegacySessions(
    at sessions: URL,
    cutoff: Date,
    knownExpiredSessionIds: Set<String>,
    dryRun: Bool,
    report: inout RielaGarbageCollectionReport
  ) {
    guard let entries = try? fileManager.contentsOfDirectory(
      at: sessions,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    for entry in entries where entry.pathExtension == "json" {
      guard !isSymbolicLink(entry) else { continue }
      guard isOlderThanCutoff(entry, cutoff: cutoff) else { continue }
      remove(entry, dryRun: dryRun, report: &report, countsAsSession: true)
    }
    let runtimeRecords = sessions.appendingPathComponent("runtime-records", isDirectory: true)
    guard let runtimeEntries = try? fileManager.contentsOfDirectory(
      at: runtimeRecords,
      includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    for entry in runtimeEntries where entry.pathExtension != "sqlite" && !entry.lastPathComponent.contains(".sqlite-") {
      guard !isSymbolicLink(entry) else { continue }
      guard knownExpiredSessionIds.contains(entry.lastPathComponent) || isOlderThanCutoff(entry, cutoff: cutoff) else {
        continue
      }
      remove(entry, dryRun: dryRun, report: &report)
    }
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

  private func remove(
    _ url: URL,
    dryRun: Bool,
    report: inout RielaGarbageCollectionReport,
    countsAsSession: Bool = false
  ) {
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
    } catch {
      report.diagnostics.append("\(url.path): \(error.localizedDescription)")
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
