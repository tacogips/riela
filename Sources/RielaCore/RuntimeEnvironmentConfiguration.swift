import Foundation

/// Persistable loader instructions only. Resolved values never belong here.
public struct RuntimeEnvironmentCommandSource: Codable, Equatable, Sendable {
  public enum Format: String, Codable, Sendable { case json, env0 }
  public var id: String
  public var names: [String]
  public var command: [String]
  public var format: Format
  public var timeoutSeconds: Double

  public init(id: String, names: [String], command: [String], format: Format = .json, timeoutSeconds: Double = 30) {
    self.id = id; self.names = names; self.command = command
    self.format = format; self.timeoutSeconds = timeoutSeconds
  }

  private enum CodingKeys: String, CodingKey { case id, names, command, format, timeoutSeconds }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(id: try values.decode(String.self, forKey: .id), names: try values.decode([String].self, forKey: .names),
      command: try values.decode([String].self, forKey: .command),
      format: try values.decodeIfPresent(Format.self, forKey: .format) ?? .json,
      timeoutSeconds: try values.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30)
  }
}

public struct RuntimeEnvironmentConfiguration: Codable, Equatable, Sendable {
  public var required: [String]
  public var sources: [RuntimeEnvironmentCommandSource]
  public init(required: [String] = [], sources: [RuntimeEnvironmentCommandSource] = []) {
    self.required = required; self.sources = sources
  }
  private enum CodingKeys: String, CodingKey { case required, sources }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(required: try values.decodeIfPresent([String].self, forKey: .required) ?? [],
      sources: try values.decodeIfPresent([RuntimeEnvironmentCommandSource].self, forKey: .sources) ?? [])
  }
}
