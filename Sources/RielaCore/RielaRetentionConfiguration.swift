import CoreFoundation
import Foundation

public enum RielaRetentionTargetKind: String, Codable, Equatable, Sendable {
  case user
  case project
  case explicit
}

public enum RielaRetentionCategoryState: String, Codable, Equatable, Sendable {
  case keepForever
  case active
  case notConfigured
}

public struct RielaRetentionCategory: Codable, Equatable, Sendable {
  public var keepForever: Bool
  public var maxAgeDays: Int?
  public var maxTotalBytes: Int64?
  public var keepWorkflowIds: [String]

  public init(
    keepForever: Bool = false,
    maxAgeDays: Int? = nil,
    maxTotalBytes: Int64? = nil,
    keepWorkflowIds: [String] = []
  ) {
    self.keepForever = keepForever
    self.maxAgeDays = maxAgeDays
    self.maxTotalBytes = maxTotalBytes
    self.keepWorkflowIds = keepWorkflowIds
  }

  public var state: RielaRetentionCategoryState {
    if keepForever { return .keepForever }
    if maxAgeDays != nil || maxTotalBytes != nil { return .active }
    return .notConfigured
  }
}

/// Workflow definition history retention. An unset value selects the shared
/// engine's default window of ten generations.
public struct RielaDefinitionRetention: Codable, Equatable, Sendable {
  public var keepVersions: Int?

  public init(keepVersions: Int? = nil) {
    self.keepVersions = keepVersions
  }
}

public struct RielaRetentionPolicy: Codable, Equatable, Sendable {
  public var automatic: Bool
  public var minIntervalMinutes: Int
  public var results: RielaRetentionCategory
  public var messages: RielaRetentionCategory
  public var logs: RielaRetentionCategory
  public var definitions: RielaDefinitionRetention

  public init(
    automatic: Bool = true,
    minIntervalMinutes: Int = 60,
    results: RielaRetentionCategory = RielaRetentionCategory(),
    messages: RielaRetentionCategory = RielaRetentionCategory(),
    logs: RielaRetentionCategory = RielaRetentionCategory(),
    definitions: RielaDefinitionRetention = RielaDefinitionRetention()
  ) {
    self.automatic = automatic
    self.minIntervalMinutes = minIntervalMinutes
    self.results = results
    self.messages = messages
    self.logs = logs
    self.definitions = definitions
  }
}

public enum RielaRetentionPolicySource: String, Codable, Equatable, Sendable {
  case configured, builtInDefault = "default", override
}

public struct RielaRetentionPolicySources: Codable, Equatable, Sendable {
  public var results: RielaRetentionPolicySource
  public var messages: RielaRetentionPolicySource
  public var logs: RielaRetentionPolicySource

  public init(results: RielaRetentionPolicySource, messages: RielaRetentionPolicySource, logs: RielaRetentionPolicySource) {
    self.results = results
    self.messages = messages
    self.logs = logs
  }
}

public struct RielaEffectiveRetentionPolicy: Equatable, Sendable {
  public var policy: RielaRetentionPolicy
  public var sources: RielaRetentionPolicySources
}

extension RielaRetentionPolicy {
  public static let builtInDefault = RielaRetentionPolicy(
    results: RielaRetentionCategory(maxAgeDays: 30), logs: RielaRetentionCategory(maxAgeDays: 30))
}

public struct RielaRetentionConfiguration: Equatable, Sendable {
  public var userPolicy: RielaRetentionPolicy?
  public var projectPolicy: RielaRetentionPolicy?
  public var automaticOverride: Bool?

  public init(userPolicy: RielaRetentionPolicy? = nil, projectPolicy: RielaRetentionPolicy? = nil, automaticOverride: Bool? = nil) {
    self.userPolicy = userPolicy
    self.projectPolicy = projectPolicy
    self.automaticOverride = automaticOverride
  }

  public func policy(for kind: RielaRetentionTargetKind) -> RielaRetentionPolicy? {
    switch kind {
    case .user, .explicit:
      userPolicy
    case .project:
      projectPolicy
    }
  }

  public func effectivePolicy(for kind: RielaRetentionTargetKind) -> RielaEffectiveRetentionPolicy {
    var policy = policy(for: kind) ?? .builtInDefault
    var sources = RielaRetentionPolicySources(results: .configured, messages: .configured, logs: .configured)
    if self.policy(for: kind) == nil {
      sources = RielaRetentionPolicySources(results: .builtInDefault, messages: .builtInDefault, logs: .builtInDefault)
    } else {
      if policy.results.state == .notConfigured {
        policy.results.maxAgeDays = 30
        sources.results = .builtInDefault
      }
      if policy.messages.state == .notConfigured { sources.messages = .builtInDefault }
      if policy.logs.state == .notConfigured {
        policy.logs.maxAgeDays = 30
        sources.logs = .builtInDefault
      }
    }
    if let automaticOverride { policy.automatic = automaticOverride }
    return RielaEffectiveRetentionPolicy(policy: policy, sources: sources)
  }

  public static func load(homeDirectory: URL, projectDirectory: URL?,
                          environment: [String: String],
                          fileManager: FileManager = .default
  ) throws -> RielaRetentionConfiguration {
    let userURL = configurationURL(for: homeDirectory)
    let userObject = try loadConfigurationObject(at: userURL, fileManager: fileManager)
    try validateDefinitionRetentionAlias(in: userObject, source: userURL.path)
    let projectIsHome = projectDirectory?.standardizedFileURL.path == homeDirectory.standardizedFileURL.path
    let projectURL = projectDirectory.map(configurationURL(for:))
    let projectObject: [String: Any]?
    if projectIsHome {
      projectObject = userObject
    } else if let projectURL {
      projectObject = try loadConfigurationObject(at: projectURL, fileManager: fileManager)
    } else {
      projectObject = nil
    }
    if let projectURL, !projectIsHome { try validateDefinitionRetentionAlias(in: projectObject, source: projectURL.path) }

    if let oldValue = environment["RIELA_GC_RETENTION_DAYS"], !oldValue.isEmpty {
      throw RielaRetentionConfigurationError.removedKey("RIELA_GC_RETENTION_DAYS")
    }

    var userPolicy: RielaRetentionPolicy?
    var projectPolicy: RielaRetentionPolicy?
    if let rawEnvironment = environment["RIELA_RETENTION"], !rawEnvironment.isEmpty {
      let object = try parseJSONObject(Data(rawEnvironment.utf8), path: "RIELA_RETENTION")
      userPolicy = try parsePolicy(object, path: "retention")
      projectPolicy = userPolicy
    } else {
      userPolicy = try parsePolicyIfPresent(userObject, path: "retention")
      if let projectObject {
        projectPolicy = try parsePolicyIfPresent(projectObject, path: "retention") ?? userPolicy
      } else {
        projectPolicy = userPolicy
      }
    }

    var automaticOverride: Bool?
    if let rawAutomatic = environment["RIELA_RETENTION_AUTOMATIC"] {
      let automatic: Bool
      switch rawAutomatic.lowercased() {
      case "true", "1": automatic = true
      case "false", "0": automatic = false
      default:
        throw RielaRetentionConfigurationError.invalid(
          path: "RIELA_RETENTION_AUTOMATIC",
          reason: "expected true, false, 1, or 0"
        )
      }
      automaticOverride = automatic
      userPolicy?.automatic = automatic
      projectPolicy?.automatic = automatic
    }
    return RielaRetentionConfiguration(userPolicy: userPolicy, projectPolicy: projectPolicy, automaticOverride: automaticOverride)
  }
}

public enum RielaByteSize {
  private static let maximum = Int64(1) << 50

  public static func parse(_ text: String) throws -> Int64 {
    let pattern = #"^([0-9]+) ?(B|KB|MB|GB|TB|KiB|MiB|GiB|TiB)$"#
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let numberRange = Range(match.range(at: 1), in: text),
          let unitRange = Range(match.range(at: 2), in: text),
          let value = Int64(text[numberRange]) else {
      throw RielaRetentionConfigurationError.invalid(path: "maxTotalBytes", reason: "invalid byte size '\(text)'")
    }
    let unit = text[unitRange].uppercased()
    let multiplier: Int64
    switch unit {
    case "B": multiplier = 1
    case "KB": multiplier = 1_000
    case "MB": multiplier = 1_000_000
    case "GB": multiplier = 1_000_000_000
    case "TB": multiplier = 1_000_000_000_000
    case "KIB": multiplier = 1_024
    case "MIB": multiplier = 1_048_576
    case "GIB": multiplier = 1_073_741_824
    case "TIB": multiplier = 1_099_511_627_776
    default:
      throw RielaRetentionConfigurationError.invalid(path: "maxTotalBytes", reason: "unsupported byte unit")
    }
    let (bytes, overflow) = value.multipliedReportingOverflow(by: multiplier)
    guard !overflow, (1...maximum).contains(bytes) else {
      throw RielaRetentionConfigurationError.invalid(path: "maxTotalBytes", reason: "byte size must be between 1 and 2^50")
    }
    return bytes
  }
}

public enum RielaRetentionConfigurationError: Error, Equatable, LocalizedError {
  case removedKey(String)
  case invalid(path: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .removedKey:
      "gc.retentionDays was removed; configure \"retention\" (see riela gc --help)"
    case let .invalid(path, reason):
      "Invalid retention configuration at \(path): \(reason)"
    }
  }
}

private func configurationURL(for directory: URL) -> URL {
  directory.appendingPathComponent(".riela", isDirectory: true).appendingPathComponent("config.json")
}

private func loadConfigurationObject(at url: URL, fileManager: FileManager) throws -> [String: Any]? {
  guard fileManager.fileExists(atPath: url.path) else { return nil }
  let object = try parseJSONObject(Data(contentsOf: url), path: url.path)
  if object.keys.contains("gc") { throw RielaRetentionConfigurationError.removedKey("gc") }
  return object
}

private func parseJSONObject(_ data: Data, path: String) throws -> [String: Any] {
  do {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RielaRetentionConfigurationError.invalid(path: path, reason: "expected a JSON object")
    }
    return object
  } catch let error as RielaRetentionConfigurationError {
    throw error
  } catch {
    throw RielaRetentionConfigurationError.invalid(path: path, reason: error.localizedDescription)
  }
}

private func parsePolicyIfPresent(_ object: [String: Any]?, path: String) throws -> RielaRetentionPolicy? {
  guard let object, let rawRetention = object["retention"] else { return nil }
  guard let retention = rawRetention as? [String: Any] else {
    throw RielaRetentionConfigurationError.invalid(path: path, reason: "expected an object")
  }
  return try parsePolicy(retention, path: path)
}

private func validateDefinitionRetentionAlias(in root: [String: Any]?, source: String) throws {
  guard let root else { return }
  let history = (root["workflowDefinitions"] as? [String: Any])?["historyRetention"]
  let definitions = ((root["retention"] as? [String: Any])?["definitions"] as? [String: Any])?["keepVersions"]
  let historyValue = try history.map { try integer($0, path: "workflowDefinitions.historyRetention") } ?? nil
  let definitionsValue = try definitions.map { try integer($0, path: "retention.definitions.keepVersions") } ?? nil
  guard let historyValue, let definitionsValue else { return }
  if historyValue != definitionsValue {
    throw RielaRetentionConfigurationError.invalid(
      path: source,
      reason: "workflowDefinitions.historyRetention and retention.definitions.keepVersions must match"
    )
  }
}

private func parsePolicy(_ object: [String: Any], path: String) throws -> RielaRetentionPolicy {
  try validateKeys(object, allowed: ["automatic", "minIntervalMinutes", "results", "messages", "logs", "definitions"], path: path)
  let automatic = try boolean(object["automatic"], path: "\(path).automatic") ?? true
  let interval = try integer(object["minIntervalMinutes"], path: "\(path).minIntervalMinutes") ?? 60
  guard (1...10_080).contains(interval) else {
    throw RielaRetentionConfigurationError.invalid(path: "\(path).minIntervalMinutes", reason: "must be between 1 and 10080")
  }
  return RielaRetentionPolicy(
    automatic: automatic,
    minIntervalMinutes: interval,
    results: try parseCategory(object["results"], name: "results", path: path),
    messages: try parseCategory(object["messages"], name: "messages", path: path),
    logs: try parseCategory(object["logs"], name: "logs", path: path),
    definitions: try parseDefinitions(object["definitions"], path: "\(path).definitions")
  )
}

private func parseDefinitions(_ raw: Any?, path: String) throws -> RielaDefinitionRetention {
  guard let raw else { return RielaDefinitionRetention() }
  guard let object = raw as? [String: Any] else {
    throw RielaRetentionConfigurationError.invalid(path: path, reason: "expected an object")
  }
  try validateKeys(object, allowed: ["keepVersions"], path: path)
  let keepVersions = try integer(object["keepVersions"], path: "\(path).keepVersions")
  guard keepVersions.map({ (0...10_000).contains($0) }) ?? true else {
    throw RielaRetentionConfigurationError.invalid(path: "\(path).keepVersions", reason: "must be between 0 and 10000")
  }
  return RielaDefinitionRetention(keepVersions: keepVersions)
}

private func parseCategory(_ raw: Any?, name: String, path: String) throws -> RielaRetentionCategory {
  guard let raw else { return RielaRetentionCategory() }
  let categoryPath = "\(path).\(name)"
  guard let object = raw as? [String: Any] else {
    throw RielaRetentionConfigurationError.invalid(path: categoryPath, reason: "expected an object")
  }
  var allowed: Set<String> = ["keepForever", "maxAgeDays", "maxTotalBytes"]
  if name == "results" { allowed.insert("keepWorkflowIds") }
  try validateKeys(object, allowed: allowed, path: categoryPath)
  let keepForever = try boolean(object["keepForever"], path: "\(categoryPath).keepForever") ?? false
  let maxAgeDays = try integer(object["maxAgeDays"], path: "\(categoryPath).maxAgeDays")
  guard maxAgeDays.map({ (1...36_500).contains($0) }) ?? true else {
    throw RielaRetentionConfigurationError.invalid(path: "\(categoryPath).maxAgeDays", reason: "must be between 1 and 36500")
  }
  let maxTotalBytes: Int64?
  if let rawBytes = object["maxTotalBytes"] {
    if let text = rawBytes as? String {
      maxTotalBytes = try RielaByteSize.parse(text)
    } else {
      maxTotalBytes = try integer64(rawBytes, path: "\(categoryPath).maxTotalBytes")
      guard let maxTotalBytes, (1...(Int64(1) << 50)).contains(maxTotalBytes) else {
        throw RielaRetentionConfigurationError.invalid(path: "\(categoryPath).maxTotalBytes", reason: "must be between 1 and 2^50")
      }
    }
  } else {
    maxTotalBytes = nil
  }
  if keepForever && (maxAgeDays != nil || maxTotalBytes != nil) {
    throw RielaRetentionConfigurationError.invalid(path: categoryPath, reason: "keepForever cannot be combined with limits")
  }
  let workflowIds: [String]
  if let rawIds = object["keepWorkflowIds"] {
    guard let ids = rawIds as? [String] else {
      throw RielaRetentionConfigurationError.invalid(path: "\(categoryPath).keepWorkflowIds", reason: "expected an array of strings")
    }
    for id in ids where id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || id.utf8.count > 512 {
      throw RielaRetentionConfigurationError.invalid(path: "\(categoryPath).keepWorkflowIds", reason: "values must be non-empty and at most 512 UTF-8 bytes")
    }
    workflowIds = ids
  } else {
    workflowIds = []
  }
  return RielaRetentionCategory(
    keepForever: keepForever,
    maxAgeDays: maxAgeDays,
    maxTotalBytes: maxTotalBytes,
    keepWorkflowIds: workflowIds
  )
}

private func validateKeys(_ object: [String: Any], allowed: Set<String>, path: String) throws {
  if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
    throw RielaRetentionConfigurationError.invalid(path: "\(path).\(unknown)", reason: "unknown key")
  }
}

private func boolean(_ raw: Any?, path: String) throws -> Bool? {
  guard let raw else { return nil }
  guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
    throw RielaRetentionConfigurationError.invalid(path: path, reason: "expected a boolean")
  }
  return number.boolValue
}

private func integer(_ raw: Any?, path: String) throws -> Int? {
  guard let raw else { return nil }
  guard let value = try integer64(raw, path: path), let result = Int(exactly: value) else {
    throw RielaRetentionConfigurationError.invalid(path: path, reason: "expected an integer")
  }
  return result
}

private func integer64(_ raw: Any?, path: String) throws -> Int64? {
  guard let raw else { return nil }
  guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
    throw RielaRetentionConfigurationError.invalid(path: path, reason: "expected an integer")
  }
  let value = number.doubleValue
  guard value.isFinite, value.rounded(.towardZero) == value,
        value >= Double(Int64.min), value < Double(Int64.max),
        let result = Int64(number.stringValue) else {
    throw RielaRetentionConfigurationError.invalid(path: path, reason: "expected an integer")
  }
  return result
}
