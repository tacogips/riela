import Foundation
import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeXDigest(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let operation = try XDigestOperation(config: input.addon.config ?? [:])
    let engine = XDigestEngine(
      environment: environment,
      currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    )
    let result = try engine.execute(operation, input: input)
    var payload = result.payload
    payload["status"] = .string(nonEmptyString(payload["status"]) ?? "ok")
    payload["addon"] = .string(input.addon.name)
    payload["stepId"] = .string(input.stepId)
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: result.when,
      payload: payload
    )
  }
}

private enum XDigestOperation: String {
  case readState = "read-state"
  case normalizeFetchedPosts = "normalize-fetched-posts"
  case validateSummaryOutput = "validate-summary-output"
  case persistState = "persist-state"
  case noDigestOutput = "no-digest-output"

  init(config: JSONObject) throws {
    guard let rawValue = nonEmptyString(config["operation"]) else {
      throw AdapterExecutionError(.policyBlocked, "riela/x-digest config.operation is required")
    }
    guard let operation = Self(rawValue: rawValue) else {
      throw AdapterExecutionError(.policyBlocked, "unsupported riela/x-digest operation '\(rawValue)'")
    }
    self = operation
  }
}

private struct XDigestResult {
  var when: [String: Bool]
  var payload: JSONObject
}

private struct XDigestEngine {
  private static let defaultStateFile = ".riela-data/x-follower-ai-business-digest/state.json"
  private static let privateRelativePrefixes = [
    ".riela-data/",
    ".riela-artifact/",
    ".riela-artifacts/",
    ".private/",
    "tmp/",
    "temp/"
  ]
  private static let privateAbsolutePrefixes = [
    "/tmp/",
    "/var/tmp/",
    "/var/folders/"
  ]

  var environment: [String: String]
  var currentDirectory: URL

  func execute(_ operation: XDigestOperation, input: WorkflowAddonExecutionInput) throws -> XDigestResult {
    switch operation {
    case .readState:
      return try readState(input)
    case .normalizeFetchedPosts:
      return normalizeFetchedPosts(input)
    case .validateSummaryOutput:
      return validateSummary(input)
    case .persistState:
      return try persistState(input)
    case .noDigestOutput:
      return noDigestOutput(input)
    }
  }

  private func readState(_ input: WorkflowAddonExecutionInput) throws -> XDigestResult {
    let workflowInput = workflowInput(input)
    let stateFile = try stateFile(from: input)
    let previousState = readStateFile(stateFile)
    let accountUsername = nonEmptyString(workflowInput["accountUsername"])
      ?? nonEmptyEnvironment("RIELA_X_DIGEST_ACCOUNT_USERNAME")
      ?? nonEmptyEnvironment("X_GW_ACCOUNT_USERNAME")
      ?? "@tacogips"
    let lookbackMinutes = try positiveInt("RIELA_X_DIGEST_LOOKBACK_MINUTES", fallback: 60)
    let maxPosts = max(5, min(try positiveInt("RIELA_X_DIGEST_MAX_POSTS", fallback: 50), 50))
    let now = now(from: input)
    let windowStart = Calendar(identifier: .gregorian).date(byAdding: .minute, value: -lookbackMinutes, to: now) ?? now
    let sinceId = nonEmptyString(previousState["lastPostId"]) ?? ""
    return XDigestResult(
      when: ["always": true],
      payload: [
        "stateFile": .string(stateFile),
        "accountUsername": .string(accountUsername),
        "accountUsernameBare": .string(accountUsername.trimmingPrefix("@")),
        "lookbackMinutes": .number(Double(lookbackMinutes)),
        "maxPosts": .number(Double(maxPosts)),
        "sinceId": .string(sinceId),
        "windowStartIso": .string(isoString(windowStart)),
        "requestedAt": .string(isoString(now)),
        "previousState": .object(previousState)
      ]
    )
  }

  private func normalizeFetchedPosts(_ input: WorkflowAddonExecutionInput) -> XDigestResult {
    let payloads = upstreamPayloads(input.resolvedInputPayload)
    let cursor = payloads.first { payload in
      nonEmptyString(payload["windowStartIso"]) != nil
        && nonEmptyString(payload["requestedAt"]) != nil
        && numberValue(payload["maxPosts"]) != nil
    } ?? [:]
    let gatewayPayload = payloads.first { payload in
      object(payload["xGateway"]) != nil
    } ?? [:]
    let gateway = object(gatewayPayload["xGateway"]) ?? [:]
    let data = object(object(gateway["data"])?.value(at: ["data"])) ?? [:]
    let timeline = object(data["followingTimeline"]) ?? [:]
    let rawPosts = array(timeline["posts"]) ?? []
    let fetchedPosts = rawPosts.compactMap { value -> JSONObject? in
      guard let post = object(value) else { return nil }
      return normalizePost(post)
    }
    let windowStart = parseDate(nonEmptyString(cursor["windowStartIso"]))
    let windowEnd = parseDate(nonEmptyString(cursor["requestedAt"])) ?? now(from: input)
    let sinceId = nonEmptyString(cursor["sinceId"]) ?? ""
    let sinceNumeric = numericPostId(sinceId)
    let maxPosts = Int(numberValue(cursor["maxPosts"]) ?? 50)
    var selected: [JSONObject] = []
    for post in fetchedPosts {
      let created = parseDate(nonEmptyString(post["createdAt"]))
      let inWindow = created.map { date in
        (windowStart.map { date >= $0 } ?? true) && date <= windowEnd
      } ?? true
      let postId = numericPostId(nonEmptyString(post["id"]))
      let afterCursor = sinceNumeric == nil || postId == nil || (postId ?? 0) > (sinceNumeric ?? 0)
      if inWindow && afterCursor {
        var enriched = post
        enriched["postUrl"] = .string(postURL(post))
        enriched["authorUrl"] = .string(authorURL(post))
        selected.append(enriched)
      }
    }
    selected.sort { (numericPostId(nonEmptyString($0["id"])) ?? -1) > (numericPostId(nonEmptyString($1["id"])) ?? -1) }
    let fetchedIds = fetchedPosts
      .compactMap { nonEmptyString($0["id"]) }
      .filter { numericPostId($0) != nil }
      .sorted { (numericPostId($0) ?? -1) > (numericPostId($1) ?? -1) }
    return XDigestResult(
      when: ["always": true],
      payload: [
        "fetchWindow": .object([
          "startIso": .string(nonEmptyString(cursor["windowStartIso"]) ?? ""),
          "endIso": .string(nonEmptyString(cursor["requestedAt"]) ?? ""),
          "lookbackMinutes": cursor["lookbackMinutes"] ?? .number(60)
        ]),
        "sinceId": .string(sinceId),
        "maxPosts": .number(Double(maxPosts)),
        "fetchedPostCount": .number(Double(fetchedPosts.count)),
        "selectedPostCount": .number(Double(Array(selected.prefix(maxPosts)).count)),
        "maxFetchedPostId": .string(fetchedIds.first ?? sinceId),
        "pageInfo": timeline["pageInfo"] ?? .object([:]),
        "selectedPosts": .array(Array(selected.prefix(maxPosts)).map { .object($0) })
      ]
    )
  }

  private func validateSummary(_ input: WorkflowAddonExecutionInput) -> XDigestResult {
    let payloads = upstreamPayloads(input.resolvedInputPayload)
    let normalizePayload = payloads.first { payload in
      object(payload["fetchWindow"]) != nil
        && array(payload["selectedPosts"]) != nil
        && nonEmptyString(payload["maxFetchedPostId"]) != nil
    } ?? [:]
    let summaryPayload = payloads.first { payload in
      array(payload["topicDigests"]) != nil && bool(payload["shouldSendTelegram"]) != nil
    } ?? [:]
    let selectedPosts = (array(normalizePayload["selectedPosts"]) ?? []).compactMap(object)
    let selectedById = Dictionary(uniqueKeysWithValues: selectedPosts.compactMap { post -> (String, JSONObject)? in
      guard let id = nonEmptyString(post["id"]) else { return nil }
      return (id, post)
    })
    let topicDigests = (array(summaryPayload["topicDigests"]) ?? []).compactMap(object)
    var validated: [JSONObject] = []
    for item in topicDigests {
      var posts: [JSONObject] = []
      var seen = Set<String>()
      var invalidCount = 0
      for postId in sourcePostIds(item) {
        guard let post = selectedById[postId] else {
          invalidCount += 1
          continue
        }
        if seen.insert(postId).inserted {
          posts.append(post)
        }
      }
      guard !posts.isEmpty else { continue }
      let sourcePosts = posts.map(sourcePostSummary).sorted { lhs, rhs in
        (numberValue(lhs["viewCount"]) ?? -1) > (numberValue(rhs["viewCount"]) ?? -1)
      }
      let users = uniqueUsers(posts)
      let totalViews = sourcePosts.reduce(0.0) { partial, post in
        partial + (numberValue(post["viewCount"]) ?? 0)
      }
      var topic: JSONObject = [
        "topic": .string(cleanText(item["topic"], fallback: "AI/business update")),
        "reason": .string(cleanText(item["reason"], fallback: "AI/business relevant")),
        "totalViewCount": .number(totalViews),
        "postUserCount": .number(Double(users.count)),
        "summary": .string(cleanText(item["summary"], fallback: cleanText(posts.first?["text"], fallback: ""))),
        "userLinks": .array(Array(users.prefix(3)).map { .object($0) }),
        "sourcePosts": .array(Array(sourcePosts.prefix(3)).map { post in
          var withoutHandle = post
          withoutHandle.removeValue(forKey: "authorHandle")
          return .object(withoutHandle)
        }),
        "sourcePostIds": .array(posts.compactMap { nonEmptyString($0["id"]).map(JSONValue.string) }),
        "invalidSourcePostIdCount": .number(Double(invalidCount))
      ]
      if let articleURL = nonEmptyString(item["articleUrl"]) {
        topic["articleUrl"] = .string(articleURL)
      }
      validated.append(topic)
    }
    validated.sort { (numberValue($0["totalViewCount"]) ?? 0) > (numberValue($1["totalViewCount"]) ?? 0) }
    let replyParts = validated.enumerated().map { index, topic in
      let users = (array(topic["userLinks"]) ?? [])
        .compactMap(object)
        .map { "\(nonEmptyString($0["handle"]) ?? "") \(nonEmptyString($0["url"]) ?? "")".trimmingCharacters(in: .whitespaces) }
        .joined(separator: ", ")
      let posts = (array(topic["sourcePosts"]) ?? [])
        .compactMap(object)
        .compactMap { nonEmptyString($0["postUrl"]) }
        .joined(separator: " ")
      let article = nonEmptyString(topic["articleUrl"]).map { "\nArticle: \($0)" } ?? ""
      return [
        "\(index + 1). \(nonEmptyString(topic["topic"]) ?? "") (\(Int(numberValue(topic["totalViewCount"]) ?? 0)) views, \(Int(numberValue(topic["postUserCount"]) ?? 0)) users)",
        nonEmptyString(topic["summary"]) ?? "",
        "Users: \(users)",
        "Posts: \(posts)\(article)"
      ].joined(separator: "\n")
    }
    let maxFetchedPostId = nonEmptyString(normalizePayload["maxFetchedPostId"])
      ?? nonEmptyString(summaryPayload["maxFetchedPostId"])
      ?? ""
    let selectedCount = selectedPosts.count
    let sourceCount = validated.reduce(0) { partial, topic in partial + (array(topic["sourcePostIds"])?.count ?? 0) }
    let discardedCount = numberValue(summaryPayload["discardedCount"]).map { count in
      count + Double(topicDigests.count - validated.count)
    } ?? Double(selectedCount - sourceCount)
    let replyText = replyParts.joined(separator: "\n")
    let shouldSendTelegram = !validated.isEmpty && !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return XDigestResult(
      when: ["should_send_telegram": shouldSendTelegram],
      payload: [
        "shouldSendTelegram": .bool(!validated.isEmpty),
        "maxFetchedPostId": .string(maxFetchedPostId),
        "replyText": .string(replyText),
        "topicDigests": .array(validated.map { .object($0) }),
        "discardedCount": .number(discardedCount),
        "droppedInvalidTopicDigestCount": .number(Double(topicDigests.count - validated.count)),
        "droppedInvalidSourcePostIdCount": .number(validated.reduce(0) { partial, topic in
          partial + (numberValue(topic["invalidSourcePostIdCount"]) ?? 0)
        })
      ]
    )
  }

  private func persistState(_ input: WorkflowAddonExecutionInput) throws -> XDigestResult {
    let payload = upstreamPayloads(input.resolvedInputPayload).last ?? [:]
    let stateFile = try stateFile(from: input)
    let maxFetchedPostId = nonEmptyString(payload["maxFetchedPostId"]) ?? ""
    let shouldSend = bool(payload["shouldSendTelegram"]) == true
    let replyText = string(payload["replyText"]) ?? ""
    if !maxFetchedPostId.isEmpty {
      let url = URL(fileURLWithPath: stateFile, relativeTo: currentDirectory).standardizedFileURL
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let retainedTopics = array(payload["topicDigests"]) ?? []
      let state: JSONObject = [
        "lastPostId": .string(maxFetchedPostId),
        "updatedAt": .string(isoString(now(from: input))),
        "retainedTopicCount": .number(Double(retainedTopics.count))
      ]
      let data = try JSONEncoder.prettySorted.encode(JSONValue.object(state))
      try data.write(to: url, options: [.atomic])
    }
    let shouldSendTelegram = shouldSend && !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return XDigestResult(
      when: ["should_send_telegram": shouldSendTelegram],
      payload: [
        "shouldSendTelegram": .bool(shouldSend),
        "replyText": .string(replyText),
        "maxFetchedPostId": .string(maxFetchedPostId),
        "stateFile": .string(stateFile),
        "persisted": .bool(!maxFetchedPostId.isEmpty)
      ]
    )
  }

  private func noDigestOutput(_ input: WorkflowAddonExecutionInput) -> XDigestResult {
    let payload = upstreamPayloads(input.resolvedInputPayload).last ?? [:]
    return XDigestResult(
      when: ["always": true],
      payload: [
        "status": .string("no_digest"),
        "shouldSendTelegram": .bool(false),
        "replyText": .string(""),
        "maxFetchedPostId": .string(nonEmptyString(payload["maxFetchedPostId"]) ?? ""),
        "stateFile": .string(nonEmptyString(payload["stateFile"]) ?? ""),
        "persisted": .bool(bool(payload["persisted"]) == true)
      ]
    )
  }

  private func stateFile(from input: WorkflowAddonExecutionInput) throws -> String {
    let workflowInput = workflowInput(input)
    let configured = nonEmptyString(workflowInput["stateFile"])
      ?? nonEmptyEnvironment("RIELA_X_DIGEST_STATE_FILE")
      ?? Self.defaultStateFile
    try assertPrivateRuntimePath(configured)
    return configured
  }

  private func assertPrivateRuntimePath(_ filePath: String) throws {
    let resolved = URL(fileURLWithPath: filePath, relativeTo: currentDirectory).standardizedFileURL.path
    let cwd = currentDirectory.standardizedFileURL.path
    let relative = resolved.hasPrefix(cwd + "/") ? String(resolved.dropFirst(cwd.count + 1)) : ""
    let allowed = Self.privateRelativePrefixes.contains { relative.hasPrefix($0) }
      || Self.privateAbsolutePrefixes.contains { resolved.hasPrefix($0) }
    guard allowed else {
      throw AdapterExecutionError(.policyBlocked, "RIELA_X_DIGEST_STATE_FILE must point to an ignored/private runtime path, got \(filePath)")
    }
  }

  private func readStateFile(_ filePath: String) -> JSONObject {
    let url = URL(fileURLWithPath: filePath, relativeTo: currentDirectory).standardizedFileURL
    guard let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
      case let .object(object) = decoded
    else {
      return [:]
    }
    return object
  }

  private func workflowInput(_ input: WorkflowAddonExecutionInput) -> JSONObject {
    let variables = addonVariables(for: input)
    return object(variables["workflowInput"]) ?? object(variables["runtimeVariables"]?.value(at: ["workflowInput"])) ?? [:]
  }

  private func positiveInt(_ environmentName: String, fallback: Int) throws -> Int {
    guard let raw = nonEmptyEnvironment(environmentName) else {
      return fallback
    }
    guard let value = Int(raw), value > 0 else {
      throw AdapterExecutionError(.policyBlocked, "\(environmentName) must be a positive integer")
    }
    return value
  }

  private func nonEmptyEnvironment(_ name: String) -> String? {
    guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private func now(from input: WorkflowAddonExecutionInput) -> Date {
    let variables = addonVariables(for: input)
    if let configured = nonEmptyString(input.addon.config?["nowIso"]) ?? nonEmptyString(variables["nowIso"]),
      let date = parseDate(configured) {
      return date
    }
    return Date()
  }
}

private func upstreamPayloads(_ input: JSONObject) -> [JSONObject] {
  var payloads: [JSONObject] = []
  for value in array(input["upstream"]) ?? [] {
    if let payload = object(value.value(at: ["output", "payload"])) {
      payloads.append(payload)
    }
  }
  return payloads
}

private func normalizePost(_ post: JSONObject) -> JSONObject {
  let metrics = object(post["metrics"]) ?? [:]
  let author = object(post["author"]) ?? [:]
  let refs = array(post["referencedPosts"]) ?? []
  return [
    "id": .string(nonEmptyString(post["id"]) ?? ""),
    "text": .string(string(post["text"]) ?? ""),
    "createdAt": .string(nonEmptyString(post["createdAt"]) ?? ""),
    "author": .object([
      "username": .string(nonEmptyString(author["username"]) ?? ""),
      "name": .string(nonEmptyString(author["name"]) ?? "")
    ]),
    "metrics": .object([
      "impressionCount": numberValue(metrics["impressionCount"]).map(JSONValue.number) ?? .null,
      "likeCount": numberValue(metrics["likeCount"]).map(JSONValue.number) ?? .null,
      "replyCount": numberValue(metrics["replyCount"]).map(JSONValue.number) ?? .null,
      "repostCount": numberValue(metrics["repostCount"]).map(JSONValue.number) ?? .null,
      "quoteCount": numberValue(metrics["quoteCount"]).map(JSONValue.number) ?? .null,
      "bookmarkCount": numberValue(metrics["bookmarkCount"]).map(JSONValue.number) ?? .null
    ]),
    "referencedPosts": .array(refs.compactMap { value -> JSONValue? in
      guard let ref = object(value) else { return nil }
      let refAuthor = object(ref["author"]) ?? [:]
      return .object([
        "relation": .string(nonEmptyString(ref["relation"]) ?? ""),
        "id": .string(nonEmptyString(ref["id"]) ?? ""),
        "text": .string(string(ref["text"]) ?? ""),
        "author": .object([
          "username": .string(nonEmptyString(refAuthor["username"]) ?? ""),
          "name": .string(nonEmptyString(refAuthor["name"]) ?? "")
        ])
      ])
    })
  ]
}

private func sourcePostSummary(_ post: JSONObject) -> JSONObject {
  [
    "id": .string(nonEmptyString(post["id"]) ?? ""),
    "postUrl": .string(postURL(post)),
    "authorHandle": .string(authorHandle(post)),
    "authorUrl": .string(authorURL(post)),
    "viewCount": object(post["metrics"]).flatMap { metrics in
      numberValue(metrics["impressionCount"]).map(JSONValue.number)
    } ?? .null
  ]
}

private func uniqueUsers(_ posts: [JSONObject]) -> [JSONObject] {
  var users: [JSONObject] = []
  var seen = Set<String>()
  for post in posts {
    let author = object(post["author"]) ?? [:]
    let key = (nonEmptyString(author["username"]) ?? "").trimmingPrefix("@").lowercased()
    guard !key.isEmpty, seen.insert(key).inserted else {
      continue
    }
    users.append(["handle": .string(authorHandle(post)), "url": .string(authorURL(post))])
  }
  return users
}

private func postURL(_ post: JSONObject) -> String {
  if let url = nonEmptyString(post["postUrl"]) {
    return url
  }
  let author = object(post["author"]) ?? [:]
  let username = (nonEmptyString(author["username"]) ?? "").trimmingPrefix("@")
  guard let id = nonEmptyString(post["id"]), !username.isEmpty else {
    return ""
  }
  return "https://x.com/\(username)/status/\(id)"
}

private func authorURL(_ post: JSONObject) -> String {
  if let url = nonEmptyString(post["authorUrl"]) {
    return url
  }
  let author = object(post["author"]) ?? [:]
  let username = (nonEmptyString(author["username"]) ?? "").trimmingPrefix("@")
  return username.isEmpty ? "" : "https://x.com/\(username)"
}

private func authorHandle(_ post: JSONObject) -> String {
  let author = object(post["author"]) ?? [:]
  let username = (nonEmptyString(author["username"]) ?? "").trimmingPrefix("@")
  return username.isEmpty ? "@unknown" : "@\(username)"
}

private func sourcePostIds(_ item: JSONObject) -> [String] {
  if let ids = array(item["sourcePostIds"]) {
    return ids.compactMap(nonEmptyString)
  }
  return nonEmptyString(item["id"]).map { [$0] } ?? []
}

private func cleanText(_ value: JSONValue?, fallback: String) -> String {
  guard let text = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
    return fallback
  }
  return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func parseDate(_ value: String?) -> Date? {
  guard let value, !value.isEmpty else {
    return nil
  }
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = formatter.date(from: value) {
    return date
  }
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: value)
}

private func isoString(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.string(from: date)
}

private func numericPostId(_ value: String?) -> Int64? {
  guard let value, value.allSatisfy(\.isNumber) else {
    return nil
  }
  return Int64(value)
}

private func object(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}

private func array(_ value: JSONValue?) -> [JSONValue]? {
  guard case let .array(array)? = value else {
    return nil
  }
  return array
}

private func bool(_ value: JSONValue?) -> Bool? {
  guard case let .bool(value)? = value else {
    return nil
  }
  return value
}

private func string(_ value: JSONValue?) -> String? {
  guard case let .string(value)? = value else {
    return nil
  }
  return value
}

private func numberValue(_ value: JSONValue?) -> Double? {
  guard case let .number(value)? = value else {
    return nil
  }
  return value
}

private extension JSONValue {
  func value(at path: [String]) -> JSONValue? {
    var current: JSONValue = self
    for component in path {
      guard case let .object(object) = current, let next = object[component] else {
        return nil
      }
      current = next
    }
    return current
  }
}

private extension JSONObject {
  func value(at path: [String]) -> JSONValue? {
    guard let first = path.first, let value = self[first] else {
      return nil
    }
    return value.value(at: Array(path.dropFirst()))
  }
}

private extension JSONEncoder {
  static var prettySorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

private extension String {
  func trimmingPrefix(_ prefix: String) -> String {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
  }
}
