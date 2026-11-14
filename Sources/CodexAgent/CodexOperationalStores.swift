import Foundation

func codexOperationalNow() -> String {
  ISO8601DateFormatter().string(from: Date())
}

public struct CodexJSONStore<Value: Codable & Sendable>: Sendable {
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
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: [.atomic])
  }
}

public enum CodexSessionCommands {
  public static func list(codexHome: String? = nil) -> [CodexSession] {
    listSessions(options: CodexSessionListOptions(codexHome: codexHome)).sessions
  }

  public static func show(sessionId: String, codexHome: String? = nil) -> CodexSession? {
    findSession(id: sessionId, codexHome: codexHome)
  }

  public static func search(query: String, codexHome: String? = nil) throws -> CodexSessionsSearchResult {
    try CodexSessionIndex.searchSessions(query: query, options: CodexSessionListOptions(codexHome: codexHome))
  }

  public static func runArguments(prompt: String, options: CodexProcessOptions = CodexProcessOptions()) -> [String] {
    CodexProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options)
  }

  public static func resumeArguments(sessionId: String, prompt: String? = nil, options: CodexProcessOptions = CodexProcessOptions()) -> [String] {
    CodexProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options)
  }
}

public enum CodexOperationalError: Error, Equatable {
  case invalidBookmark
}
