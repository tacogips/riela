import Foundation
import RielaCore
import RielaEvents

extension DefaultEventLiveServer {
  /// Scans one file-change source, dispatches every stable observed change to
  /// its bound workflows, and returns the number of dispatched events.
  func pollFileChangeSource(
    source: FileChangeWatchSource,
    state: FileChangeWatchState,
    config: EventLiveConfig,
    eventRoot: URL,
    parsed: ParsedParityOptions
  ) async throws -> Int {
    let observed: [FileChangeObservedEvent]
    do {
      observed = try state.scanForStableChanges(source: source, now: Date())
    } catch {
      throw EventLiveSourcePollFailure(error)
    }
    var dispatched = 0
    for event in observed {
      guard source.changeTypes.contains(event.changeType) else {
        continue
      }
      let envelope = source.envelope(for: event)
      let triggerResult = await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(
        sources: config.sources,
        bindings: config.bindings,
        envelope: envelope
      ))
      guard triggerResult.accepted else {
        try? writeServeRecord(
          eventRoot: eventRoot,
          status: "ready",
          lastIgnoredReason: "file-change-trigger-not-accepted",
          lastTriggerCount: triggerResult.triggers.count,
          lastEnvelopeSourceId: envelope.sourceId,
          lastEnvelopeEventType: envelope.eventType.rawValue,
          lastDiagnosticCodes: triggerResult.diagnostics.map(\.code).joined(separator: ",")
        )
        continue
      }
      for trigger in triggerResult.triggers {
        guard let workflowName = trigger.workflowName else {
          continue
        }
        // A malformed dropped document must not kill the listener: the
        // failure is recorded on the serve record and watching continues.
        do {
          _ = try await workflowRunner.runWorkflow(EventWorkflowRunRequest(
            workflowName: workflowName,
            runtimeVariables: trigger.runtimeVariables,
            parsed: parsed
          ))
          try? writeServeRecord(
            eventRoot: eventRoot,
            status: "ready",
            pollingTarget: source.id,
            lastWorkflowName: workflowName,
            lastEnvelopeSourceId: envelope.sourceId,
            lastEnvelopeEventType: envelope.eventType.rawValue
          )
        } catch {
          try? writeServeRecord(
            eventRoot: eventRoot,
            status: "ready",
            detail: String(describing: error),
            lastIgnoredReason: "file-change-workflow-failed",
            lastWorkflowName: workflowName,
            lastEnvelopeSourceId: envelope.sourceId,
            lastEnvelopeEventType: envelope.eventType.rawValue
          )
        }
      }
      dispatched += 1
    }
    return dispatched
  }
}

extension EventLiveConfig {
  func fileChangeSources(eventRoot: URL) throws -> [FileChangeWatchSource] {
    let sourceDirectory = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let boundSourceIds = Set(bindings.filter(\.enabled).map(\.sourceId))
    let sourceIds = Set(sources.filter { source in
      source.enabled && source.kind == .fileChange && boundSourceIds.contains(source.id)
    }.map(\.id))
    guard FileManager.default.fileExists(atPath: sourceDirectory.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        let data = try Data(contentsOf: url)
        let contract = try JSONDecoder().decode(EventSourceContract.self, from: data)
        guard sourceIds.contains(contract.id) else {
          return nil
        }
        return try FileChangeWatchSource(
          file: try JSONDecoder().decode(FileChangeWatchSourceFile.self, from: data),
          configFileURL: url
        )
      }
  }
}

/// Raw file-change source JSON, decoded from the same file as
/// `EventSourceContract` (kind `file-change`).
struct FileChangeWatchSourceFile: Decodable {
  struct Filters: Decodable {
    var suffixes: [String]?
  }

  var id: String
  var directory: String? = nil
  var changeTypes: [String]? = nil
  var recursive: Bool? = nil
  var filters: Filters? = nil
  var stabilityWindowMs: Int? = nil
}

/// Validated file-change watch source: an operator-configured local directory
/// whose create/modify/delete events dispatch bound workflows.
struct FileChangeWatchSource: Sendable {
  static let defaultStabilityWindowMs = 1_000
  static let maximumStabilityWindowMs = 60_000
  static let allowedChangeTypes: Set<String> = ["create", "modify", "delete"]
  static let provider = "local-fs"

  var id: String
  /// The operator-authored directory value, kept verbatim for event payloads.
  var directoryLabel: String
  /// The resolved absolute directory that is actually scanned.
  var directoryURL: URL
  var changeTypes: Set<String>
  var recursive: Bool
  /// Lowercased suffix filters; empty means every regular file is eligible.
  var suffixes: [String]
  var stabilityWindowMs: Int

  init(file: FileChangeWatchSourceFile, configFileURL: URL) throws {
    self.id = file.id
    guard let directory = file.directory, !directory.isEmpty else {
      throw FileChangeSourceConfigError("file-change source '\(file.id)' requires a non-empty directory")
    }
    self.directoryLabel = directory
    let expanded = (directory as NSString).expandingTildeInPath
    let resolved = expanded.hasPrefix("/")
      ? URL(fileURLWithPath: expanded, isDirectory: true)
      : configFileURL.deletingLastPathComponent().appendingPathComponent(directory, isDirectory: true)
    self.directoryURL = resolved.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      throw FileChangeSourceConfigError(
        "file-change source '\(file.id)' directory does not exist or is not a directory: \(directoryURL.path)"
      )
    }
    guard FileManager.default.isReadableFile(atPath: directoryURL.path) else {
      throw FileChangeSourceConfigError("file-change source '\(file.id)' directory is not readable: \(directoryURL.path)")
    }
    if let changeTypes = file.changeTypes {
      guard !changeTypes.isEmpty else {
        throw FileChangeSourceConfigError("file-change source '\(file.id)' changeTypes must not be empty")
      }
      var seen = Set<String>()
      for changeType in changeTypes {
        guard Self.allowedChangeTypes.contains(changeType) else {
          throw FileChangeSourceConfigError(
            "file-change source '\(file.id)' changeTypes entry '\(changeType)' must be one of create, modify, delete"
          )
        }
        guard seen.insert(changeType).inserted else {
          throw FileChangeSourceConfigError("file-change source '\(file.id)' changeTypes entry '\(changeType)' is duplicated")
        }
      }
      self.changeTypes = seen
    } else {
      self.changeTypes = Self.allowedChangeTypes
    }
    self.recursive = file.recursive ?? false
    if let suffixes = file.filters?.suffixes {
      var normalized: [String] = []
      for suffix in suffixes {
        guard !suffix.isEmpty else {
          throw FileChangeSourceConfigError("file-change source '\(file.id)' filters.suffixes entries must be non-empty")
        }
        guard !suffix.contains("/"), !suffix.contains("\\") else {
          throw FileChangeSourceConfigError(
            "file-change source '\(file.id)' filters.suffixes entry '\(suffix)' must not contain path separators"
          )
        }
        let lowered = suffix.lowercased()
        guard !normalized.contains(lowered) else {
          throw FileChangeSourceConfigError("file-change source '\(file.id)' filters.suffixes entry '\(suffix)' is duplicated")
        }
        normalized.append(lowered)
      }
      self.suffixes = normalized
    } else {
      self.suffixes = []
    }
    let stabilityWindowMs = file.stabilityWindowMs ?? Self.defaultStabilityWindowMs
    guard stabilityWindowMs >= 0, stabilityWindowMs <= Self.maximumStabilityWindowMs else {
      throw FileChangeSourceConfigError(
        "file-change source '\(file.id)' stabilityWindowMs must be between 0 and \(Self.maximumStabilityWindowMs)"
      )
    }
    self.stabilityWindowMs = stabilityWindowMs
  }

  func matchesSuffixFilter(_ relativePath: String) -> Bool {
    guard !suffixes.isEmpty else {
      return true
    }
    let lowered = relativePath.lowercased()
    return suffixes.contains { lowered.hasSuffix($0) }
  }

  func envelope(for event: FileChangeObservedEvent) -> ExternalEventEnvelope {
    let mtimeEpochMs = event.stat.map { Int($0.mtime.timeIntervalSince1970 * 1_000) }
    var file: JSONObject = [
      "path": .string(event.relativePath),
      "name": .string(event.fileName),
      "absolutePath": .string(directoryURL.appendingPathComponent(event.relativePath).path)
    ]
    if !event.fileExtension.isEmpty {
      file["extension"] = .string(event.fileExtension)
    }
    if let stat = event.stat {
      file["size"] = .integer(stat.size)
      file["mtime"] = .string(fileChangeISOTimestamp(stat.mtime))
    }
    return ExternalEventEnvelope(
      sourceId: id,
      eventId: "\(id)-\(event.changeType)-\(event.relativePath)-\(Int(event.observedAt.timeIntervalSince1970 * 1_000))",
      provider: Self.provider,
      eventType: "file.change.\(event.eventTypeSuffix)",
      receivedAt: event.observedAt,
      dedupeKey: "\(id):\(event.changeType):\(event.relativePath):\(event.stat?.size ?? 0):\(mtimeEpochMs ?? 0)",
      input: [
        "change": .object(["type": .string(event.changeType)]),
        "file": .object(file),
        "watch": .object([
          "sourceId": .string(id),
          "directory": .string(directoryLabel),
          "resolvedDirectory": .string(directoryURL.path)
        ])
      ]
    )
  }
}

/// Validates every file-change source config under `<eventRoot>/sources` for
/// `events validate`, which cannot see the file-change-only fields through
/// `EventSourceContract` and needs each config file's location to resolve a
/// relative `directory`.
func fileChangeSourceDiagnostics(eventRoot: URL) -> [EventValidationDiagnostic] {
  let sourceDirectory = eventRoot.appendingPathComponent("sources", isDirectory: true)
  guard let sourceFiles = try? FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil) else {
    return []
  }
  var diagnostics: [EventValidationDiagnostic] = []
  for url in sourceFiles.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    guard let data = try? Data(contentsOf: url),
          let contract = try? JSONDecoder().decode(EventSourceContract.self, from: data),
          contract.kind == .fileChange else {
      continue
    }
    do {
      _ = try FileChangeWatchSource(
        file: try JSONDecoder().decode(FileChangeWatchSourceFile.self, from: data),
        configFileURL: url
      )
    } catch {
      diagnostics.append(EventValidationDiagnostic(
        code: "INVALID_EVENT_SOURCE",
        path: "sources/\(url.lastPathComponent)",
        message: String(describing: error)
      ))
    }
  }
  return diagnostics
}

struct FileChangeSourceConfigError: Error, CustomStringConvertible {
  var description: String

  init(_ description: String) {
    self.description = description
  }
}

/// One dispatched filesystem change. `stat` is absent when a deletion's
/// metadata was never observed before the file disappeared.
struct FileChangeObservedEvent: Equatable {
  var changeType: String
  var relativePath: String
  var stat: FileChangeFileStat?
  var observedAt: Date

  var fileName: String {
    relativePath.split(separator: "/").last.map(String.init) ?? relativePath
  }

  var fileExtension: String {
    let name = fileName
    guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else {
      return ""
    }
    return String(name[dotIndex...])
  }

  var eventTypeSuffix: String {
    switch changeType {
    case "create":
      "created"
    case "modify":
      "modified"
    default:
      "deleted"
    }
  }
}

struct FileChangeFileStat: Equatable {
  var size: Int64
  var mtime: Date
}

/// Per-source watch state for the polling scanner. Files present at listener
/// start are recorded without dispatching; create/modify events dispatch only
/// after the file's metadata has stayed unchanged for the source's stability
/// window, so noisy write bursts coalesce into one event.
final class FileChangeWatchState {
  private struct PendingChange {
    var changeType: String
    var stat: FileChangeFileStat
    var stableSince: Date
  }

  private var known: [String: FileChangeFileStat]
  private var pending: [String: PendingChange] = [:]

  init(source: FileChangeWatchSource) throws {
    self.known = try Self.snapshot(source: source)
  }

  func scanForStableChanges(source: FileChangeWatchSource, now: Date) throws -> [FileChangeObservedEvent] {
    let snapshot = try Self.snapshot(source: source)
    var events: [FileChangeObservedEvent] = []
    for (path, lastStat) in known.sorted(by: { $0.key < $1.key }) where snapshot[path] == nil {
      known.removeValue(forKey: path)
      pending.removeValue(forKey: path)
      events.append(FileChangeObservedEvent(
        changeType: "delete",
        relativePath: path,
        stat: lastStat,
        observedAt: now
      ))
    }
    // A file that appeared and vanished between scans was never announced, so
    // its pending create is dropped without a delete event.
    for path in pending.keys where snapshot[path] == nil {
      pending.removeValue(forKey: path)
    }
    let stabilityWindow = TimeInterval(source.stabilityWindowMs) / 1_000
    for (path, stat) in snapshot.sorted(by: { $0.key < $1.key }) {
      if var pendingChange = pending[path] {
        if pendingChange.stat != stat {
          pendingChange.stat = stat
          pendingChange.stableSince = now
          pending[path] = pendingChange
          continue
        }
        guard now.timeIntervalSince(pendingChange.stableSince) >= stabilityWindow else {
          continue
        }
        pending.removeValue(forKey: path)
        known[path] = stat
        events.append(FileChangeObservedEvent(
          changeType: pendingChange.changeType,
          relativePath: path,
          stat: stat,
          observedAt: now
        ))
        continue
      }
      let changeType: String
      if let knownStat = known[path] {
        guard knownStat != stat else {
          continue
        }
        changeType = "modify"
      } else {
        changeType = "create"
      }
      guard stabilityWindow > 0 else {
        known[path] = stat
        events.append(FileChangeObservedEvent(
          changeType: changeType,
          relativePath: path,
          stat: stat,
          observedAt: now
        ))
        continue
      }
      pending[path] = PendingChange(changeType: changeType, stat: stat, stableSince: now)
    }
    return events
  }

  private static func snapshot(source: FileChangeWatchSource) throws -> [String: FileChangeFileStat] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    let fileURLs: [URL]
    if source.recursive {
      guard let enumerator = FileManager.default.enumerator(
        at: source.directoryURL,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      ) else {
        throw FileChangeSourceConfigError("file-change source '\(source.id)' cannot enumerate \(source.directoryURL.path)")
      }
      fileURLs = enumerator.compactMap { $0 as? URL }
    } else {
      fileURLs = try FileManager.default.contentsOfDirectory(
        at: source.directoryURL,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    }
    let rootPath = source.directoryURL.standardizedFileURL.path
    var snapshot: [String: FileChangeFileStat] = [:]
    for url in fileURLs {
      guard let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            let mtime = values.contentModificationDate else {
        continue
      }
      let filePath = url.standardizedFileURL.path
      guard filePath.hasPrefix(rootPath + "/") else {
        continue
      }
      let relativePath = String(filePath.dropFirst(rootPath.count + 1))
      guard source.matchesSuffixFilter(relativePath) else {
        continue
      }
      snapshot[relativePath] = FileChangeFileStat(size: Int64(values.fileSize ?? 0), mtime: mtime)
    }
    return snapshot
  }
}

private func fileChangeISOTimestamp(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}
