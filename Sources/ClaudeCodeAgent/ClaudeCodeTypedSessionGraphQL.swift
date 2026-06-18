import Foundation
import RielaCore

func isPingDocument(_ document: String) -> Bool {
  let stripped = document
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return stripped == "query { ping }" || stripped == "{ ping }"
}

func executeTypedSessionGraphQLDocument(_ document: String, variables: JSONObject, context: ClaudeCodeAgentCompatibilityContext) -> ClaudeCodeGraphQLCommandExecutor.Result? {
  guard document.contains("sessions") || document.contains("session(") || document.contains("searchSessions") else {
    return nil
  }
  guard !document.contains("command(") else {
    return nil
  }
  let explicitConfigDir = claudeCodeStringValue(variables["configDir"]) ?? context.configDir
  let configDir = explicitConfigDir ?? defaultClaudeCodeAgentConfigDir()
  let claudeCodeHome = claudeCodeStringValue(variables["claudeCodeHome"]) ?? context.claudeCodeHome
  let authToken = claudeCodeStringValue(variables["authToken"]) ?? claudeCodeStringValue(variables["token"]) ?? context.authToken
  do {
    if let authError = try authorizationError(commandName: "session.list", rawToken: authToken, configDir: configDir) {
      return ClaudeCodeGraphQLCommandExecutor.Result(errors: [authError])
    }
    if document.contains("searchSessions") {
      let args = graphQLArguments(field: "searchSessions", document: document, variables: variables)
      let query = claudeCodeStringValue(args["query"]) ?? ""
      let listOptions = ClaudeCodeSessionListOptions(
        claudeCodeHome: claudeCodeHome,
        source: claudeCodeStringValue(args["source"]).flatMap { source in
          switch source.lowercased() {
          case "uuid", "cli":
            return .cli
          case "vscode":
            return .vscode
          case "exec":
            return .exec
          default:
            return ClaudeCodeSessionSource(rawValue: source.lowercased())
          }
        },
        cwd: claudeCodeStringValue(args["projectPath"]) ?? claudeCodeStringValue(args["cwd"]),
        branch: claudeCodeStringValue(args["branch"]),
        limit: Int.max,
        offset: 0,
        sortBy: "createdAt",
        sortOrder: "desc"
      )
      let searchOptions = ClaudeCodeSessionTranscriptSearchOptions(
        caseSensitive: claudeCodeBoolValue(args["caseSensitive"]) ?? false,
        role: claudeCodeStringValue(args["role"])?.lowercased() ?? "both",
        maxBytes: claudeCodeIntValue(args["maxBytes"]),
        maxEvents: nil,
        maxSessions: claudeCodeIntValue(args["maxSessions"]),
        timeoutMs: claudeCodeIntValue(args["timeoutMs"]),
        limit: claudeCodeIntValue(args["limit"]) ?? 50,
        offset: claudeCodeIntValue(args["offset"]) ?? 0
      )
      let result = try ClaudeCodeSessionIndex.searchSessions(query: query, options: listOptions, searchOptions: searchOptions)
      return ClaudeCodeGraphQLCommandExecutor.Result(data: .object([
        "searchSessions": .object([
          "sessionIds": .array(result.sessionIds.map(JSONValue.string)),
          "total": .number(Double(result.total)),
          "offset": .number(Double(result.offset)),
          "limit": .number(Double(result.limit)),
          "scannedSessions": .number(Double(result.scannedSessions)),
          "scannedBytes": .number(Double(result.scannedBytes)),
          "scannedEvents": .number(Double(result.scannedEvents)),
          "truncated": .bool(result.truncated),
          "timedOut": .bool(result.timedOut)
        ])
      ]))
    }
    if document.contains("session(") {
      let args = graphQLArguments(field: "session", document: document, variables: variables)
      guard let id = claudeCodeStringValue(args["id"]), let session = ClaudeCodeSessionIndex.findSession(id: id, claudeCodeHome: claudeCodeHome) else {
        return ClaudeCodeGraphQLCommandExecutor.Result(data: .object(["session": .null]))
      }
      var sessionObject = typedSessionJSON(session)
      if document.contains("history") {
        sessionObject["history"] = typedSessionHistoryJSON(session: session, args: graphQLArguments(field: "history", document: document, variables: variables))
      }
      if document.contains("grep") {
        let grepArgs = graphQLArguments(field: "grep", document: document, variables: variables)
        let query = claudeCodeStringValue(grepArgs["query"]) ?? ""
        let searchOptions = ClaudeCodeSessionTranscriptSearchOptions(
          caseSensitive: claudeCodeBoolValue(grepArgs["caseSensitive"]) ?? false,
          role: claudeCodeStringValue(grepArgs["role"])?.lowercased() ?? "both",
          maxBytes: claudeCodeIntValue(grepArgs["maxBytes"]),
          timeoutMs: claudeCodeIntValue(grepArgs["timeoutMs"]),
          limit: claudeCodeIntValue(grepArgs["maxMatches"]) ?? 50
        )
        let result = try ClaudeCodeSessionIndex.searchSessionTranscriptDetailed(session: session, query: query, options: searchOptions)
        sessionObject["grep"] = .object([
          "sessionId": .string(session.id),
          "matched": .bool(result.matched),
          "matchCount": .number(Double(result.matchCount)),
          "scannedBytes": .number(Double(result.scannedBytes)),
          "scannedLines": .number(Double(result.scannedEvents)),
          "scannedEvents": .number(Double(result.scannedEvents)),
          "truncated": .bool(result.truncated),
          "timedOut": .bool(result.timedOut)
        ])
      }
      return ClaudeCodeGraphQLCommandExecutor.Result(data: .object(["session": .object(sessionObject)]))
    }
    if document.contains("sessions") {
      let args = graphQLArguments(field: "sessions", document: document, variables: variables)
      let options = sessionListOptions(from: args, claudeCodeHome: claudeCodeHome)
      var sessions = ClaudeCodeSessionIndex.listSessions(options: options).sessions
      if let status = claudeCodeStringValue(args["status"]), status != "completed" {
        sessions = []
      }
      return ClaudeCodeGraphQLCommandExecutor.Result(data: .object([
        "sessions": .object([
          "total": .number(Double(sessions.count)),
          "nodes": .array(sessions.map { .object(typedSessionJSON($0)) })
        ])
      ]))
    }
    return nil
  } catch {
    return ClaudeCodeGraphQLCommandExecutor.Result(errors: [String(describing: error)])
  }
}

func typedSessionJSON(_ session: ClaudeCodeSession) -> JSONObject {
  [
    "id": .string(session.id),
    "projectPath": .string(session.cwd),
    "cwd": .string(session.cwd),
    "status": .string("completed"),
    "createdAt": .string(isoString(session.createdAt)),
    "updatedAt": .string(isoString(session.updatedAt)),
    "messageCount": .number(Double((try? ClaudeCodeRolloutReader.getSessionMessages(path: session.rolloutPath).count) ?? 0))
  ]
}

func typedSessionHistoryJSON(session: ClaudeCodeSession, args: JSONObject) -> JSONValue {
  let offset = max(0, claudeCodeIntValue(args["offset"]) ?? 0)
  let limit = max(0, claudeCodeIntValue(args["limit"]) ?? 50)
  let messages = (try? ClaudeCodeRolloutReader.getSessionMessages(path: session.rolloutPath)) ?? []
  let start = min(offset, messages.count)
  let end = min(start + limit, messages.count)
  let events = messages[start..<end].map { message -> JSONValue in
    .object([
      "type": .string(message.role),
      "uuid": .null,
      "timestamp": .string(message.timestamp),
      "content": message.text.map(JSONValue.string) ?? .null,
      "raw": message.line.payload
    ])
  }
  return .object([
    "total": .number(Double(messages.count)),
    "offset": .number(Double(offset)),
    "limit": .number(Double(limit)),
    "events": .array(Array(events)),
    "tokenUsage": .object(["input": .number(0), "output": .number(0)])
  ])
}

func graphQLArguments(field: String, document: String, variables: JSONObject) -> JSONObject {
  let escapedField = NSRegularExpression.escapedPattern(for: field)
  guard let argumentText = firstRegexCapture(in: document, pattern: #"\b"# + escapedField + #"\s*\(([^)]*)\)"#) else {
    return [:]
  }
  var result: JSONObject = [:]
  let pattern = #"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*("[^"]*"|\$[A-Za-z_][A-Za-z0-9_]*|-?[0-9]+|true|false|[A-Za-z_][A-Za-z0-9_]*)"#
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return result
  }
  let nsRange = NSRange(argumentText.startIndex..<argumentText.endIndex, in: argumentText)
  for match in regex.matches(in: argumentText, range: nsRange) {
    guard
      let nameRange = Range(match.range(at: 1), in: argumentText),
      let valueRange = Range(match.range(at: 2), in: argumentText)
    else {
      continue
    }
    let name = String(argumentText[nameRange])
    let rawValue = String(argumentText[valueRange])
    if rawValue.hasPrefix("$") {
      result[name] = variables[String(rawValue.dropFirst())] ?? .null
    } else if rawValue.hasPrefix("\""), rawValue.hasSuffix("\"") {
      result[name] = .string(String(rawValue.dropFirst().dropLast()))
    } else if rawValue == "true" || rawValue == "false" {
      result[name] = .bool(rawValue == "true")
    } else if let intValue = Int(rawValue) {
      result[name] = .number(Double(intValue))
    } else {
      result[name] = .string(rawValue.lowercased())
    }
  }
  return result
}

func extractInlineGraphQLParams(from document: String) -> JSONObject? {
  guard let paramsRange = document.range(of: "params") else {
    return nil
  }
  guard let colon = document[paramsRange.upperBound...].firstIndex(of: ":") else {
    return nil
  }
  guard let open = document[colon...].firstIndex(of: "{") else {
    return nil
  }
  guard let close = matchingBrace(in: document, open: open) else {
    return nil
  }
  let literal = String(document[open...close])
  let jsonText = quoteGraphQLObjectKeys(literal)
  guard
    let data = jsonText.data(using: .utf8),
    let value = try? JSONDecoder().decode(JSONValue.self, from: data),
    case let .object(object) = value
  else {
    return nil
  }
  return object
}

func matchingBrace(in text: String, open: String.Index) -> String.Index? {
  var depth = 0
  var inString = false
  var escaped = false
  var index = open
  while index < text.endIndex {
    let character = text[index]
    if inString {
      if escaped {
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        inString = false
      }
    } else if character == "\"" {
      inString = true
    } else if character == "{" {
      depth += 1
    } else if character == "}" {
      depth -= 1
      if depth == 0 {
        return index
      }
    }
    index = text.index(after: index)
  }
  return nil
}

func quoteGraphQLObjectKeys(_ literal: String) -> String {
  literal.replacingOccurrences(
    of: #"([,{]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#,
    with: #"$1"$2":"#,
    options: .regularExpression
  )
}

func firstRegexCapture(in text: String, pattern: String) -> String? {
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return nil
  }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else {
    return nil
  }
  return String(text[capture])
}

func shorthandOperation(for command: String) -> String {
  if command == "session.watch" {
    return "subscription"
  }
  return mutationCommandNames.contains(command) ? "mutation" : "query"
}

func escapeGraphQLString(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
}

let mutationCommandNames: Set<String> = [
  "session.run",
  "session.resume",
  "session.fork",
  "group.create",
  "group.add",
  "group.remove",
  "group.pause",
  "group.resume",
  "group.delete",
  "group.run",
  "queue.create",
  "queue.add",
  "queue.pause",
  "queue.resume",
  "queue.delete",
  "queue.update",
  "queue.remove",
  "queue.move",
  "queue.mode",
  "queue.run",
  "bookmark.add",
  "bookmark.delete",
  "token.create",
  "token.revoke",
  "token.rotate",
  "files.rebuild"
]
