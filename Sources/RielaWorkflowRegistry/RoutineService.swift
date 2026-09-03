import Foundation
import RielaCore
import RielaEvents

public struct RoutineServiceError: Error, Equatable, Sendable, CustomStringConvertible {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { message }
}

public struct RoutineCreateRequest: Codable, Equatable, Sendable {
  public var name: String
  /// Original natural-language instruction the routine was created from.
  public var instruction: String?
  /// What to do on every tick.
  public var task: String
  /// Six-field cron expression. Exactly one of `schedule` or `every`.
  public var schedule: String?
  /// Interval shorthand ("45s", "30m", "2h") expanded to a cron expression.
  public var every: String?
  public var timezone: String?
  /// Workflow run on every tick.
  public var workflowName: String
  public var completionCriteria: String?
  public var eventRoot: String?
  public var routineStoreRoot: String?
  public var deactivateWorkflowOnCompletion: Bool?
  public var origin: JSONObject?

  public init(
    name: String,
    instruction: String? = nil,
    task: String,
    schedule: String? = nil,
    every: String? = nil,
    timezone: String? = nil,
    workflowName: String,
    completionCriteria: String? = nil,
    eventRoot: String? = nil,
    routineStoreRoot: String? = nil,
    deactivateWorkflowOnCompletion: Bool? = nil,
    origin: JSONObject? = nil
  ) {
    self.name = name
    self.instruction = instruction
    self.task = task
    self.schedule = schedule
    self.every = every
    self.timezone = timezone
    self.workflowName = workflowName
    self.completionCriteria = completionCriteria
    self.eventRoot = eventRoot
    self.routineStoreRoot = routineStoreRoot
    self.deactivateWorkflowOnCompletion = deactivateWorkflowOnCompletion
    self.origin = origin
  }
}

public struct RoutineMutationResult: Codable, Equatable, Sendable {
  public var routine: RoutineRecord
  public var diagnostics: [String]

  public init(routine: RoutineRecord, diagnostics: [String] = []) {
    self.routine = routine
    self.diagnostics = diagnostics
  }
}

/// First-class routine management: SQLite record + cron event source/binding
/// files + (on completion) workflow deactivation, behind one service used by
/// the CLI, the GraphQL executor, and the builtin routine add-ons.
public struct RoutineService: Sendable {
  public var workingDirectory: String
  public var environment: [String: String]

  public init(
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.workingDirectory = workingDirectory
    self.environment = environment
  }

  public func store(routineStoreRoot: String? = nil) -> RoutineStore {
    RoutineStore(rootDirectory: RoutineStore.resolveRootDirectory(
      explicit: routineStoreRoot,
      workingDirectory: workingDirectory,
      environment: environment
    ))
  }

  public func defaultEventRoot() -> String {
    URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .appendingPathComponent(".riela/events", isDirectory: true)
      .path
  }

  // MARK: - Create

  public func create(_ request: RoutineCreateRequest) throws -> RoutineMutationResult {
    let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw RoutineServiceError("routine name is required")
    }
    let task = request.task.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !task.isEmpty else {
      throw RoutineServiceError("routine task is required")
    }
    let workflowName = request.workflowName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !workflowName.isEmpty else {
      throw RoutineServiceError("routine workflowName is required")
    }
    let schedule = try resolvedSchedule(schedule: request.schedule, every: request.every)
    if let timezone = request.timezone, TimeZone(identifier: timezone) == nil {
      throw RoutineServiceError("unknown timezone identifier '\(timezone)'")
    }

    let routineId = "routine-\(Self.slug(name))-\(Self.randomSuffix())"
    let sourceId = "\(routineId)-cron"
    let bindingId = "\(routineId)-binding"
    let eventRoot = resolvedEventRoot(request.eventRoot)
    let routineStore = store(routineStoreRoot: request.routineStoreRoot)
    let now = RoutineStore.timestamp()

    var record = RoutineRecord(
      routineId: routineId,
      name: name,
      instruction: request.instruction,
      task: task,
      schedule: schedule,
      timezone: request.timezone,
      workflowName: workflowName,
      completionCriteria: request.completionCriteria,
      status: .active,
      createdAt: now,
      updatedAt: now,
      eventRoot: eventRoot,
      sourceId: sourceId,
      bindingId: bindingId,
      deactivateWorkflowOnCompletion: request.deactivateWorkflowOnCompletion ?? false,
      origin: request.origin
    )

    let binding = eventBinding(for: record, storeRoot: routineStore.rootDirectory)
    let validationSource = EventSourceContract(id: sourceId, kind: .cron)
    let diagnostics = EventContractValidator.validate(sources: [validationSource], bindings: [binding])
    guard diagnostics.isEmpty else {
      throw RoutineServiceError(
        "routine event contract validation failed: "
          + diagnostics.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
      )
    }

    let sourceURL = sourceFileURL(for: record)
    let bindingURL = bindingFileURL(for: record)
    guard !FileManager.default.fileExists(atPath: sourceURL.path),
          !FileManager.default.fileExists(atPath: bindingURL.path) else {
      throw RoutineServiceError("routine event files already exist for generated id '\(routineId)'")
    }

    try routineStore.save(record)
    do {
      try writeSourceFile(for: record)
      try writeBindingFile(binding, record: record)
    } catch {
      for url in [sourceURL, bindingURL] where FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.removeItem(at: url)
      }
      _ = try? routineStore.delete(routineId: routineId)
      throw error
    }
    record = try routineStore.load(routineId: routineId) ?? record
    return RoutineMutationResult(
      routine: record,
      diagnostics: [
        "routineStore=\(routineStore.databasePath)",
        "source=\(sourceFileURL(for: record).path)",
        "binding=\(bindingFileURL(for: record).path)",
        "note=restart 'riela events serve' to pick up the new routine schedule"
      ]
    )
  }

  // MARK: - Queries

  public func list(
    filter: RoutineListFilter = RoutineListFilter(),
    routineStoreRoot: String? = nil
  ) throws -> [RoutineRecord] {
    if let limit = filter.limit, !(1...RoutineStore.maximumListLimit).contains(limit) {
      throw RoutineServiceError("routine list limit must be between 1 and \(RoutineStore.maximumListLimit)")
    }
    return try store(routineStoreRoot: routineStoreRoot).list(filter: filter)
  }

  public func get(routineId: String, routineStoreRoot: String? = nil) throws -> RoutineRecord {
    guard let record = try store(routineStoreRoot: routineStoreRoot).load(routineId: routineId) else {
      throw RoutineServiceError("routine '\(routineId)' was not found")
    }
    return record
  }

  // MARK: - Lifecycle

  /// Marks the routine completed, disables its event source/binding files, and
  /// (when the routine opted in) deactivates its workflow in the registry.
  public func complete(
    routineId: String,
    note: String? = nil,
    routineStoreRoot: String? = nil
  ) throws -> RoutineMutationResult {
    let routineStore = store(routineStoreRoot: routineStoreRoot)
    let record = try routineStore.update(routineId: routineId) { record in
      record.status = .completed
      record.completedAt = RoutineStore.timestamp()
      record.completionNote = note
    }
    var diagnostics = setEventFilesEnabled(false, record: record)
    if record.deactivateWorkflowOnCompletion {
      do {
        _ = try WorkflowRegistryService().setActivation(
          .deactivated,
          target: WorkflowRegistryTarget(workflowId: record.workflowName),
          workingDirectory: workingDirectory
        )
        diagnostics.append("workflow=\(record.workflowName) deactivated")
      } catch {
        diagnostics.append("workflow-deactivation-failed=\(error)")
      }
    }
    return RoutineMutationResult(routine: record, diagnostics: diagnostics)
  }

  /// Pauses (`disabled`) or resumes (`active`) a routine. Resuming a completed
  /// routine clears its completion stamp but does not re-activate a workflow
  /// that completion deactivated.
  public func setStatus(
    routineId: String,
    status: RoutineStatus,
    routineStoreRoot: String? = nil
  ) throws -> RoutineMutationResult {
    guard status != .completed else {
      throw RoutineServiceError("use complete to mark a routine completed")
    }
    let routineStore = store(routineStoreRoot: routineStoreRoot)
    let record = try routineStore.update(routineId: routineId) { record in
      record.status = status
      if status == .active {
        record.completedAt = nil
        record.completionNote = nil
      }
    }
    let diagnostics = setEventFilesEnabled(status == .active, record: record)
    return RoutineMutationResult(routine: record, diagnostics: diagnostics)
  }

  /// Deletes the routine record and removes its event source/binding files.
  public func delete(routineId: String, routineStoreRoot: String? = nil) throws -> RoutineMutationResult {
    let routineStore = store(routineStoreRoot: routineStoreRoot)
    guard let record = try routineStore.load(routineId: routineId) else {
      throw RoutineServiceError("routine '\(routineId)' was not found")
    }
    var diagnostics: [String] = []
    for url in [sourceFileURL(for: record), bindingFileURL(for: record)]
    where FileManager.default.fileExists(atPath: url.path) {
      do {
        try FileManager.default.removeItem(at: url)
        diagnostics.append("removed=\(url.path)")
      } catch {
        diagnostics.append("remove-failed=\(url.path): \(error)")
      }
    }
    _ = try routineStore.delete(routineId: routineId)
    return RoutineMutationResult(routine: record, diagnostics: diagnostics)
  }

  // MARK: - Event files

  public func sourceFileURL(for record: RoutineRecord) -> URL {
    URL(fileURLWithPath: record.eventRoot, isDirectory: true)
      .appendingPathComponent("sources", isDirectory: true)
      .appendingPathComponent("\(record.sourceId).json")
  }

  public func bindingFileURL(for record: RoutineRecord) -> URL {
    URL(fileURLWithPath: record.eventRoot, isDirectory: true)
      .appendingPathComponent("bindings", isDirectory: true)
      .appendingPathComponent("\(record.bindingId).json")
  }

  func eventBinding(for record: RoutineRecord, storeRoot: String) -> EventBindingContract {
    var template: JSONObject = [
      "routineId": .string(record.routineId),
      "routineName": .string(record.name),
      "task": .string(record.task),
      "scheduledAt": .string("{{event.input.scheduledAt}}"),
      "scheduledLocalTime": .string("{{event.input.scheduledLocalTime}}"),
      "firedAt": .string("{{event.input.firedAt}}"),
      "timezone": .string("{{event.input.timezone}}")
    ]
    if let completionCriteria = record.completionCriteria {
      template["completionCriteria"] = .string(completionCriteria)
    }
    return EventBindingContract(
      id: record.bindingId,
      enabled: record.status == .active,
      sourceId: record.sourceId,
      eventType: "cron.tick",
      workflowName: record.workflowName,
      inputMapping: EventInputMapping(
        mode: .template,
        template: .object(template),
        mirrorToHumanInput: false
      ),
      routineId: record.routineId,
      routineStoreRoot: storeRoot
    )
  }

  private func writeSourceFile(for record: RoutineRecord) throws {
    // EventSourceContract's canonical encoder does not carry cron
    // schedule/timezone (they are decoded by the serve loop from the raw
    // source JSON), so the source file is written as a plain JSON object.
    var source: JSONObject = [
      "id": .string(record.sourceId),
      "kind": .string("cron"),
      "schedule": .string(record.schedule),
      "enabled": .bool(true)
    ]
    if let timezone = record.timezone {
      source["timezone"] = .string(timezone)
    }
    try writeJSONFile(.object(source), to: sourceFileURL(for: record))
  }

  private func writeBindingFile(_ binding: EventBindingContract, record: RoutineRecord) throws {
    let data = try prettyJSONEncoder().encode(binding)
    let url = bindingFileURL(for: record)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
  }

  private func setEventFilesEnabled(_ enabled: Bool, record: RoutineRecord) -> [String] {
    var diagnostics: [String] = []
    for url in [sourceFileURL(for: record), bindingFileURL(for: record)] {
      do {
        let data = try Data(contentsOf: url)
        guard case var .object(object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
          diagnostics.append("event-file-not-object=\(url.path)")
          continue
        }
        object["enabled"] = .bool(enabled)
        try writeJSONFile(.object(object), to: url)
        diagnostics.append("\(enabled ? "enabled" : "disabled")=\(url.path)")
      } catch {
        diagnostics.append("event-file-update-failed=\(url.path): \(error)")
      }
    }
    return diagnostics
  }

  private func writeJSONFile(_ value: JSONValue, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try prettyJSONEncoder().encode(value).write(to: url, options: .atomic)
  }

  private func prettyJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  // MARK: - Helpers

  private func resolvedSchedule(schedule: String?, every: String?) throws -> String {
    let trimmedSchedule = schedule?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEvery = every?.trimmingCharacters(in: .whitespacesAndNewlines)
    let expression: String
    switch (trimmedSchedule?.isEmpty == false, trimmedEvery?.isEmpty == false) {
    case (true, true):
      throw RoutineServiceError("provide exactly one of schedule or every")
    case (true, false):
      expression = trimmedSchedule ?? ""
    case (false, true):
      expression = try CronSchedule.expression(every: trimmedEvery ?? "")
    case (false, false):
      throw RoutineServiceError("provide a six-field cron schedule or an every-interval like 30m")
    }
    do {
      _ = try CronSchedule.parse(expression)
    } catch {
      throw RoutineServiceError("invalid cron schedule '\(expression)': \(error)")
    }
    return expression
  }

  private func resolvedEventRoot(_ explicit: String?) -> String {
    guard let explicit, !explicit.isEmpty else {
      return defaultEventRoot()
    }
    let expanded = (explicit as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return expanded
    }
    return URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .appendingPathComponent(expanded, isDirectory: true)
      .standardizedFileURL
      .path
  }

  static func slug(_ name: String) -> String {
    var slug = ""
    for scalar in name.lowercased().unicodeScalars {
      if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
        slug.unicodeScalars.append(scalar)
      } else if !slug.hasSuffix("-") && !slug.isEmpty {
        slug.append("-")
      }
    }
    while slug.hasSuffix("-") {
      slug.removeLast()
    }
    if slug.count > 32 {
      slug = String(slug.prefix(32))
    }
    return slug.isEmpty ? "routine" : slug
  }

  static func randomSuffix() -> String {
    String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
  }
}
