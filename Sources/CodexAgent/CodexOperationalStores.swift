import Foundation
import AgentRuntimeKit

func codexOperationalNow() -> String {
  agentRuntimeISO8601Now()
}

public typealias CodexJSONStore<Value: Codable & Sendable> = AgentJSONFileStore<Value>

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
