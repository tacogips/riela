#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

/// Transaction phase updates are immutable generations. Each generation is
/// assembled privately and becomes canonical through one exclusive directory
/// rename, so a record can never be visible without its digest.
enum WorkflowTransactionGenerationStore {
  private static let payloadName = "record.json"
  private static let sidecarName = "record.sha256"

  static func write(
    _ record: WorkflowDirectoryTransactionRecord,
    logicalURL: URL,
    historyRoot: URL,
    betweenPayloadAndSidecar: () throws -> Void
  ) throws {
    let pinned = try WorkflowHistoryPinnedRoot(historyRoot)
    let generations = directory(for: logicalURL)
    try pinned.ensureDirectory(generations)
    let existing = try loadAll(logicalURL: logicalURL, historyRoot: historyRoot, pinned: pinned)
    if let latest = existing.last {
      try validateTransition(from: latest.record, to: record)
    }
    let sequence = (existing.last?.sequence ?? 0) + 1
    let name = String(format: "%08d-%@", sequence, record.phase.rawValue)
    let temporary = generations.appendingPathComponent(".tmp-\(UUID().uuidString.lowercased())", isDirectory: true)
    let destination = generations.appendingPathComponent(name, isDirectory: true)
    try pinned.withParent(of: temporary) { parent, leaf in
      guard mkdirat(parent, leaf, S_IRWXU) == 0 else {
        throw CLIUsageError("unable to create transaction generation")
      }
    }
    do {
      let bytes = try WorkflowHistoryCanonicalCoding.encode(record)
      try pinned.atomicWrite(bytes, to: temporary.appendingPathComponent(payloadName), overwrite: false)
      try betweenPayloadAndSidecar()
      try pinned.atomicWrite(
        Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8),
        to: temporary.appendingPathComponent(sidecarName),
        overwrite: false
      )
      try makeImmutable(temporary, pinned: pinned)
      _ = try readGeneration(
        temporary,
        expectedSequence: sequence,
        expectedPhase: record.phase,
        pinned: pinned,
        requireImmutable: true
      )
      try pinned.publishDirectory(temporary, to: destination)
    } catch {
      try? removePrivateGeneration(temporary, pinned: pinned)
      if existing.isEmpty { try? pinned.unlink(generations, directory: true) }
      throw error
    }
  }

  static func readLatest(
    logicalURL: URL,
    historyRoot: URL
  ) throws -> WorkflowDirectoryTransactionRecord? {
    let pinned = try WorkflowHistoryPinnedRoot(historyRoot, create: false)
    return try loadAll(logicalURL: logicalURL, historyRoot: historyRoot, pinned: pinned).last?.record
  }

  static func exists(logicalURL: URL, historyRoot: URL) throws -> Bool {
    let pinned = try WorkflowHistoryPinnedRoot(historyRoot, create: false)
    guard try pinned.entryType(directory(for: logicalURL)) != nil else { return false }
    return try !loadAll(logicalURL: logicalURL, historyRoot: historyRoot, pinned: pinned).isEmpty
  }

  private struct Generation {
    var sequence: Int
    var record: WorkflowDirectoryTransactionRecord
  }

  private static func loadAll(
    logicalURL: URL,
    historyRoot: URL,
    pinned: WorkflowHistoryPinnedRoot
  ) throws -> [Generation] {
    let generations = directory(for: logicalURL)
    guard let type = try pinned.entryType(generations) else { return [] }
    guard type == S_IFDIR else { throw CLIUsageError("transaction generations entry changed type") }
    var loaded: [Generation] = []
    for name in try pinned.names(in: generations) {
      if name.hasPrefix(".tmp-") {
        let temporary = generations.appendingPathComponent(name, isDirectory: true)
        try removePrivateGeneration(temporary, pinned: pinned)
        continue
      }
      let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
      guard parts.count == 2, let sequence = Int(parts[0]), sequence > 0,
            let phase = WorkflowDirectoryTransactionPhase(rawValue: parts[1]) else {
        throw CLIUsageError("transaction generation name is noncanonical")
      }
      loaded.append(try readGeneration(
        generations.appendingPathComponent(name, isDirectory: true),
        expectedSequence: sequence,
        expectedPhase: phase,
        pinned: pinned,
        requireImmutable: true
      ))
    }
    loaded.sort { $0.sequence < $1.sequence }
    let expectedSequences = loaded.isEmpty ? [] : Array(1...loaded.count)
    guard loaded.map(\.sequence) == expectedSequences else {
      throw CLIUsageError("transaction generations are missing or ambiguous")
    }
    for pair in zip(loaded, loaded.dropFirst()) {
      try validateTransition(from: pair.0.record, to: pair.1.record)
    }
    return loaded
  }

  private static func readGeneration(
    _ directory: URL,
    expectedSequence: Int,
    expectedPhase: WorkflowDirectoryTransactionPhase,
    pinned: WorkflowHistoryPinnedRoot,
    requireImmutable: Bool
  ) throws -> Generation {
    let names = try pinned.names(in: directory)
    guard names == [payloadName, sidecarName] else {
      throw CLIUsageError("transaction generation is incomplete or contains extra entries")
    }
    if requireImmutable { try pinned.requireDirectoryNonWritable(directory) }
    let bytes = try pinned.readRegular(
      directory.appendingPathComponent(payloadName),
      requireNonWritable: requireImmutable
    )
    let digest = try pinned.readRegular(
      directory.appendingPathComponent(sidecarName),
      requireNonWritable: requireImmutable
    )
    guard digest == Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8) else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    let record = try WorkflowHistoryCanonicalCoding.decode(WorkflowDirectoryTransactionRecord.self, from: bytes)
    guard record.phase == expectedPhase else {
      throw CLIUsageError("transaction generation phase does not match its canonical name")
    }
    return Generation(sequence: expectedSequence, record: record)
  }

  static func validateTransition(
    from previous: WorkflowDirectoryTransactionRecord,
    to next: WorkflowDirectoryTransactionRecord
  ) throws {
    var priorBase = previous
    var nextBase = next
    priorBase.phase = .preparing
    nextBase.phase = .preparing
    priorBase.verification = []
    nextBase.verification = []
    priorBase.diagnostics = []
    nextBase.diagnostics = []
    guard try WorkflowHistoryCanonicalCoding.encode(priorBase)
      == WorkflowHistoryCanonicalCoding.encode(nextBase) else {
      throw CLIUsageError("transaction generations disagree on immutable state")
    }
    try validateEvidenceTransition(from: previous, to: next)
    let allowed: [WorkflowDirectoryTransactionPhase: Set<WorkflowDirectoryTransactionPhase>] = [
      .preparing: [.preparing, .prepared, .failed],
      .prepared: [.prepared, .committing, .failed],
      .committing: [.committing, .liveMoved, .recovered],
      .liveMoved: [.liveMoved, .published, .recovered],
      .published: [.published, .committed],
      .committed: [.committed],
      .failed: [.failed],
      .recovered: [.recovered]
    ]
    guard allowed[previous.phase]?.contains(next.phase) == true else {
      throw CLIUsageError("transaction generation phase transition is noncanonical")
    }
  }

  private static func validateEvidenceTransition(
    from previous: WorkflowDirectoryTransactionRecord,
    to next: WorkflowDirectoryTransactionRecord
  ) throws {
    let previousVerification = Dictionary(uniqueKeysWithValues: previous.verification.map { ($0.id, $0) })
    let nextVerification = Dictionary(uniqueKeysWithValues: next.verification.map { ($0.id, $0) })
    guard previousVerification.allSatisfy({ nextVerification[$0.key] == $0.value }) else {
      throw CLIUsageError("transaction verification evidence was removed or rewritten")
    }
    let addedVerification = Set(nextVerification.keys).subtracting(previousVerification.keys)
    guard addedVerification.isEmpty || previous.phase == .preparing else {
      throw CLIUsageError("transaction verification evidence evolved after preflight")
    }
    guard Set(previous.diagnostics).isSubset(of: Set(next.diagnostics)) else {
      throw CLIUsageError("transaction diagnostics were removed or rewritten")
    }
  }

  private static func makeImmutable(
    _ directory: URL,
    pinned: WorkflowHistoryPinnedRoot
  ) throws {
    try pinned.setPermissions(
      S_IRUSR | S_IRGRP | S_IROTH,
      for: directory.appendingPathComponent(payloadName),
      expectedType: S_IFREG
    )
    try pinned.setPermissions(
      S_IRUSR | S_IRGRP | S_IROTH,
      for: directory.appendingPathComponent(sidecarName),
      expectedType: S_IFREG
    )
    try pinned.setPermissions(
      S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH,
      for: directory,
      expectedType: S_IFDIR
    )
  }

  private static func removePrivateGeneration(
    _ directory: URL,
    pinned: WorkflowHistoryPinnedRoot
  ) throws {
    try? pinned.setPermissions(S_IRWXU, for: directory, expectedType: S_IFDIR)
    for name in (try? pinned.names(in: directory)) ?? [] {
      try? pinned.setPermissions(S_IRUSR | S_IWUSR, for: directory.appendingPathComponent(name), expectedType: S_IFREG)
      try pinned.unlink(directory.appendingPathComponent(name))
    }
    try pinned.unlink(directory, directory: true)
  }

  private static func directory(for logicalURL: URL) -> URL {
    URL(fileURLWithPath: logicalURL.path + ".generations", isDirectory: true)
  }
}
