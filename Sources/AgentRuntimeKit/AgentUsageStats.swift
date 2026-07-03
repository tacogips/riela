import Foundation
import RielaCore

public protocol AgentUsageStatsRolloutLine: Sendable {
  var timestamp: String { get }
  var type: String { get }
  var payload: JSONValue { get }
}

public struct AgentModelUsageStats: Codable, Equatable, Sendable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var cacheReadInputTokens: Int
  public var cacheCreationInputTokens: Int

  public init(
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    cacheReadInputTokens: Int = 0,
    cacheCreationInputTokens: Int = 0
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheReadInputTokens = cacheReadInputTokens
    self.cacheCreationInputTokens = cacheCreationInputTokens
  }
}

public struct AgentDailyActivity: Codable, Equatable, Sendable {
  public var date: String
  public var messageCount: Int?
  public var sessionCount: Int?
  public var toolCallCount: Int?
  public var tokensByModel: [String: Int]?

  public init(
    date: String,
    messageCount: Int? = nil,
    sessionCount: Int? = nil,
    toolCallCount: Int? = nil,
    tokensByModel: [String: Int]? = nil
  ) {
    self.date = date
    self.messageCount = messageCount
    self.sessionCount = sessionCount
    self.toolCallCount = toolCallCount
    self.tokensByModel = tokensByModel
  }
}

public struct AgentUsageStats: Codable, Equatable, Sendable {
  public var totalSessions: Int
  public var totalMessages: Int
  public var firstSessionDate: String?
  public var lastComputedDate: String?
  public var modelUsage: [String: AgentModelUsageStats]
  public var recentDailyActivity: [AgentDailyActivity]

  public init(
    totalSessions: Int,
    totalMessages: Int,
    firstSessionDate: String?,
    lastComputedDate: String?,
    modelUsage: [String: AgentModelUsageStats],
    recentDailyActivity: [AgentDailyActivity]
  ) {
    self.totalSessions = totalSessions
    self.totalMessages = totalMessages
    self.firstSessionDate = firstSessionDate
    self.lastComputedDate = lastComputedDate
    self.modelUsage = modelUsage
    self.recentDailyActivity = recentDailyActivity
  }
}

public final class AgentUsageStatsCache: @unchecked Sendable {
  private let lock = NSLock()
  private var entry: AgentUsageStatsCacheEntry?

  public init() {}

  public func get(key: String, now: Date) -> AgentUsageStatsCacheEntry? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry, entry.key == key, entry.expiresAt > now else {
      return nil
    }
    return entry
  }

  public func set(_ entry: AgentUsageStatsCacheEntry) {
    lock.lock()
    self.entry = entry
    lock.unlock()
  }
}

public struct AgentUsageStatsCacheEntry: Sendable {
  public var key: String
  public var expiresAt: Date
  public var value: AgentUsageStats?

  public init(key: String, expiresAt: Date, value: AgentUsageStats?) {
    self.key = key
    self.expiresAt = expiresAt
    self.value = value
  }
}

public enum AgentUsageStatsCollector {
  public static let defaultRecentDays = 14
  public static let defaultCacheTTL: TimeInterval = 5

  public static func collect<Line: AgentUsageStatsRolloutLine>(
    sessionsDir: String,
    recentDays requestedRecentDays: Int?,
    now requestedNow: Date?,
    cache: AgentUsageStatsCache,
    readRollout: (String) throws -> [Line]
  ) -> AgentUsageStats? {
    let recentDays = normalizeRecentDays(requestedRecentDays)
    let now = requestedNow ?? Date()
    let key = "\(sessionsDir)::\(recentDays)"

    if let cached = cache.get(key: key, now: now) {
      return cached.value
    }

    guard let rolloutFiles = listRolloutFiles(sessionsDir: sessionsDir) else {
      cacheValue(cache: cache, key: key, now: now, value: nil)
      return nil
    }

    let result = computeStats(
      rolloutFiles: rolloutFiles,
      recentDays: recentDays,
      now: now,
      readRollout: readRollout
    )
    cacheValue(cache: cache, key: key, now: now, value: result)
    return result
  }

  private static func computeStats<Line: AgentUsageStatsRolloutLine>(
    rolloutFiles: [String],
    recentDays: Int,
    now: Date,
    readRollout: (String) throws -> [Line]
  ) -> AgentUsageStats {
    let lastComputedDate = dateKey(from: now)
    let firstRecentDay = Calendar.utc.startOfDay(for: now).addingTimeInterval(TimeInterval(-(recentDays - 1) * 86_400))
    var totalSessions = 0
    var totalMessages = 0
    var firstSessionDate: String?
    var modelUsage: [String: MutableModelUsageStats] = [:]
    var dailyActivity: [String: MutableDailyActivity] = [:]
    var tokenCountStateByKey: [String: TokenCountState] = [:]

    for rolloutFile in rolloutFiles {
      let lines = (try? readRollout(rolloutFile)) ?? []
      guard !lines.isEmpty else {
        continue
      }
      totalSessions += 1

      var sessionDateForFile: String?
      for line in lines {
        if let lineDate = dateKey(fromTimestamp: line.timestamp) {
          sessionDateForFile = minDateKey(sessionDateForFile, lineDate)
        }
        if line.type == "session_meta", let timestamp = extractSessionMetaTimestamp(line.payload), let metaDate = dateKey(fromTimestamp: timestamp) {
          sessionDateForFile = minDateKey(sessionDateForFile, metaDate)
        }

        if isUserOrAssistantMessage(line) {
          totalMessages += 1
          if let lineDate = dateKey(fromTimestamp: line.timestamp) {
            dailyActivity[lineDate, default: MutableDailyActivity()].messageCount += 1
          }
        }

        let toolCallCount = extractToolCallCount(line)
        if toolCallCount > 0, let lineDate = dateKey(fromTimestamp: line.timestamp) {
          dailyActivity[lineDate, default: MutableDailyActivity()].toolCallCount += toolCallCount
        }

        guard let usageEvent = normalizeForAggregation(extractUsageEvent(line), stateByKey: &tokenCountStateByKey),
              usageEvent.totalTokens > 0 else {
          continue
        }
        modelUsage[usageEvent.model, default: MutableModelUsageStats()].add(usageEvent)
        if let lineDate = dateKey(fromTimestamp: line.timestamp) {
          dailyActivity[lineDate, default: MutableDailyActivity()].tokensByModel[usageEvent.model, default: 0] += usageEvent.totalTokens
        }
      }

      if let sessionDateForFile {
        firstSessionDate = minDateKey(firstSessionDate, sessionDateForFile)
        dailyActivity[sessionDateForFile, default: MutableDailyActivity()].sessionCount += 1
      }
    }

    let recentDailyActivity = (0..<recentDays).map { offset in
      let date = firstRecentDay.addingTimeInterval(TimeInterval(offset * 86_400))
      let key = dateKey(from: date)
      guard let activity = dailyActivity[key] else {
        return AgentDailyActivity(date: key)
      }
      return activity.export(date: key)
    }

    return AgentUsageStats(
      totalSessions: totalSessions,
      totalMessages: totalMessages,
      firstSessionDate: firstSessionDate,
      lastComputedDate: lastComputedDate,
      modelUsage: modelUsage.mapValues { $0.export() },
      recentDailyActivity: recentDailyActivity
    )
  }

  private static func normalizeRecentDays(_ value: Int?) -> Int {
    guard let value, value > 0 else {
      return defaultRecentDays
    }
    return value
  }

  private static func cacheValue(cache: AgentUsageStatsCache, key: String, now: Date, value: AgentUsageStats?) {
    cache.set(AgentUsageStatsCacheEntry(key: key, expiresAt: now.addingTimeInterval(defaultCacheTTL), value: value))
  }
}

private struct MutableModelUsageStats {
  var inputTokens = 0
  var outputTokens = 0
  var cacheReadInputTokens = 0
  var cacheCreationInputTokens = 0

  mutating func add(_ event: UsageEvent) {
    inputTokens += event.inputTokens
    outputTokens += event.outputTokens
    cacheReadInputTokens += event.cacheReadInputTokens
    cacheCreationInputTokens += event.cacheCreationInputTokens
  }

  func export() -> AgentModelUsageStats {
    AgentModelUsageStats(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadInputTokens: cacheReadInputTokens,
      cacheCreationInputTokens: cacheCreationInputTokens
    )
  }
}

private struct MutableDailyActivity {
  var messageCount = 0
  var sessionCount = 0
  var toolCallCount = 0
  var tokensByModel: [String: Int] = [:]

  func export(date: String) -> AgentDailyActivity {
    AgentDailyActivity(
      date: date,
      messageCount: messageCount > 0 ? messageCount : nil,
      sessionCount: sessionCount > 0 ? sessionCount : nil,
      toolCallCount: toolCallCount > 0 ? toolCallCount : nil,
      tokensByModel: tokensByModel.isEmpty ? nil : tokensByModel
    )
  }
}

private struct UsageEvent {
  var source: Source
  var model: String
  var inputTokens: Int
  var outputTokens: Int
  var cacheReadInputTokens: Int
  var cacheCreationInputTokens: Int
  var totalTokens: Int
  var isCumulative: Bool
  var aggregationKey: String?

  enum Source {
    case turnComplete
    case tokenCount
  }
}

private struct TokenCountState {
  var lastInputTokens: Int?
  var lastOutputTokens: Int?
  var lastCacheReadInputTokens: Int?
  var lastCacheCreationInputTokens: Int?
  var lastTotalTokens: Int?

  mutating func set(_ event: UsageEvent) {
    lastInputTokens = event.inputTokens
    lastOutputTokens = event.outputTokens
    lastCacheReadInputTokens = event.cacheReadInputTokens
    lastCacheCreationInputTokens = event.cacheCreationInputTokens
    lastTotalTokens = event.totalTokens
  }

  mutating func setMax(_ event: UsageEvent) {
    lastInputTokens = maxDefined(lastInputTokens, event.inputTokens)
    lastOutputTokens = maxDefined(lastOutputTokens, event.outputTokens)
    lastCacheReadInputTokens = maxDefined(lastCacheReadInputTokens, event.cacheReadInputTokens)
    lastCacheCreationInputTokens = maxDefined(lastCacheCreationInputTokens, event.cacheCreationInputTokens)
    lastTotalTokens = maxDefined(lastTotalTokens, event.totalTokens)
  }
}

private func listRolloutFiles(sessionsDir: String) -> [String]? {
  let root = URL(fileURLWithPath: sessionsDir, isDirectory: true)
  guard FileManager.default.fileExists(atPath: root.path) else {
    return nil
  }
  guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
    return nil
  }
  var files: [String] = []
  for case let url as URL in enumerator {
    guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else {
      continue
    }
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
    if values?.isRegularFile == true {
      files.append(url.path)
    }
  }
  return files.sorted()
}

private func isUserOrAssistantMessage(_ line: AgentUsageStatsRolloutLine) -> Bool {
  guard let payload = objectValue(line.payload) else {
    return false
  }
  if line.type == "event_msg" {
    return ["UserMessage", "AgentMessage"].contains(stringValue(payload["type"]))
  }
  if line.type == "response_item", stringValue(payload["type"]) == "message" {
    return ["user", "assistant"].contains(stringValue(payload["role"]))
  }
  return false
}

private func extractToolCallCount(_ line: AgentUsageStatsRolloutLine) -> Int {
  guard let payload = objectValue(line.payload) else {
    return 0
  }
  if line.type == "event_msg", stringValue(payload["type"]) == "ExecCommandBegin" {
    return 1
  }
  if line.type == "response_item", ["function_call", "local_shell_call"].contains(stringValue(payload["type"])) {
    return 1
  }
  return 0
}

private func extractUsageEvent(_ line: AgentUsageStatsRolloutLine) -> UsageEvent? {
  guard line.type == "event_msg", let payload = objectValue(line.payload) else {
    return nil
  }

  var source: UsageEvent.Source?
  var usage: JSONObject?
  var modelFromInfo: String?
  var model: String?
  var isCumulative = false
  var aggregationKey: String?

  switch stringValue(payload["type"]) {
  case "TurnComplete":
    source = .turnComplete
    usage = objectValue(payload["usage"])
  case "token_count", "TokenCount":
    guard let info = objectValue(payload["info"]) else {
      return nil
    }
    source = .tokenCount
    modelFromInfo = stringValue(info["model"])
    let lastTokenUsage = objectValue(info["last_token_usage"]) ?? objectValue(payload["last_token_usage"])
    let totalTokenUsage = objectValue(info["total_token_usage"]) ?? objectValue(payload["total_token_usage"])
    if let lastTokenUsage {
      usage = lastTokenUsage
    } else if let totalTokenUsage {
      usage = totalTokenUsage
      isCumulative = true
    } else {
      usage = objectValue(info["usage"]) ?? objectValue(payload["usage"]) ?? payload
    }
    model = resolveTokenCountModel(payload: payload, usage: usage, info: info, modelFromInfo: modelFromInfo)
    aggregationKey = extractTokenCountAggregationKey(payload: payload, info: info, model: model ?? "unknown")
  default:
    return nil
  }

  guard let source, let usage else {
    return nil
  }
  let inputTokens = intValue(usage["input_tokens"]) ?? intValue(usage["inputTokens"]) ?? 0
  let outputTokens = intValue(usage["output_tokens"]) ?? intValue(usage["outputTokens"]) ?? 0
  let cacheReadInputTokens = intValue(usage["cache_read_input_tokens"])
    ?? intValue(usage["cacheReadInputTokens"])
    ?? intValue(usage["cached_input_tokens"])
    ?? 0
  let cacheCreationInputTokens = intValue(usage["cache_creation_input_tokens"]) ?? intValue(usage["cacheCreationInputTokens"]) ?? 0
  let computedTotal = inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens
  let totalTokens = intValue(usage["total_tokens"]) ?? intValue(usage["totalTokens"]) ?? computedTotal
  let resolvedModel = model
    ?? modelFromInfo
    ?? stringValue(usage["model"])
    ?? stringValue(usage["model_id"])
    ?? stringValue(payload["model"])
    ?? "unknown"

  return UsageEvent(
    source: source,
    model: resolvedModel,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cacheReadInputTokens: cacheReadInputTokens,
    cacheCreationInputTokens: cacheCreationInputTokens,
    totalTokens: totalTokens,
    isCumulative: isCumulative,
    aggregationKey: aggregationKey
  )
}

private func normalizeForAggregation(_ event: UsageEvent?, stateByKey: inout [String: TokenCountState]) -> UsageEvent? {
  guard var event, event.source == .tokenCount else {
    return event
  }
  let key = event.aggregationKey ?? event.model
  var state = stateByKey[key] ?? TokenCountState()
  guard event.isCumulative else {
    stateByKey[key] = state
    return event
  }

  if let lastTotalTokens = state.lastTotalTokens, event.totalTokens < lastTotalTokens {
    state.set(event)
    stateByKey[key] = state
    event.isCumulative = false
    return event
  }

  let deltaInputTokens = positiveDelta(event.inputTokens, state.lastInputTokens)
  let deltaOutputTokens = positiveDelta(event.outputTokens, state.lastOutputTokens)
  let deltaCacheReadInputTokens = positiveDelta(event.cacheReadInputTokens, state.lastCacheReadInputTokens)
  let deltaCacheCreationInputTokens = positiveDelta(event.cacheCreationInputTokens, state.lastCacheCreationInputTokens)
  let deltaTotalTokens = positiveDelta(event.totalTokens, state.lastTotalTokens)
  state.setMax(event)
  stateByKey[key] = state
  guard deltaTotalTokens > 0 else {
    return nil
  }
  event.inputTokens = deltaInputTokens
  event.outputTokens = deltaOutputTokens
  event.cacheReadInputTokens = deltaCacheReadInputTokens
  event.cacheCreationInputTokens = deltaCacheCreationInputTokens
  event.totalTokens = deltaTotalTokens
  event.isCumulative = false
  return event
}

private func extractTokenCountAggregationKey(payload: JSONObject, info: JSONObject, model: String) -> String {
  var parts: [String] = []
  if let streamId = stringValue(info["stream_id"]) {
    parts.append("stream:\(streamId)")
  }
  if let turnId = stringValue(info["turn_id"]) {
    parts.append("info_turn:\(turnId)")
  }
  if let turnId = stringValue(payload["turn_id"]) {
    parts.append("payload_turn:\(turnId)")
  }
  if let responseId = stringValue(info["response_id"]) {
    parts.append("response:\(responseId)")
  }
  if let messageId = stringValue(info["message_id"]) {
    parts.append("message:\(messageId)")
  }
  parts.append("model:\(model)")
  return parts.joined(separator: "|")
}

private func resolveTokenCountModel(payload: JSONObject, usage: JSONObject?, info: JSONObject, modelFromInfo: String?) -> String {
  if let explicit = modelFromInfo ?? stringValue(usage?["model"]) ?? stringValue(usage?["model_id"]) ?? stringValue(payload["model"]) {
    return explicit
  }
  if let model = extractModelFromRateLimits(objectValue(payload["rate_limits"])) {
    return model
  }
  if let model = extractModelFromRateLimits(objectValue(info["rate_limits"])) {
    return model
  }
  return "unknown"
}

private func extractModelFromRateLimits(_ rateLimits: JSONObject?) -> String? {
  if let model = normalizeRateLimitModel(stringValue(rateLimits?["limit_name"])) {
    return model
  }
  return normalizeRateLimitModel(stringValue(rateLimits?["limit_id"]))
}

private func normalizeRateLimitModel(_ value: String?) -> String? {
  guard let value else {
    return nil
  }
  let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  var output = ""
  var lastWasDash = false
  for scalar in lower.unicodeScalars {
    let isAllowed = CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
    let isSeparator = CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "_"
    if isAllowed, !isSeparator {
      output.unicodeScalars.append(scalar)
      lastWasDash = scalar == "-"
    } else if !lastWasDash {
      output.append("-")
      lastWasDash = true
    }
  }
  output = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  return output.isEmpty ? nil : output
}

private func extractSessionMetaTimestamp(_ payloadValue: JSONValue) -> String? {
  guard let payload = objectValue(payloadValue) else {
    return nil
  }
  if let timestamp = stringValue(payload["timestamp"]) {
    return timestamp
  }
  return objectValue(payload["meta"]).flatMap { stringValue($0["timestamp"]) }
}

private func minDateKey(_ current: String?, _ candidate: String) -> String {
  guard let current else {
    return candidate
  }
  return candidate < current ? candidate : current
}

private func positiveDelta(_ current: Int, _ previous: Int?) -> Int {
  guard let previous else {
    return current
  }
  return max(current - previous, 0)
}

private func maxDefined(_ previous: Int?, _ current: Int) -> Int {
  guard let previous else {
    return current
  }
  return max(previous, current)
}

private func dateKey(from date: Date) -> String {
  DateFormatter.agentUsageDate.string(from: date)
}

private func dateKey(fromTimestamp timestamp: String) -> String? {
  let fractionalFormatter = ISO8601DateFormatter()
  fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let parsed = fractionalFormatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
  return parsed.map(dateKey(from:))
}

private func objectValue(_ value: JSONValue?) -> JSONObject? {
  if case let .object(object)? = value {
    return object
  }
  return nil
}

private func stringValue(_ value: JSONValue?) -> String? {
  if case let .string(string)? = value {
    return string
  }
  return nil
}

private func intValue(_ value: JSONValue?) -> Int? {
  guard let int64 = value?.asInt64 else {
    return nil
  }
  return Int(exactly: int64)
}

private extension Calendar {
  static var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
}

private extension DateFormatter {
  static let agentUsageDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar.utc
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}
