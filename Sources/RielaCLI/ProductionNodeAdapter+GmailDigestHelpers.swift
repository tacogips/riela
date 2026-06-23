import Foundation
import RielaCore

private let gmailMaxAttachmentTextBytes = 256_000

func latestStatePayload(_ payloads: [JSONObject]) -> JSONObject {
  payloads.first { payload in
    gmailArray(payload["knownMessageIds"]) != nil && gmailNumber(payload["maxMessages"]) != nil
  } ?? [:]
}

final class GmailGeminiResponseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<JSONObject, Error>?

  var value: Result<JSONObject, Error>? {
    lock.withLock { stored }
  }

  func set(_ value: Result<JSONObject, Error>) {
    lock.withLock {
      stored = value
    }
  }
}

func latestNormalizePayload(_ payloads: [JSONObject]) -> JSONObject {
  payloads.first { payload in
    gmailArray(payload["selectedMessages"]) != nil && gmailArray(payload["fetchedMessageIds"]) != nil
  } ?? [:]
}

func priorKnownIds(_ payloads: [JSONObject]) -> [String] {
  (gmailArray(latestStatePayload(payloads)["knownMessageIds"]) ?? []).compactMap(gmailNonEmptyString)
}

func gmailUpstreamPayloads(_ input: JSONObject) -> [JSONObject] {
  var payloads: [JSONObject] = []
  for value in gmailArray(input["upstream"]) ?? [] {
    if let payload = gmailObject(value.gmailValue(at: ["output", "payload"])) {
      payloads.append(payload)
    }
  }
  return payloads
}

func firstList(_ value: JSONValue, keys: [String]) -> [JSONValue] {
  if let list = gmailArray(value) {
    return list
  }
  guard let object = gmailObject(value) else {
    return []
  }
  for key in keys {
    if let list = gmailArray(object[key]) {
      return list
    }
    if let nested = object[key].map({ firstList($0, keys: keys) }), !nested.isEmpty {
      return nested
    }
  }
  for candidate in object.values {
    let nested = firstList(candidate, keys: keys)
    if !nested.isEmpty {
      return nested
    }
  }
  return []
}

func displayAddress(_ value: JSONValue?) -> String {
  if let text = gmailString(value) {
    return gmailCompactText(.string(text))
  }
  guard let object = gmailObject(value) else {
    return ""
  }
  let name = gmailCompactText(object["name"])
  let address = gmailCompactText(object["address"] ?? object["email"])
  if !name.isEmpty && !address.isEmpty {
    return "\(name) <\(address)>"
  }
  return name.isEmpty ? address : name
}

func displayAddressList(_ value: JSONValue?) -> [String] {
  if let list = gmailArray(value) {
    return list.map(displayAddress).filter { !$0.isEmpty }
  }
  let rendered = displayAddress(value)
  return rendered.isEmpty ? [] : [rendered]
}

func gmailDateSortKey(_ message: JSONObject) -> TimeInterval {
  gmailParseDate(gmailNonEmptyString(message["receivedAt"]))?.timeIntervalSince1970 ?? 0
}

func isAttachmentDescriptor(_ fileDescriptor: JSONObject) -> Bool {
  let kind = gmailCompactText(fileDescriptor["kind"]).uppercased()
  if ["BODY_TEXT", "BODY_HTML", "TEMPORARY_FILE"].contains(kind) {
    return false
  }
  return gmailNonEmptyString(fileDescriptor["downloadKey"]) != nil
    || gmailNonEmptyString(fileDescriptor["localPath"]) != nil
}

func isPDFFile(_ fileDescriptor: JSONObject) -> Bool {
  let mimeType = gmailCompactText(fileDescriptor["mimeType"]).lowercased()
  let filename = gmailCompactText(fileDescriptor["filename"]).lowercased()
  return mimeType == "application/pdf" || filename.hasSuffix(".pdf")
}

func isTextFile(_ fileDescriptor: JSONObject) -> Bool {
  let mimeType = gmailCompactText(fileDescriptor["mimeType"]).lowercased()
  let filename = gmailCompactText(fileDescriptor["filename"]).lowercased()
  return mimeType.hasPrefix("text/")
    || [".txt", ".md", ".csv", ".json", ".log"].contains { filename.hasSuffix($0) }
}

func readTextPreview(_ filePath: String) throws -> String {
  let url = URL(fileURLWithPath: filePath)
  let data = try Data(contentsOf: url).prefix(gmailMaxAttachmentTextBytes)
  let text = String(data: Data(data), encoding: .utf8) ?? ""
  return String(gmailCompactText(.string(text)).prefix(2000))
}

func classifyTextPreview(_ text: String) -> String {
  let lowered = text.lowercased()
  if ["invoice", "請求", "receipt", "領収"].contains(where: lowered.contains) {
    return "billing"
  }
  if ["contract", "agreement", "契約"].contains(where: lowered.contains) {
    return "contract"
  }
  if ["incident", "障害", "postmortem"].contains(where: lowered.contains) {
    return "incident_report"
  }
  if ["report", "summary", "dashboard", "レポート"].contains(where: lowered.contains) {
    return "report"
  }
  return "text_attachment"
}

func geminiText(from response: JSONObject) -> String {
  var parts: [String] = []
  for candidateValue in gmailArray(response["candidates"]) ?? [] {
    let content = gmailObject(candidateValue)?["content"].flatMap(gmailObject) ?? [:]
    for part in gmailArray(content["parts"]) ?? [] {
      if let text = gmailObject(part)?["text"].flatMap(gmailString) {
        parts.append(text)
      }
    }
  }
  return gmailCompactText(.string(parts.joined(separator: "\n")))
}

func digestMessageIds(_ item: JSONObject) -> [String] {
  if let ids = gmailArray(item["messageIds"]) {
    return ids.compactMap(gmailNonEmptyString)
  }
  return []
}

func orderedUnique(_ values: [String]) -> [String] {
  var seen = Set<String>()
  var output: [String] = []
  for value in values where !value.isEmpty && seen.insert(value).inserted {
    output.append(value)
  }
  return output
}

func safePathComponent(_ value: String) -> String {
  let cleaned = value.map { character -> Character in
    character.isLetter || character.isNumber || "-_.".contains(character) ? character : "_"
  }
  .reduce(into: "") { $0.append($1) }
  .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
  return cleaned.isEmpty ? "item" : cleaned
}

func shellWords(_ value: String) -> [String] {
  var words: [String] = []
  var current = ""
  var quote: Character?
  var isEscaped = false
  for character in value {
    if isEscaped {
      current.append(character)
      isEscaped = false
    } else if character == "\\" {
      isEscaped = true
    } else if let activeQuote = quote {
      if character == activeQuote {
        quote = nil
      } else {
        current.append(character)
      }
    } else if character == "'" || character == "\"" {
      quote = character
    } else if character.isWhitespace {
      if !current.isEmpty {
        words.append(current)
        current = ""
      }
    } else {
      current.append(character)
    }
  }
  if !current.isEmpty {
    words.append(current)
  }
  return words
}

func gmailParseDate(_ value: String?) -> Date? {
  guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    return nil
  }
  if let number = Double(value), value.allSatisfy(\.isNumber) {
    let timestamp = number > 10_000_000_000 ? number / 1000 : number
    return Date(timeIntervalSince1970: timestamp)
  }
  let iso = ISO8601DateFormatter()
  iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = iso.date(from: value) {
    return date
  }
  iso.formatOptions = [.withInternetDateTime]
  if let date = iso.date(from: value) {
    return date
  }
  for format in ["EEE, d MMM yyyy HH:mm:ss ZZZZ", "EEE, dd MMM yyyy HH:mm:ss ZZZZ", "d MMM yyyy HH:mm:ss ZZZZ"] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    if let date = formatter.date(from: value) {
      return date
    }
  }
  return nil
}

func gmailISOString(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.string(from: date)
}

func gmailCompactText(_ value: JSONValue?, fallback: String = "") -> String {
  guard let text = gmailString(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
    return fallback
  }
  return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

func gmailObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}

func gmailArray(_ value: JSONValue?) -> [JSONValue]? {
  guard case let .array(array)? = value else {
    return nil
  }
  return array
}

func gmailBool(_ value: JSONValue?) -> Bool? {
  guard case let .bool(value)? = value else {
    return nil
  }
  return value
}

func gmailString(_ value: JSONValue?) -> String? {
  guard case let .string(value)? = value else {
    return nil
  }
  return value
}

func gmailNonEmptyString(_ value: JSONValue?) -> String? {
  guard let value = gmailString(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    return nil
  }
  return value
}

func gmailNumber(_ value: JSONValue?) -> Double? {
  guard case let .number(value)? = value else {
    return nil
  }
  return value
}

extension JSONValue {
  func gmailValue(at path: [String]) -> JSONValue? {
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

extension JSONEncoder {
  static var gmailPrettySorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
