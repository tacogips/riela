import Foundation

public func agentRuntimeISO8601Now() -> String {
  ISO8601DateFormatter().string(from: Date())
}

public struct AgentJSONFileStore<Value: Codable & Sendable>: Sendable {
  public var url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load(default defaultValue: Value) throws -> Value {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return defaultValue
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Value.self, from: data)
  }

  public func save(_ value: Value) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: [.atomic])
  }
}
