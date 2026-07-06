import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore

public enum OfficialSDKErrorClassification: Equatable, Sendable {
  case retryable
  case nonRetryable
}

public struct OfficialSDKAPIError: Error, Equatable, Sendable {
  public var provider: String
  public var statusCode: Int
  public var type: String?
  public var message: String
  public var retryAfter: Duration?
  public var classification: OfficialSDKErrorClassification

  public init(
    provider: String,
    statusCode: Int,
    type: String? = nil,
    message: String,
    retryAfter: Duration? = nil,
    classification: OfficialSDKErrorClassification
  ) {
    self.provider = provider
    self.statusCode = statusCode
    self.type = type
    self.message = message
    self.retryAfter = retryAfter
    self.classification = classification
  }

  public var adapterError: AdapterExecutionError {
    let typePrefix = type.map { " \($0)" } ?? ""
    return AdapterExecutionError(
      .providerError,
      "\(provider) HTTP \(statusCode)\(typePrefix): \(message)",
      isRetryable: classification == .retryable,
      retryAfter: retryAfter
    )
  }
}

func decodeOfficialSDKAPIError(
  provider: String,
  statusCode: Int,
  headers: [String: String],
  body: Data,
  sensitiveValues: [String]
) -> OfficialSDKAPIError {
  let bodyValue = try? JSONDecoder().decode(JSONValue.self, from: body)
  let envelope = bodyValue.flatMap { officialSDKErrorEnvelope(provider: provider, value: $0) }
  let fallback = String(data: body, encoding: .utf8) ?? ""
  let message = redactOfficialSDKSensitiveText(
    envelope?.message ?? fallback,
    sensitiveValues: sensitiveValues
  )
  return OfficialSDKAPIError(
    provider: provider,
    statusCode: statusCode,
    type: envelope?.type,
    message: message,
    retryAfter: retryAfterDuration(headers: headers),
    classification: officialSDKErrorClassification(statusCode: statusCode)
  )
}

private func officialSDKErrorEnvelope(provider: String, value: JSONValue) -> (type: String?, message: String)? {
  guard case let .object(object) = value else {
    return nil
  }
  switch provider {
  case OpenAiSDKAdapter.provider:
    return nestedErrorEnvelope(object["error"]) ?? flatErrorEnvelope(object)
  case AnthropicSDKAdapter.provider:
    return nestedErrorEnvelope(object["error"]) ?? flatErrorEnvelope(object)
  case GeminiSDKAdapter.provider:
    if let envelope = nestedErrorEnvelope(object["error"]) {
      return envelope
    }
    if case let .array(errors) = object["error"] {
      return errors.lazy.compactMap(officialSDKErrorEnvelopeFromArrayEntry).first
    }
    return flatErrorEnvelope(object)
  default:
    return flatErrorEnvelope(object) ?? nestedErrorEnvelope(object["error"])
  }
}

private func officialSDKErrorEnvelopeFromArrayEntry(_ value: JSONValue) -> (type: String?, message: String)? {
  guard case let .object(object) = value else {
    return nil
  }
  return nestedErrorEnvelope(.object(object)) ?? flatErrorEnvelope(object)
}

private func nestedErrorEnvelope(_ value: JSONValue?) -> (type: String?, message: String)? {
  guard case let .object(object) = value else {
    if let message = errorMessageString(value) {
      return (nil, message)
    }
    return nil
  }
  let type = stringValue(object["type"]) ?? stringValue(object["status"]) ?? stringValue(object["code"])
  let message = errorMessageString(object["message"]) ?? stringValue(object["error"])
  return message.map { (type, $0) }
}

private func flatErrorEnvelope(_ object: JSONObject) -> (type: String?, message: String)? {
  let type = stringValue(object["type"]) ?? stringValue(object["status"]) ?? stringValue(object["code"])
  let message = errorMessageString(object["message"]) ?? errorMessageString(object["error"])
  return message.map { (type, $0) }
}

private func errorMessageString(_ value: JSONValue?) -> String? {
  if let message = stringValue(value), !message.isEmpty {
    return message
  }
  guard case let .array(values) = value else {
    return nil
  }
  let messages = values.compactMap { stringValue($0) }.filter { !$0.isEmpty }
  return messages.isEmpty ? nil : messages.joined(separator: "\n")
}

private func officialSDKErrorClassification(statusCode: Int) -> OfficialSDKErrorClassification {
  if statusCode == 408 || statusCode == 409 || statusCode == 429 || (500...599).contains(statusCode) {
    return .retryable
  }
  return .nonRetryable
}

private func retryAfterDuration(headers: [String: String]) -> Duration? {
  guard let value = headerValue("retry-after", in: headers)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty else {
    return nil
  }
  if let seconds = Double(value), seconds > 0 {
    return duration(seconds: seconds)
  }
  guard let date = httpDateFormatter.date(from: value) else {
    return nil
  }
  let interval = date.timeIntervalSinceNow
  return interval > 0 ? duration(seconds: interval) : nil
}

private func headerValue(_ name: String, in headers: [String: String]) -> String? {
  headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
}

private let httpDateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
  return formatter
}()

private func duration(seconds: TimeInterval) -> Duration {
  guard seconds > 0, seconds.isFinite else {
    return .zero
  }
  let wholeSeconds = Int64(seconds.rounded(.towardZero))
  let fractionalSeconds = seconds - TimeInterval(wholeSeconds)
  let attoseconds = Int64((fractionalSeconds * 1_000_000_000_000_000_000).rounded())
  return Duration(secondsComponent: wholeSeconds, attosecondsComponent: attoseconds)
}
