import RielaGraphQL

public struct RielaServerConfiguration: Codable, Equatable, Sendable {
  public var host: String
  public var port: Int
  public var noteAPIEnabled: Bool
  public var noteRoot: String?
  public var noteS3Profiles: [RielaServerS3StorageProfileConfiguration]

  public init(
    host: String = "127.0.0.1",
    port: Int = 8787,
    noteAPIEnabled: Bool = false,
    noteRoot: String? = nil,
    noteS3Profiles: [RielaServerS3StorageProfileConfiguration] = []
  ) {
    self.host = host
    self.port = port
    self.noteAPIEnabled = noteAPIEnabled
    self.noteRoot = noteRoot
    self.noteS3Profiles = noteS3Profiles
  }

  enum CodingKeys: String, CodingKey {
    case host
    case port
    case noteAPIEnabled
    case noteRoot
    case noteS3Profiles
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
    port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8787
    noteAPIEnabled = try container.decodeIfPresent(Bool.self, forKey: .noteAPIEnabled) ?? false
    noteRoot = try container.decodeIfPresent(String.self, forKey: .noteRoot)
    noteS3Profiles = try container.decodeIfPresent(
      [RielaServerS3StorageProfileConfiguration].self,
      forKey: .noteS3Profiles
    ) ?? []
  }
}

public struct RielaServerS3StorageProfileConfiguration: Codable, Equatable, Sendable {
  public var name: String
  public var endpoint: String
  public var region: String
  public var bucket: String
  public var accessKeyIdEnv: String
  public var secretAccessKeyEnv: String
  public var sessionTokenEnv: String?
  public var keyPrefix: String

  public init(
    name: String,
    endpoint: String,
    region: String,
    bucket: String,
    accessKeyIdEnv: String = "AWS_ACCESS_KEY_ID",
    secretAccessKeyEnv: String = "AWS_SECRET_ACCESS_KEY",
    sessionTokenEnv: String? = nil,
    keyPrefix: String = ""
  ) {
    self.name = name
    self.endpoint = endpoint
    self.region = region
    self.bucket = bucket
    self.accessKeyIdEnv = accessKeyIdEnv
    self.secretAccessKeyEnv = secretAccessKeyEnv
    self.sessionTokenEnv = sessionTokenEnv
    self.keyPrefix = keyPrefix
  }
}
