import Foundation
import RielaCore

public struct OfficialSDKParsingOptions: OptionSet, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let fillRequiredStringIfMissing = Self(rawValue: 1 << 0)
  public static let ignoreUnknownEnumValues = Self(rawValue: 1 << 1)
  public static let relaxed: Self = [.fillRequiredStringIfMissing, .ignoreUnknownEnumValues]
}

public struct OfficialSDKDecodedResponse: Sendable {
  public var text: String
  public var usage: AdapterUsage?
  public var stopReason: String?
  public var raw: JSONValue

  public init(text: String, usage: AdapterUsage? = nil, stopReason: String? = nil, raw: JSONValue) {
    self.text = text
    self.usage = usage
    self.stopReason = stopReason
    self.raw = raw
  }
}

func decodeOfficialSDKResponse(
  provider: String,
  data: Data,
  options: OfficialSDKParsingOptions
) throws -> OfficialSDKDecodedResponse {
  let raw = try JSONDecoder().decode(JSONValue.self, from: data)
  return try decodeOfficialSDKResponse(provider: provider, raw: raw, options: options)
}

func decodeOfficialSDKResponse(
  provider: String,
  raw: JSONValue,
  options: OfficialSDKParsingOptions
) throws -> OfficialSDKDecodedResponse {
  let data = try JSONEncoder().encode(raw)
  switch provider {
  case OpenAiSDKAdapter.provider:
    let response = try JSONDecoder().decode(OpenAIResponsesWire.Response.self, from: data)
    return OfficialSDKDecodedResponse(
      text: response.outputTextValue(options: options),
      usage: response.usage?.adapterUsage,
      stopReason: response.stopReason,
      raw: raw
    )
  case AnthropicSDKAdapter.provider:
    let response = try JSONDecoder().decode(AnthropicWire.Message.self, from: data)
    return OfficialSDKDecodedResponse(
      text: response.textValue,
      usage: response.usage?.adapterUsage,
      stopReason: response.stopReason,
      raw: raw
    )
  case GeminiSDKAdapter.provider:
    let response = try JSONDecoder().decode(GeminiWire.GenerateContentResponse.self, from: data)
    return OfficialSDKDecodedResponse(
      text: response.textValue,
      usage: response.usageMetadata?.adapterUsage,
      stopReason: response.stopReason,
      raw: raw
    )
  case CursorSDKAdapter.provider:
    let response = try JSONDecoder().decode(CursorWire.Agent.self, from: data)
    return OfficialSDKDecodedResponse(text: response.textValue, usage: nil, raw: raw)
  default:
    return OfficialSDKDecodedResponse(text: "", usage: nil, raw: raw)
  }
}

enum OpenAIResponsesWire {
  typealias Response = OpenAIResponsesResponse
  typealias OutputItem = OpenAIResponsesOutputItem
  typealias Content = OpenAIResponsesContent
  typealias Usage = OpenAIResponsesUsage
  typealias InputTokenDetails = OpenAIResponsesInputTokenDetails
}

enum AnthropicWire {
  typealias Message = AnthropicWireMessage
  typealias Content = AnthropicContent
  typealias Usage = AnthropicUsage
}

enum GeminiWire {
  typealias GenerateContentResponse = GeminiGenerateContentResponse
  typealias Candidate = GeminiCandidate
  typealias Content = GeminiContent
  typealias Part = GeminiPart
  typealias UsageMetadata = GeminiUsageMetadata
}

enum CursorWire {
  typealias Agent = CursorAgent
}

struct OpenAIResponsesResponse: Decodable {
  var outputText: String?
  var output: [OpenAIResponsesOutputItem]?
  var usage: OpenAIResponsesUsage?
  var stopReason: String?

  enum CodingKeys: String, CodingKey {
    case outputText = "output_text"
    case output
    case usage
    case stopReason = "stop_reason"
  }

  func outputTextValue(options: OfficialSDKParsingOptions) -> String {
    if let outputText, !outputText.isEmpty {
      return outputText
    }
    let segments = output?.flatMap { item in
      item.content?.compactMap { content -> String? in
        let isOutputText = content.type == "output_text" ||
          (options.contains(.fillRequiredStringIfMissing) && content.type == nil)
        guard isOutputText, let text = content.text, !text.isEmpty else {
          return nil
        }
        return text
      } ?? []
    } ?? []
    return segments.joined(separator: "\n")
  }
}

struct OpenAIResponsesOutputItem: Decodable {
  var content: [OpenAIResponsesContent]?
}

struct OpenAIResponsesContent: Decodable {
  var type: String?
  var text: String?
}

struct OpenAIResponsesUsage: Decodable {
  var inputTokens: Int?
  var outputTokens: Int?
  var totalTokens: Int?
  var inputTokenDetails: OpenAIResponsesInputTokenDetails?
  var raw: JSONObject

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case totalTokens = "total_tokens"
    case inputTokenDetails = "input_tokens_details"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
    outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
    totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
    inputTokenDetails = try container.decodeIfPresent(OpenAIResponsesInputTokenDetails.self, forKey: .inputTokenDetails)
    raw = (try? JSONObject(from: decoder)) ?? [:]
  }

  var adapterUsage: AdapterUsage {
    AdapterUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      totalTokens: totalTokens,
      cacheReadInputTokens: inputTokenDetails?.cachedTokens,
      providerRaw: raw
    )
  }
}

struct OpenAIResponsesInputTokenDetails: Decodable {
  var cachedTokens: Int?

  enum CodingKeys: String, CodingKey {
    case cachedTokens = "cached_tokens"
  }
}

struct AnthropicWireMessage: Decodable {
  var content: [AnthropicContent]?
  var usage: AnthropicUsage?
  var stopReason: String?

  enum CodingKeys: String, CodingKey {
    case content
    case usage
    case stopReason = "stop_reason"
  }

  var textValue: String {
    let segments = content?.compactMap { entry -> String? in
      guard entry.type == "text", let text = entry.text, !text.isEmpty else {
        return nil
      }
      return text
    } ?? []
    return segments.joined(separator: "\n")
  }
}

struct AnthropicContent: Decodable {
  var type: String?
  var text: String?
}

struct AnthropicUsage: Decodable {
  var inputTokens: Int?
  var outputTokens: Int?
  var cacheReadInputTokens: Int?
  var cacheCreationInputTokens: Int?
  var raw: JSONObject

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cacheReadInputTokens = "cache_read_input_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
    outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
    cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)
    cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)
    raw = (try? JSONObject(from: decoder)) ?? [:]
  }

  var adapterUsage: AdapterUsage {
    AdapterUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadInputTokens: cacheReadInputTokens,
      cacheCreationInputTokens: cacheCreationInputTokens,
      providerRaw: raw
    )
  }
}

struct GeminiGenerateContentResponse: Decodable {
  var candidates: [GeminiCandidate]?
  var usageMetadata: GeminiUsageMetadata?

  var textValue: String {
    let segments = candidates?.flatMap { candidate in
      candidate.content?.parts?.compactMap { part -> String? in
        guard let text = part.text, !text.isEmpty else {
          return nil
        }
        return text
      } ?? []
    } ?? []
    return segments.joined(separator: "\n")
  }

  var stopReason: String? {
    candidates?.compactMap(\.finishReason).first
  }
}

struct GeminiCandidate: Decodable {
  var content: GeminiContent?
  var finishReason: String?
}

struct GeminiContent: Decodable {
  var parts: [GeminiPart]?
}

struct GeminiPart: Decodable {
  var text: String?
}

struct GeminiUsageMetadata: Decodable {
  var promptTokenCount: Int?
  var candidatesTokenCount: Int?
  var totalTokenCount: Int?
  var raw: JSONObject

  enum CodingKeys: String, CodingKey {
    case promptTokenCount
    case candidatesTokenCount
    case totalTokenCount
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    promptTokenCount = try container.decodeIfPresent(Int.self, forKey: .promptTokenCount)
    candidatesTokenCount = try container.decodeIfPresent(Int.self, forKey: .candidatesTokenCount)
    totalTokenCount = try container.decodeIfPresent(Int.self, forKey: .totalTokenCount)
    raw = (try? JSONObject(from: decoder)) ?? [:]
  }

  var adapterUsage: AdapterUsage {
    AdapterUsage(
      inputTokens: promptTokenCount,
      outputTokens: candidatesTokenCount,
      totalTokens: totalTokenCount,
      providerRaw: raw
    )
  }
}

struct CursorAgent: Decodable {
  var id: String?
  var status: String?
  var url: String?
  var latestRunId: String?
  var result: String?

  var textValue: String {
    if let result, !result.isEmpty {
      return result
    }
    let summary = [
      id.map { "Cursor agent \($0)" },
      status.map { "status: \($0)" },
      latestRunId.map { "latest run: \($0)" },
      url
    ].compactMap { $0 }
    return summary.isEmpty ? "" : summary.joined(separator: "\n")
  }
}
