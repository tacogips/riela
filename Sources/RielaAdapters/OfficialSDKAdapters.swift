import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore

public struct OfficialSDKAdapterConfiguration: Sendable {
  public static let defaultRetryPolicy = RetryPolicy(
    maxAttempts: 3,
    retryDelay: .milliseconds(500),
    backoffMultiplier: 2.0,
    useJitter: true
  )

  public var apiKeyEnv: String?
  public var baseURL: URL?
  public var retryPolicy: RetryPolicy
  public var environment: [String: String]?
  public var requestExecutor: (any OfficialSDKRequestExecuting)?
  public var httpTransport: (any OfficialSDKHTTPTransporting)?
  public var customHeaders: [String: String]
  public var timeout: Duration?
  public var middlewares: [any OfficialSDKMiddleware]
  public var parsingOptions: OfficialSDKParsingOptions
  public var streamingTransport: (any OfficialSDKStreamingHTTPTransporting)?

  public init(
    apiKeyEnv: String? = nil,
    baseURL: URL? = nil,
    retryPolicy: RetryPolicy = OfficialSDKAdapterConfiguration.defaultRetryPolicy,
    environment: [String: String]? = nil,
    requestExecutor: (any OfficialSDKRequestExecuting)? = nil,
    httpTransport: (any OfficialSDKHTTPTransporting)? = nil,
    customHeaders: [String: String] = [:],
    timeout: Duration? = nil,
    middlewares: [any OfficialSDKMiddleware] = [],
    parsingOptions: OfficialSDKParsingOptions = [],
    streamingTransport: (any OfficialSDKStreamingHTTPTransporting)? = nil
  ) {
    self.apiKeyEnv = apiKeyEnv
    self.baseURL = baseURL
    self.retryPolicy = retryPolicy
    self.environment = environment
    self.requestExecutor = requestExecutor
    self.httpTransport = httpTransport
    self.customHeaders = customHeaders
    self.timeout = timeout
    self.middlewares = middlewares
    self.parsingOptions = parsingOptions
    self.streamingTransport = streamingTransport
  }
}

public struct AnthropicSDKAdapterConfiguration: Sendable {
  public var officialSDK: OfficialSDKAdapterConfiguration
  public var maxTokens: Int

  public init(
    officialSDK: OfficialSDKAdapterConfiguration = OfficialSDKAdapterConfiguration(),
    maxTokens: Int = 1024
  ) {
    self.officialSDK = officialSDK
    self.maxTokens = max(1, maxTokens)
  }
}

public protocol OfficialSDKRequestExecuting: Sendable {
  func executeSDKRequest(_ request: OfficialSDKRequest, context: AdapterExecutionContext) async throws -> OfficialSDKResponse
}

public protocol OfficialSDKHTTPTransporting: Sendable {
  func data(for request: URLRequest) async throws -> OfficialSDKHTTPResponse
}

public struct OfficialSDKRequest: Equatable, Sendable {
  public var provider: String
  public var apiKey: String
  public var baseURL: URL?
  public var body: OfficialSDKRequestBody

  public init(provider: String, apiKey: String, baseURL: URL? = nil, body: OfficialSDKRequestBody) {
    self.provider = provider
    self.apiKey = apiKey
    self.baseURL = baseURL
    self.body = body
  }
}

public enum OfficialSDKRequestBody: Equatable, Sendable {
  case openAIResponses(OpenAIResponsesRequest)
  case anthropicMessages(AnthropicMessagesRequest)
  case geminiGenerateContent(GeminiGenerateContentRequest)
  case cursorCreateAgent(CursorAgentRequest)
}

public struct OpenAIResponsesRequest: Equatable, Sendable {
  public var model: String
  public var input: String
  public var instructions: String?
  public var imageInputs: [OpenAIImageInput]

  public init(
    model: String,
    input: String,
    instructions: String? = nil,
    imageInputs: [OpenAIImageInput] = []
  ) {
    self.model = model
    self.input = input
    self.instructions = instructions
    self.imageInputs = imageInputs
  }
}

public struct OpenAIImageInput: Equatable, Sendable {
  public var mimeType: String
  public var dataBase64: String

  public init(mimeType: String, dataBase64: String) {
    self.mimeType = mimeType
    self.dataBase64 = dataBase64
  }

  public var dataURL: String {
    "data:\(mimeType);base64,\(dataBase64)"
  }
}

public struct AnthropicMessagesRequest: Equatable, Sendable {
  public var model: String
  public var maxTokens: Int
  public var system: String?
  public var messages: [AnthropicMessage]
  public var imageInputs: [AnthropicImageInput]

  public init(
    model: String,
    maxTokens: Int,
    system: String? = nil,
    messages: [AnthropicMessage],
    imageInputs: [AnthropicImageInput] = []
  ) {
    self.model = model
    self.maxTokens = max(1, maxTokens)
    self.system = system
    self.messages = messages
    self.imageInputs = imageInputs
  }
}

public struct AnthropicMessage: Equatable, Sendable {
  public var role: String
  public var content: String

  public init(role: String, content: String) {
    self.role = role
    self.content = content
  }
}

public struct AnthropicImageInput: Equatable, Sendable {
  public var mimeType: String
  public var dataBase64: String

  public init(mimeType: String, dataBase64: String) {
    self.mimeType = mimeType
    self.dataBase64 = dataBase64
  }
}

public struct GeminiGenerateContentRequest: Equatable, Sendable {
  public var model: String
  public var input: String
  public var system: String?
  public var inlineDataParts: [GeminiInlineDataPart]

  public init(
    model: String,
    input: String,
    system: String? = nil,
    inlineDataParts: [GeminiInlineDataPart] = []
  ) {
    self.model = model
    self.input = input
    self.system = system
    self.inlineDataParts = inlineDataParts
  }
}

public struct GeminiInlineDataPart: Equatable, Sendable {
  public var mimeType: String
  public var dataBase64: String

  public init(mimeType: String, dataBase64: String) {
    self.mimeType = mimeType
    self.dataBase64 = dataBase64
  }
}

public struct CursorAgentRequest: Equatable, Sendable {
  public var model: String
  public var prompt: String
  public var repositoryURL: String?
  public var startingRef: String?
  public var workOnCurrentBranch: Bool?
  public var autoCreatePR: Bool?

  public init(
    model: String,
    prompt: String,
    repositoryURL: String? = nil,
    startingRef: String? = nil,
    workOnCurrentBranch: Bool? = nil,
    autoCreatePR: Bool? = nil
  ) {
    self.model = model
    self.prompt = prompt
    self.repositoryURL = repositoryURL
    self.startingRef = startingRef
    self.workOnCurrentBranch = workOnCurrentBranch
    self.autoCreatePR = autoCreatePR
  }
}

public struct OfficialSDKResponse: Equatable, Sendable {
  public var body: JSONValue
  public var usage: AdapterUsage?

  public init(body: JSONValue, usage: AdapterUsage? = nil) {
    self.body = body
    self.usage = usage
  }
}

public struct OfficialSDKHTTPResponse: Equatable, Sendable {
  public var statusCode: Int
  public var body: Data
  public var headers: [String: String]

  public init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
    self.statusCode = statusCode
    self.body = body
    self.headers = headers
  }
}

public struct URLSessionOfficialSDKHTTPTransport: OfficialSDKHTTPTransporting {
  public init() {}

  public func data(for request: URLRequest) async throws -> OfficialSDKHTTPResponse {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AdapterExecutionError(.providerError, "official SDK request did not return an HTTP response")
    }
    let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
      guard let key = entry.key as? String else {
        return
      }
      result[key] = String(describing: entry.value)
    }
    return OfficialSDKHTTPResponse(statusCode: httpResponse.statusCode, body: data, headers: headers)
  }
}

public struct URLSessionOfficialSDKRequestExecutor: OfficialSDKRequestExecuting {
  public var transport: any OfficialSDKHTTPTransporting
  public var customHeaders: [String: String]
  public var timeout: Duration?
  public var middlewares: [any OfficialSDKMiddleware]
  public var parsingOptions: OfficialSDKParsingOptions

  public init(
    transport: any OfficialSDKHTTPTransporting = URLSessionOfficialSDKHTTPTransport(),
    customHeaders: [String: String] = [:],
    timeout: Duration? = nil,
    middlewares: [any OfficialSDKMiddleware] = [],
    parsingOptions: OfficialSDKParsingOptions = []
  ) {
    self.transport = transport
    self.customHeaders = customHeaders
    self.timeout = timeout
    self.middlewares = middlewares
    self.parsingOptions = parsingOptions
  }

  public func executeSDKRequest(_ request: OfficialSDKRequest, context: AdapterExecutionContext) async throws -> OfficialSDKResponse {
    let urlRequest = applyOfficialSDKRequestMiddleware(
      try makeURLRequest(for: request, context: context, customHeaders: customHeaders, timeout: timeout),
      middlewares: middlewares
    )
    let rawResponse = try await transport.data(for: urlRequest)
    let response = applyOfficialSDKResponseMiddleware(rawResponse, request: urlRequest, middlewares: middlewares)
    guard (200...299).contains(response.statusCode) else {
      throw decodeOfficialSDKAPIError(
        provider: request.provider,
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.body,
        sensitiveValues: [request.apiKey]
      )
      .adapterError
    }

    let decoded = try decodeOfficialSDKResponseForAdapter(
      provider: request.provider,
      data: response.body,
      options: parsingOptions
    )
    return OfficialSDKResponse(
      body: decoded.raw,
      usage: decoded.usage
    )
  }
}

public struct OpenAiSDKAdapter: NodeAdapter {
  public static let provider = "official-openai-sdk"
  private static let defaultApiKeyEnv = "OPENAI_API_KEY"

  public var configuration: OfficialSDKAdapterConfiguration

  public init(configuration: OfficialSDKAdapterConfiguration = OfficialSDKAdapterConfiguration()) {
    self.configuration = configuration
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let request = try makeOfficialSDKRequest(
      input: input,
      provider: Self.provider,
      configuration: configuration,
      defaultApiKeyEnv: Self.defaultApiKeyEnv,
      defaultBaseURLEnv: "OPENAI_BASE_URL",
      missingApiKeyMessage: "missing OpenAI API key",
      body: .openAIResponses(
        OpenAIResponsesRequest(
          model: input.node.model,
          input: input.promptText,
          instructions: input.systemPromptText,
          imageInputs: try openAIImageInputs(from: input)
        )
      )
    )

    return try await executeOfficialSDKRequest(
      adapterInput: input,
      context: context,
      configuration: configuration,
      request: request,
      responseLabel: "official OpenAI SDK response",
      timeoutMessage: "official OpenAI SDK request aborted",
      fallbackFailureMessage: "unknown OpenAI SDK failure"
    )
  }
}

public struct AnthropicSDKAdapter: NodeAdapter {
  public static let provider = "official-anthropic-sdk"
  private static let defaultApiKeyEnv = "ANTHROPIC_API_KEY"

  public var configuration: AnthropicSDKAdapterConfiguration

  public init(configuration: AnthropicSDKAdapterConfiguration = AnthropicSDKAdapterConfiguration()) {
    self.configuration = configuration
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let request = try makeOfficialSDKRequest(
      input: input,
      provider: Self.provider,
      configuration: configuration.officialSDK,
      defaultApiKeyEnv: Self.defaultApiKeyEnv,
      defaultBaseURLEnv: "ANTHROPIC_BASE_URL",
      missingApiKeyMessage: "missing Anthropic API key",
      body: .anthropicMessages(
        AnthropicMessagesRequest(
          model: input.node.model,
          maxTokens: configuration.maxTokens,
          system: input.systemPromptText,
          messages: [AnthropicMessage(role: "user", content: input.promptText)],
          imageInputs: try anthropicImageInputs(from: input)
        )
      )
    )

    return try await executeOfficialSDKRequest(
      adapterInput: input,
      context: context,
      configuration: configuration.officialSDK,
      request: request,
      responseLabel: "official Anthropic SDK response",
      timeoutMessage: "official Anthropic SDK request aborted",
      fallbackFailureMessage: "unknown Anthropic SDK failure"
    )
  }
}

public struct GeminiSDKAdapter: NodeAdapter {
  public static let provider = "official-gemini-sdk"
  private static let defaultApiKeyEnvs = ["GOOGLE_API_KEY", "GEMINI_API_KEY"]

  public var configuration: OfficialSDKAdapterConfiguration

  public init(configuration: OfficialSDKAdapterConfiguration = OfficialSDKAdapterConfiguration()) {
    self.configuration = configuration
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let request = try makeOfficialSDKRequest(
      input: input,
      provider: Self.provider,
      configuration: configuration,
      defaultApiKeyEnvs: Self.defaultApiKeyEnvs,
      defaultBaseURLEnvs: ["GEMINI_BASE_URL"],
      missingApiKeyMessage: "missing Gemini API key",
      body: .geminiGenerateContent(
        GeminiGenerateContentRequest(
          model: input.node.model,
          input: input.promptText,
          system: input.systemPromptText,
          inlineDataParts: try geminiInlineDataParts(from: input) + geminiInlineDataPartsFromImagePaths(input)
        )
      )
    )

    return try await executeOfficialSDKRequest(
      adapterInput: input,
      context: context,
      configuration: configuration,
      request: request,
      responseLabel: "official Gemini SDK response",
      timeoutMessage: "official Gemini SDK request aborted",
      fallbackFailureMessage: "unknown Gemini SDK failure"
    )
  }
}

public struct CursorSDKAdapter: NodeAdapter {
  public static let provider = "official-cursor-sdk"
  private static let defaultApiKeyEnv = "CURSOR_API_KEY"

  public var configuration: OfficialSDKAdapterConfiguration

  public init(configuration: OfficialSDKAdapterConfiguration = OfficialSDKAdapterConfiguration()) {
    self.configuration = configuration
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let request = try makeOfficialSDKRequest(
      input: input,
      provider: Self.provider,
      configuration: configuration,
      defaultApiKeyEnv: Self.defaultApiKeyEnv,
      defaultBaseURLEnv: "CURSOR_BASE_URL",
      missingApiKeyMessage: "missing Cursor API key",
      body: .cursorCreateAgent(cursorAgentRequest(from: input))
    )

    return try await executeOfficialSDKRequest(
      adapterInput: input,
      context: context,
      configuration: configuration,
      request: request,
      responseLabel: "official Cursor SDK response",
      timeoutMessage: "official Cursor SDK request aborted",
      fallbackFailureMessage: "unknown Cursor SDK failure"
    )
  }
}

private func makeOfficialSDKRequest(
  input: AdapterExecutionInput,
  provider: String,
  configuration: OfficialSDKAdapterConfiguration,
  defaultApiKeyEnv: String,
  defaultBaseURLEnv: String,
  missingApiKeyMessage: String,
  body: OfficialSDKRequestBody
) throws -> OfficialSDKRequest {
  try makeOfficialSDKRequest(
    input: input,
    provider: provider,
    configuration: configuration,
    defaultApiKeyEnvs: [defaultApiKeyEnv],
    defaultBaseURLEnvs: [defaultBaseURLEnv],
    missingApiKeyMessage: missingApiKeyMessage,
    body: body
  )
}

private func makeOfficialSDKRequest(
  input: AdapterExecutionInput,
  provider: String,
  configuration: OfficialSDKAdapterConfiguration,
  defaultApiKeyEnvs: [String],
  defaultBaseURLEnvs: [String],
  missingApiKeyMessage: String,
  body: OfficialSDKRequestBody
) throws -> OfficialSDKRequest {
  let environment = (configuration.environment ?? ProcessInfo.processInfo.environment)
    .merging(input.agentEnvironment) { _, nodeValue in nodeValue }
  let envNames = configuration.apiKeyEnv.map { [$0] } ?? defaultApiKeyEnvs
  guard let apiKey = envNames.compactMap({ environment[$0] }).first(where: { !$0.isEmpty }) else {
    throw AdapterExecutionError(.policyBlocked, missingApiKeyMessage)
  }
  let baseURL = configuration.baseURL ?? defaultBaseURLEnvs
    .compactMap { environment[$0] }
    .first(where: { !$0.isEmpty })
    .flatMap(URL.init(string:))

  return OfficialSDKRequest(
    provider: provider,
    apiKey: apiKey,
    baseURL: baseURL,
    body: body
  )
}

private func executeOfficialSDKRequest(
  adapterInput: AdapterExecutionInput,
  context: AdapterExecutionContext,
  configuration: OfficialSDKAdapterConfiguration,
  request: OfficialSDKRequest,
  responseLabel: String,
  timeoutMessage: String,
  fallbackFailureMessage: String
) async throws -> AdapterExecutionOutput {
  let parsingOptions = effectiveOfficialSDKParsingOptions(configuration: configuration, input: adapterInput, request: request)
  let usageEmissionTracker = OfficialSDKUsageEmissionTracker()
  let streamingContext = AdapterExecutionContext(
    deadline: context.deadline,
    backendEventHandler: { event in
      if event.channel == .usage {
        usageEmissionTracker.markEmitted()
      }
      await context.backendEventHandler?(event)
    }
  )
  let decoded: OfficialSDKDecodedResponse
  let usage: AdapterUsage?
  if shouldStreamOfficialSDKResponse(configuration: configuration, input: adapterInput, request: request),
     let streamingTransport = effectiveOfficialSDKStreamingTransport(configuration) {
    do {
      decoded = try await executeOfficialSDKStreamingRequest(
        context: streamingContext,
        configuration: configuration,
        request: request,
        streamingTransport: streamingTransport,
        parsingOptions: parsingOptions,
        timeoutMessage: timeoutMessage,
        fallbackFailureMessage: fallbackFailureMessage
      )
      usage = nil
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AdapterExecutionError where error.isRetryable == false {
      throw error
    } catch {
      if let adapterError = error as? AdapterExecutionError,
         let retryAfter = adapterError.retryAfter {
        try await sleepBeforeOfficialSDKFallback(retryAfter: retryAfter, deadline: context.deadline)
      }
      // Streamed deltas are observational only. If the stream fails, retry once
      // through the blocking path so the final adapter output contract remains
      // identical to pre-streaming behavior.
      let response = try await executeOfficialSDKBlockingRequest(
        context: context,
        configuration: configuration,
        request: request,
        parsingOptions: parsingOptions,
        retryPolicy: RetryPolicy(maxAttempts: 1, retryDelay: .zero),
        timeoutMessage: timeoutMessage,
        fallbackFailureMessage: fallbackFailureMessage
      )
      decoded = response.decoded
      usage = response.usage
    }
  } else {
    let response = try await executeOfficialSDKBlockingRequest(
      context: context,
      configuration: configuration,
      request: request,
      parsingOptions: parsingOptions,
      retryPolicy: configuration.retryPolicy,
      timeoutMessage: timeoutMessage,
      fallbackFailureMessage: fallbackFailureMessage
    )
    decoded = response.decoded
    usage = response.usage
  }

  let effectiveUsage = usage ?? decoded.usage
  if let effectiveUsage, !usageEmissionTracker.didEmitUsage() {
    await context.backendEventHandler?(AdapterBackendEvent(
      provider: request.provider,
      eventType: "response.usage",
      channel: .usage,
      usage: effectiveUsage.eventPayload
    ))
  }

  return try makeOfficialSDKAdapterOutput(
    adapterInput: adapterInput,
    request: request,
    decoded: decoded,
    usage: effectiveUsage,
    responseLabel: responseLabel
  )
}

private struct OfficialSDKBlockingResponse: Sendable {
  var decoded: OfficialSDKDecodedResponse
  var usage: AdapterUsage?
}

private func executeOfficialSDKBlockingRequest(
  context: AdapterExecutionContext,
  configuration: OfficialSDKAdapterConfiguration,
  request: OfficialSDKRequest,
  parsingOptions: OfficialSDKParsingOptions,
  retryPolicy: RetryPolicy,
  timeoutMessage: String,
  fallbackFailureMessage: String
) async throws -> OfficialSDKBlockingResponse {
  let executor = configuration.requestExecutor ?? URLSessionOfficialSDKRequestExecutor(
    transport: configuration.httpTransport ?? URLSessionOfficialSDKHTTPTransport(),
    customHeaders: configuration.customHeaders,
    timeout: configuration.timeout,
    middlewares: configuration.middlewares,
    parsingOptions: parsingOptions
  )
  let response = try await retryOfficialSDKRequest(
    policy: retryPolicy,
    deadline: context.deadline,
    timeoutMessage: timeoutMessage,
    fallbackFailureMessage: fallbackFailureMessage,
    sensitiveValues: [request.apiKey]
  ) {
    try await executor.executeSDKRequest(request, context: context)
  }

  let decoded = try decodeOfficialSDKResponseForAdapter(
    provider: request.provider,
    raw: response.body,
    options: parsingOptions
  )
  return OfficialSDKBlockingResponse(decoded: decoded, usage: response.usage)
}

private func makeOfficialSDKAdapterOutput(
  adapterInput: AdapterExecutionInput,
  request: OfficialSDKRequest,
  decoded: OfficialSDKDecodedResponse,
  usage: AdapterUsage?,
  responseLabel: String
) throws -> AdapterExecutionOutput {
  let normalized: OutputContractEnvelopeNormalization
  if adapterInput.node.output == nil {
    normalized = OutputContractEnvelopeNormalization(
      completionPassed: true,
      when: ["always": true],
      payload: normalizeTextBusinessPayload(decoded.text),
      usedEnvelope: false
    )
  } else {
    normalized = try normalizeOutputContractEnvelope(
      parseJSONObjectCandidate(decoded.text, source: responseLabel),
      source: responseLabel
    )
  }

  return AdapterExecutionOutput(
    provider: request.provider,
    model: adapterInput.node.model,
    promptText: adapterInput.promptText,
    completionPassed: normalized.completionPassed,
    when: normalized.when,
    payload: normalized.payload,
    usage: usage
  )
}

private func executeOfficialSDKStreamingRequest(
  context: AdapterExecutionContext,
  configuration: OfficialSDKAdapterConfiguration,
  request: OfficialSDKRequest,
  streamingTransport: any OfficialSDKStreamingHTTPTransporting,
  parsingOptions: OfficialSDKParsingOptions,
  timeoutMessage: String,
  fallbackFailureMessage: String
) async throws -> OfficialSDKDecodedResponse {
  try await retryOfficialSDKRequest(
    policy: RetryPolicy(maxAttempts: 1, retryDelay: .zero),
    deadline: context.deadline,
    timeoutMessage: timeoutMessage,
    fallbackFailureMessage: fallbackFailureMessage,
    sensitiveValues: [request.apiKey]
  ) {
    try await executeOfficialSDKStream(
      request: request,
      context: context,
      configuration: configuration,
      transport: streamingTransport,
      parsingOptions: parsingOptions
    )
  }
}

private func shouldStreamOfficialSDKResponse(
  configuration: OfficialSDKAdapterConfiguration,
  input: AdapterExecutionInput,
  request: OfficialSDKRequest
) -> Bool {
  guard effectiveOfficialSDKStreamingTransport(configuration) != nil,
        request.provider != CursorSDKAdapter.provider,
        firstBool(
          input.mergedVariables["streamBackendContent"],
          input.node.variables["streamBackendContent"]
        ) != false else {
    return false
  }
  if isOfficialSDKToggleDisabled(ProcessInfo.processInfo.environment["RIELA_OFFICIAL_SDK_STREAMING"]) {
    return false
  }
  let environment = mergedOfficialSDKEnvironment(configuration: configuration, input: input)
  return !isOfficialSDKToggleDisabled(environment["RIELA_OFFICIAL_SDK_STREAMING"])
}

private func effectiveOfficialSDKStreamingTransport(
  _ configuration: OfficialSDKAdapterConfiguration
) -> (any OfficialSDKStreamingHTTPTransporting)? {
  if let streamingTransport = configuration.streamingTransport {
    return streamingTransport
  }
  guard configuration.requestExecutor == nil, configuration.httpTransport == nil else {
    return nil
  }
  return URLSessionOfficialSDKStreamingTransport()
}

private func effectiveOfficialSDKParsingOptions(
  configuration: OfficialSDKAdapterConfiguration,
  input: AdapterExecutionInput,
  request: OfficialSDKRequest
) -> OfficialSDKParsingOptions {
  var options = configuration.parsingOptions
  let environment = mergedOfficialSDKEnvironment(configuration: configuration, input: input)
  if firstBool(
    input.mergedVariables["officialSDKRelaxedParsing"],
    input.node.variables["officialSDKRelaxedParsing"],
    environment["RIELA_OFFICIAL_SDK_RELAXED_PARSING"].map(JSONValue.string)
  ) == true {
    options.insert(.relaxed)
  }
  if request.provider == OpenAiSDKAdapter.provider,
     let host = request.baseURL?.host?.lowercased(),
     host != "api.openai.com" {
    options.insert(.relaxed)
  }
  return options
}

private func mergedOfficialSDKEnvironment(
  configuration: OfficialSDKAdapterConfiguration,
  input: AdapterExecutionInput
) -> [String: String] {
  ProcessInfo.processInfo.environment
    .merging(configuration.environment ?? [:]) { _, configuredValue in configuredValue }
    .merging(input.agentEnvironment) { _, nodeValue in nodeValue }
}

private func isOfficialSDKToggleDisabled(_ value: String?) -> Bool {
  guard let value else {
    return false
  }
  switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "off", "false", "0", "no":
    return true
  default:
    return false
  }
}

private final class OfficialSDKUsageEmissionTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var emitted = false

  func markEmitted() {
    lock.lock()
    emitted = true
    lock.unlock()
  }

  func didEmitUsage() -> Bool {
    lock.lock()
    let emitted = emitted
    lock.unlock()
    return emitted
  }
}

private func retryOfficialSDKRequest<T: Sendable>(
  policy: RetryPolicy,
  deadline: Date?,
  timeoutMessage: String,
  fallbackFailureMessage: String,
  sensitiveValues: [String],
  operation: @Sendable @escaping () async throws -> T
) async throws -> T {
  try await executeWithRetry(
    policy: policy,
    deadline: deadline,
    operation: {
      try await runWithDeadline(deadline, timeoutMessage: timeoutMessage, operation: operation)
    },
    normalizeError: { error in
      normalizeOfficialSDKFailure(
        error,
        timeoutMessage: timeoutMessage,
        fallbackFailureMessage: fallbackFailureMessage,
        sensitiveValues: sensitiveValues
      )
    }
  )
}

private func runWithDeadline<T: Sendable>(
  _ deadline: Date?,
  timeoutMessage: String,
  operation: @Sendable @escaping () async throws -> T
) async throws -> T {
  guard let deadline else {
    return try await operation()
  }

  let interval = deadline.timeIntervalSinceNow
  guard interval > 0 else {
    throw AdapterExecutionError(.timeout, timeoutMessage)
  }

  return try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      throw AdapterExecutionError(.timeout, timeoutMessage)
    }

    guard let result = try await group.next() else {
      throw AdapterExecutionError(.timeout, timeoutMessage)
    }
    group.cancelAll()
    return result
  }
}

private func normalizeOfficialSDKFailure(
  _ error: Error,
  timeoutMessage: String,
  fallbackFailureMessage: String,
  sensitiveValues: [String]
) -> AdapterExecutionError {
  if let adapterError = error as? AdapterExecutionError {
    let message = adapterError.code == .timeout ? timeoutMessage : adapterError.message
    return AdapterExecutionError(
      adapterError.code,
      redactOfficialSDKSensitiveText(message, sensitiveValues: sensitiveValues),
      isRetryable: adapterError.isRetryable,
      retryAfter: adapterError.retryAfter
    )
  }
  if error is CancellationError {
    return AdapterExecutionError(.timeout, timeoutMessage)
  }
  let normalized = normalizeAdapterFailure(error, fallbackMessage: fallbackFailureMessage)
  return AdapterExecutionError(
    normalized.code,
    redactOfficialSDKSensitiveText(normalized.message, sensitiveValues: sensitiveValues)
  )
}

private func decodeOfficialSDKResponseForAdapter(
  provider: String,
  data: Data,
  options: OfficialSDKParsingOptions
) throws -> OfficialSDKDecodedResponse {
  do {
    return try decodeOfficialSDKResponse(provider: provider, data: data, options: options)
  } catch let error as AdapterExecutionError {
    throw error
  } catch {
    throw AdapterExecutionError(
      .invalidOutput,
      "official SDK \(provider) response did not match expected schema",
      isRetryable: false
    )
  }
}

private func decodeOfficialSDKResponseForAdapter(
  provider: String,
  raw: JSONValue,
  options: OfficialSDKParsingOptions
) throws -> OfficialSDKDecodedResponse {
  do {
    return try decodeOfficialSDKResponse(provider: provider, raw: raw, options: options)
  } catch let error as AdapterExecutionError {
    throw error
  } catch {
    throw AdapterExecutionError(
      .invalidOutput,
      "official SDK \(provider) response did not match expected schema",
      isRetryable: false
    )
  }
}

private func sleepBeforeOfficialSDKFallback(retryAfter: Duration, deadline: Date?) async throws {
  guard retryAfter > .zero else {
    return
  }
  if let deadline,
     deadline <= Date().addingTimeInterval(timeInterval(forOfficialSDKDuration: retryAfter)) {
    throw AdapterExecutionError(.providerError, "official SDK stream retry-after exceeds deadline", isRetryable: true, retryAfter: retryAfter)
  }
  try await Task.sleep(for: retryAfter)
}

private func timeInterval(forOfficialSDKDuration duration: Duration) -> TimeInterval {
  let components = duration.components
  return max(
    0,
    TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
  )
}

func redactOfficialSDKSensitiveText(_ text: String, sensitiveValues: [String]) -> String {
  var redacted = redactAdapterSensitiveText(text)
  for value in sensitiveValues where !value.isEmpty {
    redacted = redacted.replacingOccurrences(of: value, with: "<redacted>")
  }
  return redacted
}

private func cursorAgentRequest(from input: AdapterExecutionInput) -> CursorAgentRequest {
  CursorAgentRequest(
    model: input.node.model,
    prompt: [input.systemPromptText, input.promptText].compactMap { text in
      text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }.joined(separator: "\n\n"),
    repositoryURL: firstNonEmptyString(
      input.mergedVariables["cursorRepositoryURL"],
      input.node.variables["cursorRepositoryURL"],
      input.agentEnvironment["CURSOR_REPOSITORY_URL"].map(JSONValue.string)
    ),
    startingRef: firstNonEmptyString(
      input.mergedVariables["cursorStartingRef"],
      input.node.variables["cursorStartingRef"],
      input.agentEnvironment["CURSOR_STARTING_REF"].map(JSONValue.string)
    ),
    workOnCurrentBranch: firstBool(
      input.mergedVariables["cursorWorkOnCurrentBranch"],
      input.node.variables["cursorWorkOnCurrentBranch"],
      input.agentEnvironment["CURSOR_WORK_ON_CURRENT_BRANCH"].map(JSONValue.string)
    ),
    autoCreatePR: firstBool(
      input.mergedVariables["cursorAutoCreatePR"],
      input.node.variables["cursorAutoCreatePR"],
      input.agentEnvironment["CURSOR_AUTO_CREATE_PR"].map(JSONValue.string)
    )
  )
}
