import Foundation

/// Nonblocking advisory locks owned for the complete native command lifetime.
public struct WorkflowCommandLocks: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, Sendable { case shared, exclusive }
  public struct Resource: Codable, Equatable, Sendable {
    public var name: String
    public var mode: Mode
    public init(name: String, mode: Mode = .exclusive) { self.name = name; self.mode = mode }
  }
  public var directoryEnvironment: String
  public var defaultDirectory: String?
  public var resources: [Resource]
  public enum BusyAction: String, Codable, Sendable { case run }
  public var onBusy: BusyAction?
  public var busyPayload: JSONObject?

  public init(directoryEnvironment: String, defaultDirectory: String? = nil, resources: [Resource], busyPayload: JSONObject? = nil, onBusy: BusyAction? = nil) {
    self.directoryEnvironment = directoryEnvironment; self.defaultDirectory = defaultDirectory
    self.resources = resources; self.busyPayload = busyPayload; self.onBusy = onBusy
  }

  public func validate() throws {
    guard !(onBusy != nil && busyPayload != nil), isValidEnvironmentVariableName(directoryEnvironment), (1...16).contains(resources.count),
      Set(resources.map(\.name)).count == resources.count,
      resources.allSatisfy({ $0.name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil }),
      defaultDirectory == nil || (!(defaultDirectory?.isEmpty ?? true) && (defaultDirectory?.utf8.count ?? 0) <= 4096),
      try JSONEncoder().encode(busyPayload).count <= 65_536 else {
      throw AdapterExecutionError(.invalidInput, "invalid command execution locks")
    }
  }
}
