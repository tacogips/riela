import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore

public struct OfficialSDKAdapterConfiguration: Sendable {
  public var apiKeyEnv: String?
  public var baseURL: URL?
  public var retryPolicy: RetryPolicy
  public var environment: [String: String]?
  public var requestExecutor: (any OfficialSDKRequestExecuting)?
  public var httpTransport: (any OfficialSDKHTTPTransporting)?

  public init(
    apiKeyEnv: String? = nil,
    baseURL: URL? = nil,
    retryPolicy: RetryPolicy = RetryPolicy(),
    environment: [String: String]? = nil,
    requestExecutor: (any OfficialSDKRequestExecuting)? = nil,
    httpTransport: (any OfficialSDKHTTPTransporting)? = nil
  ) {
    self.apiKeyEnv = apiKeyEnv
    self.baseURL = baseURL
    self.retryPolicy = retryPolicy
    self.environment = environment
    self.requestExecutor = requestExecutor
    self.httpTransport = httpTransport
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

  public init(model: String, maxTokens: Int, system: String? = nil, messages: [AnthropicMessage]) {
    self.model = model
    self.maxTokens = max(1, maxTokens)
    self.system = system
    self.messages = messages
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

  public init(body: JSONValue) {
    self.body = body
  }
}

public struct OfficialSDKHTTPResponse: Equatable, Sendable {
  public var statusCode: Int
  public var body: Data

  public init(statusCode: Int, body: Data) {
    self.statusCode = statusCode
    self.body = body
  }
}

public struct URLSessionOfficialSDKHTTPTransport: OfficialSDKHTTPTransporting {
  public init() {}

  public func data(for request: URLRequest) async throws -> OfficialSDKHTTPResponse {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AdapterExecutionError(.providerError, "official SDK request did not return an HTTP response")
    }
    return OfficialSDKHTTPResponse(statusCode: httpResponse.statusCode, body: data)
  }
}

public struct URLSessionOfficialSDKRequestExecutor: OfficialSDKRequestExecuting {
  public var transport: any OfficialSDKHTTPTransporting

  public init(transport: any OfficialSDKHTTPTransporting = URLSessionOfficialSDKHTTPTransport()) {
    self.transport = transport
  }

  public func executeSDKRequest(_ request: OfficialSDKRequest, context: AdapterExecutionContext) async throws -> OfficialSDKResponse {
    let urlRequest = try makeURLRequest(for: request)
    let response = try await transport.data(for: urlRequest)
    guard (200...299).contains(response.statusCode) else {
      let detail = String(data: response.body, encoding: .utf8) ?? ""
      throw AdapterExecutionError(
        .providerError,
        "\(request.provider) request failed with HTTP \(response.statusCode): \(redactOfficialSDKSensitiveText(detail, sensitiveValues: [request.apiKey]))"
      )
    }

    let decoded = try JSONDecoder().decode(JSONValue.self, from: response.body)
    return OfficialSDKResponse(body: decoded)
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
      fallbackFailureMessage: "unknown OpenAI SDK failure",
      extractText: extractOpenAIText
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
          messages: [AnthropicMessage(role: "user", content: input.promptText)]
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
      fallbackFailureMessage: "unknown Anthropic SDK failure",
      extractText: extractAnthropicText
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
          inlineDataParts: try geminiInlineDataParts(from: input)
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
      fallbackFailureMessage: "unknown Gemini SDK failure",
      extractText: extractGeminiText
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
      fallbackFailureMessage: "unknown Cursor SDK failure",
      extractText: extractCursorAgentText
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
  fallbackFailureMessage: String,
  extractText: @Sendable @escaping (JSONValue) -> String
) async throws -> AdapterExecutionOutput {
  let executor = configuration.requestExecutor ?? URLSessionOfficialSDKRequestExecutor(
    transport: configuration.httpTransport ?? URLSessionOfficialSDKHTTPTransport()
  )
  let response = try await retryOfficialSDKRequest(
    policy: configuration.retryPolicy,
    deadline: context.deadline,
    timeoutMessage: timeoutMessage,
    fallbackFailureMessage: fallbackFailureMessage,
    sensitiveValues: [request.apiKey]
  ) {
    try await executor.executeSDKRequest(request, context: context)
  }

  let text = extractText(response.body)
  let normalized: OutputContractEnvelopeNormalization
  if adapterInput.node.output == nil {
    normalized = OutputContractEnvelopeNormalization(
      completionPassed: true,
      when: ["always": true],
      payload: normalizeTextBusinessPayload(text),
      usedEnvelope: false
    )
  } else {
    normalized = try normalizeOutputContractEnvelope(
      parseJSONObjectCandidate(text, source: responseLabel),
      source: responseLabel
    )
  }

  return AdapterExecutionOutput(
    provider: request.provider,
    model: adapterInput.node.model,
    promptText: adapterInput.promptText,
    completionPassed: normalized.completionPassed,
    when: normalized.when,
    payload: normalized.payload
  )
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
    return AdapterExecutionError(adapterError.code, redactOfficialSDKSensitiveText(message, sensitiveValues: sensitiveValues))
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

private func redactOfficialSDKSensitiveText(_ text: String, sensitiveValues: [String]) -> String {
  var redacted = redactAdapterSensitiveText(text)
  for value in sensitiveValues where !value.isEmpty {
    redacted = redacted.replacingOccurrences(of: value, with: "<redacted>")
  }
  return redacted
}

private func makeURLRequest(for request: OfficialSDKRequest) throws -> URLRequest {
  let endpoint: URL
  var body: JSONObject
  var headers: [String: String]

  switch request.body {
  case let .openAIResponses(openAIRequest):
    endpoint = officialSDKEndpoint(baseURL: request.baseURL, defaultBaseURL: "https://api.openai.com/v1", pathComponents: ["responses"])
    body = [
      "model": .string(openAIRequest.model),
      "input": openAIInputValue(openAIRequest)
    ]
    if let instructions = openAIRequest.instructions {
      body["instructions"] = .string(instructions)
    }
    headers = [
      "Authorization": "Bearer \(request.apiKey)",
      "Content-Type": "application/json"
    ]
  case let .anthropicMessages(anthropicRequest):
    endpoint = officialSDKEndpoint(baseURL: request.baseURL, defaultBaseURL: "https://api.anthropic.com", pathComponents: ["v1", "messages"])
    body = [
      "model": .string(anthropicRequest.model),
      "max_tokens": .number(Double(anthropicRequest.maxTokens)),
      "messages": .array(anthropicRequest.messages.map { message in
        .object([
          "role": .string(message.role),
          "content": .string(message.content)
        ])
      })
    ]
    if let system = anthropicRequest.system {
      body["system"] = .string(system)
    }
    headers = [
      "x-api-key": request.apiKey,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json"
    ]
  case let .geminiGenerateContent(geminiRequest):
    endpoint = geminiGenerateContentEndpoint(baseURL: request.baseURL, model: geminiRequest.model)
    let parts = geminiRequest.inlineDataParts.map { part in
      JSONValue.object([
        "inline_data": .object([
          "mime_type": .string(part.mimeType),
          "data": .string(part.dataBase64)
        ])
      ])
    } + [
      .object(["text": .string(geminiRequest.input)])
    ]
    body = [
      "contents": .array([
        .object([
          "role": .string("user"),
          "parts": .array(parts)
        ])
      ])
    ]
    if let system = geminiRequest.system {
      body["systemInstruction"] = .object([
        "parts": .array([
          .object(["text": .string(system)])
        ])
      ])
    }
    headers = [
      "x-goog-api-key": request.apiKey,
      "Content-Type": "application/json"
    ]
  case let .cursorCreateAgent(cursorRequest):
    endpoint = officialSDKEndpoint(baseURL: request.baseURL, defaultBaseURL: "https://api.cursor.com/v1", pathComponents: ["agents"])
    body = [
      "prompt": .object(["text": .string(cursorRequest.prompt)]),
      "model": .object(["id": .string(cursorRequest.model)])
    ]
    if let repositoryURL = cursorRequest.repositoryURL {
      var repo: JSONObject = ["url": .string(repositoryURL)]
      if let startingRef = cursorRequest.startingRef {
        repo["startingRef"] = .string(startingRef)
      }
      body["repos"] = .array([.object(repo)])
    }
    if let workOnCurrentBranch = cursorRequest.workOnCurrentBranch {
      body["workOnCurrentBranch"] = .bool(workOnCurrentBranch)
    }
    if let autoCreatePR = cursorRequest.autoCreatePR {
      body["autoCreatePR"] = .bool(autoCreatePR)
    }
    headers = [
      "Authorization": "Basic \(Data("\(request.apiKey):".utf8).base64EncodedString())",
      "Content-Type": "application/json"
    ]
  }

  var urlRequest = URLRequest(url: endpoint)
  urlRequest.httpMethod = "POST"
  for (key, value) in headers {
    urlRequest.setValue(value, forHTTPHeaderField: key)
  }
  urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(body))
  return urlRequest
}

private func openAIInputValue(_ request: OpenAIResponsesRequest) -> JSONValue {
  guard !request.imageInputs.isEmpty else {
    return .string(request.input)
  }

  var content: [JSONValue] = [
    .object([
      "type": .string("input_text"),
      "text": .string(request.input)
    ])
  ]
  content += request.imageInputs.map { image in
    .object([
      "type": .string("input_image"),
      "image_url": .string(image.dataURL)
    ])
  }

  return .array([
    .object([
      "role": .string("user"),
      "content": .array(content)
    ])
  ])
}

private func geminiGenerateContentEndpoint(baseURL: URL?, model: String) -> URL {
  let base = officialSDKEndpoint(
    baseURL: baseURL,
    defaultBaseURL: "https://generativelanguage.googleapis.com",
    pathComponents: ["v1beta"]
  )
  let normalizedModel = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
  let baseString = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
  return URL(string: "\(baseString)/models/\(normalizedModel):generateContent")!
}

private func officialSDKEndpoint(baseURL: URL?, defaultBaseURL: String, pathComponents: [String]) -> URL {
  let base = baseURL ?? URL(string: defaultBaseURL)!
  let existingPathComponents = base.pathComponents.filter { $0 != "/" }
  if existingPathComponents.suffix(pathComponents.count) == pathComponents {
    return base
  }
  let missingPathComponents: ArraySlice<String>
  if pathComponents.count > 1,
     existingPathComponents.suffix(pathComponents.count - 1) == pathComponents.dropLast() {
    missingPathComponents = pathComponents.suffix(1)
  } else {
    missingPathComponents = pathComponents[...]
  }
  return missingPathComponents.reduce(base) { url, component in
    url.appendingPathComponent(component)
  }
}

private func extractOpenAIText(_ response: JSONValue) -> String {
  guard case let .object(object) = response else {
    return ""
  }
  if let outputText = stringValue(object["output_text"]) {
    return outputText
  }
  guard case let .array(output) = object["output"] else {
    return ""
  }

  let segments = output.flatMap { item -> [String] in
    guard case let .object(itemObject) = item, case let .array(content) = itemObject["content"] else {
      return []
    }
    return content.compactMap { entry -> String? in
      guard
        case let .object(entryObject) = entry,
        stringValue(entryObject["type"]) == "output_text",
        let text = stringValue(entryObject["text"]),
        !text.isEmpty
      else {
        return nil
      }
      return text
    }
  }

  return segments.joined(separator: "\n")
}

private func extractAnthropicText(_ response: JSONValue) -> String {
  guard case let .object(object) = response, case let .array(content) = object["content"] else {
    return ""
  }

  let segments = content.compactMap { entry -> String? in
    guard
      case let .object(entryObject) = entry,
      stringValue(entryObject["type"]) == "text",
      let text = stringValue(entryObject["text"]),
      !text.isEmpty
    else {
      return nil
    }
    return text
  }

  return segments.joined(separator: "\n")
}

private func extractGeminiText(_ response: JSONValue) -> String {
  guard case let .object(object) = response, case let .array(candidates) = object["candidates"] else {
    return ""
  }

  let segments = candidates.flatMap { candidate -> [String] in
    guard
      case let .object(candidateObject) = candidate,
      case let .object(content) = candidateObject["content"],
      case let .array(parts) = content["parts"]
    else {
      return []
    }
    return parts.compactMap { part -> String? in
      guard
        case let .object(partObject) = part,
        let text = stringValue(partObject["text"]),
        !text.isEmpty
      else {
        return nil
      }
      return text
    }
  }

  return segments.joined(separator: "\n")
}

private func extractCursorAgentText(_ response: JSONValue) -> String {
  guard case let .object(object) = response else {
    return ""
  }
  if let result = stringValue(object["result"]), !result.isEmpty {
    return result
  }
  let id = stringValue(object["id"])
  let status = stringValue(object["status"])
  let url = stringValue(object["url"])
  let latestRunId = stringValue(object["latestRunId"])
  let summary = [
    id.map { "Cursor agent \($0)" },
    status.map { "status: \($0)" },
    latestRunId.map { "latest run: \($0)" },
    url
  ].compactMap { $0 }
  return summary.isEmpty ? "" : summary.joined(separator: "\n")
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

private func geminiInlineDataParts(from input: AdapterExecutionInput) throws -> [GeminiInlineDataPart] {
  let value = input.mergedVariables["geminiInlineDataParts"] ?? input.node.variables["geminiInlineDataParts"]
  guard let value, value != .null else {
    return []
  }
  guard case let .array(parts) = value else {
    throw AdapterExecutionError(.policyBlocked, "geminiInlineDataParts must be an array")
  }
  return try parts.enumerated().map { index, part in
    guard case let .object(object) = part else {
      throw AdapterExecutionError(.policyBlocked, "geminiInlineDataParts[\(index)] must be an object")
    }
    guard let mimeType = nonEmptyStringValue(object["mimeType"]) else {
      throw AdapterExecutionError(.policyBlocked, "geminiInlineDataParts[\(index)].mimeType is required")
    }
    guard let dataBase64 = nonEmptyStringValue(object["dataBase64"] ?? object["data"]) else {
      throw AdapterExecutionError(.policyBlocked, "geminiInlineDataParts[\(index)].dataBase64 is required")
    }
    return GeminiInlineDataPart(mimeType: mimeType, dataBase64: dataBase64)
  }
}

private func openAIImageInputs(from input: AdapterExecutionInput) throws -> [OpenAIImageInput] {
  try resolveAdapterImagePaths(input).map { path in
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw AdapterExecutionError(.policyBlocked, "failed to read OpenAI image attachment at \(path)")
    }
    return OpenAIImageInput(
      mimeType: openAIImageMimeType(for: url),
      dataBase64: data.base64EncodedString()
    )
  }
}

private func openAIImageMimeType(for url: URL) -> String {
  switch url.pathExtension.lowercased() {
  case "gif":
    return "image/gif"
  case "heic":
    return "image/heic"
  case "jpeg", "jpg":
    return "image/jpeg"
  case "png":
    return "image/png"
  case "webp":
    return "image/webp"
  default:
    return "application/octet-stream"
  }
}

private func nonEmptyStringValue(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value, !text.isEmpty else {
    return nil
  }
  return text
}

private func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}

private func firstNonEmptyString(_ values: JSONValue?...) -> String? {
  values.compactMap(nonEmptyStringValue).first
}

private func firstBool(_ values: JSONValue?...) -> Bool? {
  values.compactMap(boolValue).first
}

private func boolValue(_ value: JSONValue?) -> Bool? {
  switch value {
  case let .bool(flag):
    flag
  case let .string(text):
    Bool(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  default:
    nil
  }
}
