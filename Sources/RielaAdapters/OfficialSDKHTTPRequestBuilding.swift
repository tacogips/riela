import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore

func makeURLRequest(
  for request: OfficialSDKRequest,
  context: AdapterExecutionContext,
  customHeaders: [String: String],
  timeout: Duration?,
  streaming: Bool = false
) throws -> URLRequest {
  let endpoint: URL
  var body: JSONObject
  var headers: [String: String]

  switch request.body {
  case let .openAIResponses(openAIRequest):
    endpoint = officialSDKEndpoint(
      baseURL: request.baseURL,
      defaultBaseURL: "https://api.openai.com/v1",
      pathComponents: ["responses"]
    )
    body = [
      "model": .string(openAIRequest.model),
      "input": openAIInputValue(openAIRequest)
    ]
    if streaming {
      body["stream"] = .bool(true)
    }
    if let instructions = openAIRequest.instructions {
      body["instructions"] = .string(instructions)
    }
    headers = [
      "Authorization": "Bearer \(request.apiKey)",
      "Content-Type": "application/json"
    ]
  case let .anthropicMessages(anthropicRequest):
    endpoint = officialSDKEndpoint(
      baseURL: request.baseURL,
      defaultBaseURL: "https://api.anthropic.com",
      pathComponents: ["v1", "messages"]
    )
    body = [
      "model": .string(anthropicRequest.model),
      "max_tokens": .number(Double(anthropicRequest.maxTokens)),
      "messages": .array(anthropicRequest.messages.map { message in
        .object([
          "role": .string(message.role),
          "content": anthropicContentValue(message: message, imageInputs: anthropicRequest.imageInputs)
        ])
      })
    ]
    if streaming {
      body["stream"] = .bool(true)
    }
    if let system = anthropicRequest.system {
      body["system"] = .string(system)
    }
    headers = [
      "x-api-key": request.apiKey,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json"
    ]
  case let .geminiGenerateContent(geminiRequest):
    endpoint = geminiGenerateContentEndpoint(baseURL: request.baseURL, model: geminiRequest.model, streaming: streaming)
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
    endpoint = officialSDKEndpoint(
      baseURL: request.baseURL,
      defaultBaseURL: "https://api.cursor.com/v1",
      pathComponents: ["agents"]
    )
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
  for (key, value) in customHeaders {
    urlRequest.setValue(value, forHTTPHeaderField: key)
  }
  if let timeoutInterval = officialSDKRequestTimeoutInterval(timeout: timeout, deadline: context.deadline) {
    urlRequest.timeoutInterval = timeoutInterval
  }
  urlRequest.httpBody = try officialSDKRequestBodyEncoder().encode(JSONValue.object(body))
  return urlRequest
}

private func officialSDKRequestBodyEncoder() -> JSONEncoder {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return encoder
}

func applyOfficialSDKRequestMiddleware(
  _ request: URLRequest,
  middlewares: [any OfficialSDKMiddleware]
) -> URLRequest {
  middlewares.reduce(request) { current, middleware in
    middleware.intercept(request: current)
  }
}

func applyOfficialSDKResponseMiddleware(
  _ response: OfficialSDKHTTPResponse,
  request: URLRequest,
  middlewares: [any OfficialSDKMiddleware]
) -> OfficialSDKHTTPResponse {
  guard !middlewares.isEmpty,
        let url = request.url,
        let httpResponse = HTTPURLResponse(
          url: url,
          statusCode: response.statusCode,
          httpVersion: nil,
          headerFields: response.headers
        ) else {
    return response
  }
  let body = middlewares.reduce(response.body) { current, middleware in
    middleware.intercept(response: httpResponse, data: current)
  }
  return OfficialSDKHTTPResponse(statusCode: response.statusCode, body: body, headers: response.headers)
}

private func officialSDKRequestTimeoutInterval(timeout: Duration?, deadline: Date?) -> TimeInterval? {
  let configuredTimeout = timeout.map(officialSDKTimeInterval)
  let rawDeadlineTimeout = deadline?.timeIntervalSinceNow
  let deadlineTimeout = rawDeadlineTimeout.flatMap { $0 > 0 ? $0 : nil }
  let candidates = [configuredTimeout, deadlineTimeout].compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
  guard let shortestTimeout = candidates.min() else {
    return nil
  }
  return max(1, shortestTimeout)
}

private func officialSDKTimeInterval(for duration: Duration) -> TimeInterval {
  let components = duration.components
  let seconds = TimeInterval(components.seconds)
  let fractionalSeconds = TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
  return max(0, seconds + fractionalSeconds)
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

private func anthropicContentValue(message: AnthropicMessage, imageInputs: [AnthropicImageInput]) -> JSONValue {
  guard !imageInputs.isEmpty else {
    return .string(message.content)
  }

  let imageBlocks = imageInputs.map { image in
    JSONValue.object([
      "type": .string("image"),
      "source": .object([
        "type": .string("base64"),
        "media_type": .string(image.mimeType),
        "data": .string(image.dataBase64)
      ])
    ])
  }
  return .array(imageBlocks + [
    .object([
      "type": .string("text"),
      "text": .string(message.content)
    ])
  ])
}

private func geminiGenerateContentEndpoint(baseURL: URL?, model: String, streaming: Bool = false) -> URL {
  let base = officialSDKEndpoint(
    baseURL: baseURL,
    defaultBaseURL: "https://generativelanguage.googleapis.com",
    pathComponents: ["v1beta"]
  )
  let normalizedModel = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
  let baseString = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
  let method = streaming ? "streamGenerateContent?alt=sse" : "generateContent"
  return URL(string: "\(baseString)/models/\(normalizedModel):\(method)")!
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
