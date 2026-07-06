import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore

public struct OfficialSDKStreamingHTTPResponse: Sendable {
  public var statusCode: Int
  public var headers: [String: String]
  public var body: AsyncThrowingStream<Data, Error>

  public init(statusCode: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, Error>) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }
}

public protocol OfficialSDKStreamingHTTPTransporting: Sendable {
  func bytes(for request: URLRequest) async throws -> OfficialSDKStreamingHTTPResponse
}

public struct URLSessionOfficialSDKStreamingTransport: OfficialSDKStreamingHTTPTransporting {
  public init() {}

  public func bytes(for request: URLRequest) async throws -> OfficialSDKStreamingHTTPResponse {
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AdapterExecutionError(.providerError, "official SDK stream did not return an HTTP response")
    }
    let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
      guard let key = entry.key as? String else {
        return
      }
      result[key] = String(describing: entry.value)
    }
    let stream = AsyncThrowingStream<Data, Error> { continuation in
      Task {
        do {
          var buffer = Data()
          buffer.reserveCapacity(1024)
          for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1024 {
              continuation.yield(buffer)
              buffer.removeAll(keepingCapacity: true)
            }
          }
          if !buffer.isEmpty {
            continuation.yield(buffer)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
    return OfficialSDKStreamingHTTPResponse(statusCode: httpResponse.statusCode, headers: headers, body: stream)
  }
}

func executeOfficialSDKStream(
  request: OfficialSDKRequest,
  context: AdapterExecutionContext,
  configuration: OfficialSDKAdapterConfiguration,
  transport: any OfficialSDKStreamingHTTPTransporting,
  parsingOptions: OfficialSDKParsingOptions
) async throws -> OfficialSDKDecodedResponse {
  let urlRequest = applyOfficialSDKRequestMiddleware(
    try makeURLRequest(
      for: request,
      context: context,
      customHeaders: configuration.customHeaders,
      timeout: configuration.timeout,
      streaming: true
    ),
    middlewares: configuration.middlewares
  )
  let response = try await transport.bytes(for: urlRequest)
  guard (200...299).contains(response.statusCode) else {
    let body = try await collectOfficialSDKStreamData(response.body, middlewares: configuration.middlewares)
    throw decodeOfficialSDKAPIError(
      provider: request.provider,
      statusCode: response.statusCode,
      headers: response.headers,
      body: body,
      sensitiveValues: [request.apiKey]
    )
    .adapterError
  }

  let parser = ServerSentEventsParser()
  var interpreter = makeOfficialSDKStreamInterpreter(provider: request.provider, parsingOptions: parsingOptions)
  for try await rawChunk in response.body {
    let chunk = configuration.middlewares.reduce(rawChunk) { current, middleware in
      middleware.interceptStreamChunk(current)
    }
    for event in parser.feed(chunk) {
      try await emitOfficialSDKStreamEvents(
        try interpreter.interpret(event),
        context: context,
        sensitiveValues: [request.apiKey]
      )
    }
  }
  for event in parser.finish() {
    try await emitOfficialSDKStreamEvents(
      try interpreter.interpret(event),
      context: context,
      sensitiveValues: [request.apiKey]
    )
  }
  return try interpreter.finalize()
}

private func collectOfficialSDKStreamData(
  _ stream: AsyncThrowingStream<Data, Error>,
  middlewares: [any OfficialSDKMiddleware]
) async throws -> Data {
  var body = Data()
  for try await rawChunk in stream {
    let chunk = middlewares.reduce(rawChunk) { current, middleware in
      middleware.interceptStreamChunk(current)
    }
    body.append(chunk)
  }
  return body
}

private func emitOfficialSDKStreamEvents(
  _ events: [AdapterBackendEvent],
  context: AdapterExecutionContext,
  sensitiveValues: [String]
) async throws {
  for event in events {
    var event = event
    if let contentDelta = event.contentDelta {
      event.contentDelta = redactOfficialSDKSensitiveText(contentDelta, sensitiveValues: sensitiveValues)
    }
    if let contentSnapshot = event.contentSnapshot {
      event.contentSnapshot = redactOfficialSDKSensitiveText(contentSnapshot, sensitiveValues: sensitiveValues)
    }
    await context.backendEventHandler?(event)
  }
}

private protocol OfficialSDKStreamInterpreting {
  mutating func interpret(_ event: ServerSentEvent) throws -> [AdapterBackendEvent]
  func finalize() throws -> OfficialSDKDecodedResponse
}

private func makeOfficialSDKStreamInterpreter(
  provider: String,
  parsingOptions: OfficialSDKParsingOptions
) -> any OfficialSDKStreamInterpreting {
  switch provider {
  case OpenAiSDKAdapter.provider:
    return OpenAIResponsesStreamInterpreter(parsingOptions: parsingOptions)
  case AnthropicSDKAdapter.provider:
    return AnthropicMessagesStreamInterpreter()
  case GeminiSDKAdapter.provider:
    return GeminiStreamInterpreter(parsingOptions: parsingOptions)
  default:
    return GenericOfficialSDKStreamInterpreter(provider: provider)
  }
}

private struct OpenAIResponsesStreamInterpreter: OfficialSDKStreamInterpreting {
  var parsingOptions: OfficialSDKParsingOptions
  var textSegments: [String] = []
  var completedResponse: JSONValue?
  var usage: AdapterUsage?

  mutating func interpret(_ event: ServerSentEvent) throws -> [AdapterBackendEvent] {
    guard event.data != "[DONE]" else {
      return []
    }
    let raw = try decodeStreamJSON(event.data)
    try throwIfStreamError(provider: OpenAiSDKAdapter.provider, raw: raw, eventType: event.event)
    guard case let .object(object) = raw else {
      return [lifecycleEvent(provider: OpenAiSDKAdapter.provider, eventType: event.event ?? "message", raw: raw)]
    }
    let type = streamString(object["type"]) ?? event.event ?? "message"
    switch type {
    case "response.output_text.delta":
      guard let delta = streamString(object["delta"]), !delta.isEmpty else {
        return []
      }
      textSegments.append(delta)
      return [AdapterBackendEvent(
        provider: OpenAiSDKAdapter.provider,
        eventType: type,
        channel: .assistant,
        contentDelta: delta,
        isDelta: true
      )]
    case "response.completed":
      let response = object["response"] ?? raw
      completedResponse = response
      usage = (try? decodeOfficialSDKResponse(
        provider: OpenAiSDKAdapter.provider,
        raw: response,
        options: parsingOptions
      ))?.usage
      if let usage {
        return [usageEvent(provider: OpenAiSDKAdapter.provider, eventType: type, usage: usage)]
      }
      return []
    case "response.failed":
      throw AdapterExecutionError(.providerError, streamErrorMessage(provider: OpenAiSDKAdapter.provider, raw: raw), isRetryable: false)
    default:
      return [lifecycleEvent(provider: OpenAiSDKAdapter.provider, eventType: type, raw: raw)]
    }
  }

  func finalize() throws -> OfficialSDKDecodedResponse {
    if !textSegments.isEmpty {
      return OfficialSDKDecodedResponse(text: textSegments.joined(), usage: usage, raw: completedResponse ?? .object([:]))
    }
    if let completedResponse {
      return try decodeOfficialSDKResponse(provider: OpenAiSDKAdapter.provider, raw: completedResponse, options: parsingOptions)
    }
    return OfficialSDKDecodedResponse(text: "", usage: usage, raw: .object([:]))
  }
}

private struct AnthropicMessagesStreamInterpreter: OfficialSDKStreamInterpreting {
  var textSegments: [String] = []
  var thinkingSegments: [String] = []
  var inputTokens: Int?
  var outputTokens: Int?
  var cacheReadInputTokens: Int?
  var cacheCreationInputTokens: Int?
  var usageRaw: JSONObject = [:]
  var lastRaw: JSONValue = .object([:])

  mutating func interpret(_ event: ServerSentEvent) throws -> [AdapterBackendEvent] {
    let raw = try decodeStreamJSON(event.data)
    try throwIfStreamError(provider: AnthropicSDKAdapter.provider, raw: raw, eventType: event.event)
    lastRaw = raw
    guard case let .object(object) = raw else {
      return [lifecycleEvent(provider: AnthropicSDKAdapter.provider, eventType: event.event ?? "message", raw: raw)]
    }
    let type = streamString(object["type"]) ?? event.event ?? "message"
    switch type {
    case "message_start":
      if let usage = nestedObject(object["message"], key: "usage") {
        mergeAnthropicUsage(usage)
      }
      return [lifecycleEvent(provider: AnthropicSDKAdapter.provider, eventType: type, raw: raw)]
    case "content_block_delta":
      guard let delta = nestedObject(raw, key: "delta"),
            let deltaType = streamString(delta["type"]) else {
        return []
      }
      if deltaType == "text_delta", let text = streamString(delta["text"]), !text.isEmpty {
        textSegments.append(text)
        return [AdapterBackendEvent(
          provider: AnthropicSDKAdapter.provider,
          eventType: type,
          channel: .assistant,
          contentDelta: text,
          isDelta: true
        )]
      }
      if deltaType == "thinking_delta", let thinking = streamString(delta["thinking"]), !thinking.isEmpty {
        thinkingSegments.append(thinking)
        return [AdapterBackendEvent(
          provider: AnthropicSDKAdapter.provider,
          eventType: type,
          channel: .thinking,
          contentDelta: thinking,
          isDelta: true
        )]
      }
      return [lifecycleEvent(provider: AnthropicSDKAdapter.provider, eventType: type, raw: raw)]
    case "message_delta":
      if let usage = nestedObject(raw, key: "usage") {
        mergeAnthropicUsage(usage)
        if let adapterUsage = adapterUsage(raw: usage) {
          return [usageEvent(provider: AnthropicSDKAdapter.provider, eventType: type, usage: adapterUsage)]
        }
        return []
      }
      return []
    default:
      return [lifecycleEvent(provider: AnthropicSDKAdapter.provider, eventType: type, raw: raw)]
    }
  }

  func finalize() throws -> OfficialSDKDecodedResponse {
    OfficialSDKDecodedResponse(text: textSegments.joined(), usage: adapterUsage(raw: nil), raw: lastRaw)
  }

  private mutating func mergeAnthropicUsage(_ usage: JSONObject) {
    inputTokens = streamInt(usage["input_tokens"]) ?? inputTokens
    outputTokens = streamInt(usage["output_tokens"]) ?? outputTokens
    cacheReadInputTokens = streamInt(usage["cache_read_input_tokens"]) ?? cacheReadInputTokens
    cacheCreationInputTokens = streamInt(usage["cache_creation_input_tokens"]) ?? cacheCreationInputTokens
    usageRaw = usage
  }

  private func adapterUsage(raw: JSONObject?) -> AdapterUsage? {
    guard inputTokens != nil || outputTokens != nil || cacheReadInputTokens != nil || cacheCreationInputTokens != nil else {
      return nil
    }
    return AdapterUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadInputTokens: cacheReadInputTokens,
      cacheCreationInputTokens: cacheCreationInputTokens,
      providerRaw: raw ?? usageRaw
    )
  }
}

private struct GeminiStreamInterpreter: OfficialSDKStreamInterpreting {
  var parsingOptions: OfficialSDKParsingOptions
  var textSegments: [String] = []
  var usage: AdapterUsage?
  var lastRaw: JSONValue = .object([:])

  mutating func interpret(_ event: ServerSentEvent) throws -> [AdapterBackendEvent] {
    let raw = try decodeStreamJSON(event.data)
    try throwIfStreamError(provider: GeminiSDKAdapter.provider, raw: raw, eventType: event.event)
    lastRaw = raw
    let decoded = try decodeOfficialSDKResponse(provider: GeminiSDKAdapter.provider, raw: raw, options: parsingOptions)
    usage = decoded.usage ?? usage
    var events: [AdapterBackendEvent] = []
    if !decoded.text.isEmpty {
      textSegments.append(decoded.text)
      events.append(AdapterBackendEvent(
        provider: GeminiSDKAdapter.provider,
        eventType: event.event ?? "message",
        channel: .assistant,
        contentDelta: decoded.text,
        isDelta: true
      ))
    }
    if let usage = decoded.usage {
      events.append(usageEvent(provider: GeminiSDKAdapter.provider, eventType: event.event ?? "message", usage: usage))
    }
    if events.isEmpty {
      events.append(lifecycleEvent(provider: GeminiSDKAdapter.provider, eventType: event.event ?? "message", raw: raw))
    }
    return events
  }

  func finalize() throws -> OfficialSDKDecodedResponse {
    OfficialSDKDecodedResponse(text: textSegments.joined(), usage: usage, raw: lastRaw)
  }
}

private struct GenericOfficialSDKStreamInterpreter: OfficialSDKStreamInterpreting {
  var provider: String
  var lastRaw: JSONValue = .object([:])

  mutating func interpret(_ event: ServerSentEvent) throws -> [AdapterBackendEvent] {
    let raw = try decodeStreamJSON(event.data)
    lastRaw = raw
    return [lifecycleEvent(provider: provider, eventType: event.event ?? "message", raw: raw)]
  }

  func finalize() throws -> OfficialSDKDecodedResponse {
    OfficialSDKDecodedResponse(text: "", raw: lastRaw)
  }
}

private func decodeStreamJSON(_ data: String) throws -> JSONValue {
  guard let bytes = data.data(using: .utf8) else {
    throw AdapterExecutionError(.providerError, "official SDK stream event was not UTF-8")
  }
  return try JSONDecoder().decode(JSONValue.self, from: bytes)
}

private func throwIfStreamError(provider: String, raw: JSONValue, eventType: String?) throws {
  guard case let .object(object) = raw else {
    return
  }
  if object["error"] != nil || eventType == "error" {
    throw AdapterExecutionError(.providerError, streamErrorMessage(provider: provider, raw: raw), isRetryable: false)
  }
}

private func streamErrorMessage(provider: String, raw: JSONValue) -> String {
  if let error = nestedObject(raw, key: "error"),
     let message = streamString(error["message"]) ?? streamString(error["type"]) ?? streamString(error["status"]) {
    return "\(provider) stream error: \(message)"
  }
  if let message = streamString(nestedValue(raw, path: ["response", "error", "message"])) {
    return "\(provider) stream error: \(message)"
  }
  return "\(provider) stream error"
}

private func usageEvent(provider: String, eventType: String, usage: AdapterUsage) -> AdapterBackendEvent {
  AdapterBackendEvent(provider: provider, eventType: eventType, channel: .usage, usage: usage.eventPayload)
}

private func lifecycleEvent(provider: String, eventType: String, raw: JSONValue) -> AdapterBackendEvent {
  AdapterBackendEvent(provider: provider, eventType: eventType, channel: .lifecycle)
}

private func nestedObject(_ value: JSONValue?, key: String) -> JSONObject? {
  guard case let .object(object) = value,
        case let .object(nested)? = object[key] else {
    return nil
  }
  return nested
}

private func nestedValue(_ value: JSONValue, path: [String]) -> JSONValue? {
  var current: JSONValue? = value
  for key in path {
    guard case let .object(object) = current else {
      return nil
    }
    current = object[key]
  }
  return current
}

private func streamString(_ value: JSONValue?) -> String? {
  guard case let .string(value) = value else {
    return nil
  }
  return value
}

private func streamInt(_ value: JSONValue?) -> Int? {
  guard let int64 = value?.asInt64 else {
    return nil
  }
  return Int(int64)
}
