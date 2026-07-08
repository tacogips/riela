import Foundation
import RielaCore

struct OfficialSDKImageInput: Equatable, Sendable {
  var mimeType: String
  var dataBase64: String
}

func openAIImageInputs(from input: AdapterExecutionInput) throws -> [OpenAIImageInput] {
  try officialSDKImageInputs(from: input, failureProviderName: "OpenAI").map { image in
    OpenAIImageInput(mimeType: image.mimeType, dataBase64: image.dataBase64)
  }
}

func anthropicImageInputs(from input: AdapterExecutionInput) throws -> [AnthropicImageInput] {
  try officialSDKImageInputs(from: input, failureProviderName: "Anthropic").map { image in
    AnthropicImageInput(mimeType: image.mimeType, dataBase64: image.dataBase64)
  }
}

func geminiInlineDataPartsFromImagePaths(_ input: AdapterExecutionInput) throws -> [GeminiInlineDataPart] {
  try officialSDKImageInputs(from: input, failureProviderName: "Gemini").map { image in
    GeminiInlineDataPart(mimeType: image.mimeType, dataBase64: image.dataBase64)
  }
}

func geminiInlineDataParts(from input: AdapterExecutionInput) throws -> [GeminiInlineDataPart] {
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
    guard let mimeType = nonEmptyOfficialSDKStringValue(object["mimeType"]) else {
      throw AdapterExecutionError(.policyBlocked, "geminiInlineDataParts[\(index)].mimeType is required")
    }
    guard let dataBase64 = nonEmptyOfficialSDKStringValue(object["dataBase64"] ?? object["data"]) else {
      throw AdapterExecutionError(.policyBlocked, "geminiInlineDataParts[\(index)].dataBase64 is required")
    }
    return GeminiInlineDataPart(mimeType: mimeType, dataBase64: dataBase64)
  }
}

private func officialSDKImageInputs(
  from input: AdapterExecutionInput,
  failureProviderName: String
) throws -> [OfficialSDKImageInput] {
  try resolveAdapterImagePaths(input).map { path in
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw AdapterExecutionError(.policyBlocked, "failed to read \(failureProviderName) image attachment at \(path)")
    }
    return OfficialSDKImageInput(
      mimeType: officialSDKImageMimeType(for: url),
      dataBase64: data.base64EncodedString()
    )
  }
}

private func officialSDKImageMimeType(for url: URL) -> String {
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

private func nonEmptyOfficialSDKStringValue(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value, !text.isEmpty else {
    return nil
  }
  return text
}
