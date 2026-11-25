import Foundation
import RielaSQLite

extension BotStore {
  public func providerInstances() throws -> [ProviderInstance] {
    let userInstances: [ProviderInstance] = try read { database in
      try database.query("SELECT json(record_json) AS record_json FROM provider_instances ORDER BY instance_id")
        .map { try Self.decodeProviderValue(ProviderInstance.self, json: $0["record_json"]) }
    } ?? []
    return NodeExecutionBackend.allCases.map(ProviderInstance.builtIn) + userInstances
  }

  public func providerInstance(id: String) throws -> ProviderInstance? {
    if let driver = NodeExecutionBackend(rawValue: id) { return .builtIn(driver) }
    return try read { try Self.loadProviderInstance(id: id, in: $0) } ?? nil
  }

  @discardableResult
  public func saveProviderInstance(_ instance: ProviderInstance) throws -> ProviderInstance {
    try instance.validate()
    return try write { database in
      if let previous = try Self.loadProviderInstance(id: instance.instanceId, in: database),
         previous.driver != instance.driver {
        try Self.deleteProviderReport(instanceId: instance.instanceId, in: database)
      }
      try database.execute(
        """
        INSERT INTO provider_instances (instance_id, record_json, updated_at) VALUES (?, jsonb(?), ?)
        ON CONFLICT(instance_id) DO UPDATE SET record_json = excluded.record_json, updated_at = excluded.updated_at
        """,
        bindings: [.text(instance.instanceId), .text(try Self.providerJSON(instance)), .text(RoutineStore.timestamp())]
      )
      return instance
    }
  }

  public func removeProviderInstance(id: String) throws {
    guard NodeExecutionBackend(rawValue: id) == nil else {
      throw BotStoreError(code: "provider_instance_reserved", message: "Built-in provider instances cannot be changed")
    }
    try write { database in
      guard try Self.loadProviderInstance(id: id, in: database) != nil else {
        throw Self.providerNotFound(id)
      }
      try Self.deleteProviderReport(instanceId: id, in: database)
      try database.execute("DELETE FROM provider_instances WHERE instance_id = ?", bindings: [.text(id)])
    }
  }

  public func providerReport(instanceId: String) throws -> ProviderReport? {
    try read { try Self.loadProviderReport(instanceId: instanceId, in: $0) } ?? nil
  }

  public func providerReports() throws -> [String: ProviderReport] {
    try read { database in
      let reports = try database.query("SELECT json(report_json) AS report_json FROM provider_reports")
        .map { try Self.decodeProviderValue(ProviderReport.self, json: $0["report_json"]) }
      return Dictionary(reports.map { ($0.instanceId, $0) }, uniquingKeysWith: { first, _ in first })
    } ?? [:]
  }

  public func mergeReportedConfig(
    instanceId: String, configOptions: [JSONObject] = [], reportedModel: String? = nil, at: Date
  ) throws {
    let config = ReportedProviderConfig(options: configOptions, reportedModel: reportedModel)
    guard !config.isEmpty else { return }
    try updateProviderReport(instanceId: instanceId, at: at) { report in
      config.apply(to: &report)
      report.observedAt = at
    }
  }

  public func recordProbe(instanceId: String, capability: BackendCapability, at: Date) throws {
    try updateProviderReport(instanceId: instanceId, at: at) { report in
      report.availability = capability.availability
      report.authentication = capability.authentication
      report.version = capability.version
      report.failures = capability.failures
      report.probedAt = at
    }
  }

  private func updateProviderReport(
    instanceId: String, at: Date, _ update: (inout ProviderReport) -> Void
  ) throws {
    try write { database in
      if NodeExecutionBackend(rawValue: instanceId) == nil,
         try Self.loadProviderInstance(id: instanceId, in: database) == nil {
        throw Self.providerNotFound(instanceId)
      }
      var report = try Self.loadProviderReport(instanceId: instanceId, in: database)
        ?? ProviderReport(instanceId: instanceId, observedAt: at)
      update(&report)
      try database.execute(
        """
        INSERT INTO provider_reports (instance_id, report_json, observed_at) VALUES (?, jsonb(?), ?)
        ON CONFLICT(instance_id) DO UPDATE SET report_json = excluded.report_json, observed_at = excluded.observed_at
        """,
        bindings: [
          .text(instanceId), .text(try Self.providerJSON(report)), .text(RoutineStore.timestamp(report.observedAt))
        ]
      )
    }
  }

  private static func loadProviderInstance(id: String, in database: SQLiteDatabase) throws -> ProviderInstance? {
    try database.query(
      "SELECT json(record_json) AS record_json FROM provider_instances WHERE instance_id = ?", bindings: [.text(id)]
    ).first.map { try decodeProviderValue(ProviderInstance.self, json: $0["record_json"]) }
  }

  private static func loadProviderReport(instanceId: String, in database: SQLiteDatabase) throws -> ProviderReport? {
    try database.query(
      "SELECT json(report_json) AS report_json FROM provider_reports WHERE instance_id = ?", bindings: [.text(instanceId)]
    ).first.map { try decodeProviderValue(ProviderReport.self, json: $0["report_json"]) }
  }

  private static func deleteProviderReport(instanceId: String, in database: SQLiteDatabase) throws {
    try database.execute("DELETE FROM provider_reports WHERE instance_id = ?", bindings: [.text(instanceId)])
  }

  private static func decodeProviderValue<Value: Decodable>(_ type: Value.Type, json: String?) throws -> Value {
    guard let json else {
      throw BotStoreError(code: "provider_instance_invalid", message: "Provider row is missing its JSON")
    }
    return try JSONDecoder().decode(type, from: Data(json.utf8))
  }

  private static func providerJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let json = String(bytes: try encoder.encode(value), encoding: .utf8) else {
      throw BotStoreError(code: "provider_instance_invalid", message: "Provider value could not be encoded as UTF-8 JSON")
    }
    return json
  }

  private static func providerNotFound(_ id: String) -> BotStoreError {
    BotStoreError(code: "provider_instance_not_found", message: "Provider instance '\(id)' was not found")
  }
}
