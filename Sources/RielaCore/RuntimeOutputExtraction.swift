import Foundation

public func parseJSONObjectCandidate(_ text: String, source: String) throws -> JSONObject {
  let candidate = extractJSONObjectCandidateText(text)
  guard let data = candidate.data(using: .utf8) else {
    throw AdapterExecutionError(.invalidOutput, "\(source) must return a JSON object: text is not UTF-8")
  }

  let decoded: JSONValue
  do {
    decoded = try JSONDecoder().decode(JSONValue.self, from: data)
  } catch {
    throw AdapterExecutionError(.invalidOutput, "\(source) must return a JSON object: \(error.localizedDescription)")
  }

  guard case let .object(object) = decoded else {
    throw AdapterExecutionError(.invalidOutput, "\(source) must return a top-level JSON object")
  }
  return object
}

private func extractJSONObjectCandidateText(_ text: String) -> String {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty {
    return trimmed
  }
  if isCompleteJSON(trimmed) {
    return trimmed
  }
  if trimmed.hasPrefix("{"), let candidate = extractBalancedJSONObject(from: trimmed, start: trimmed.startIndex) {
    return candidate
  }
  if let fenced = extractFirstFencedJSONBlock(from: trimmed) {
    return fenced
  }
  if let embedded = findFirstJSONObjectCandidate(in: trimmed) {
    return embedded
  }
  return trimmed
}

private func isCompleteJSON(_ text: String) -> Bool {
  guard let data = text.data(using: .utf8) else {
    return false
  }
  return (try? JSONSerialization.jsonObject(with: data)) != nil
}

private func extractFirstFencedJSONBlock(from text: String) -> String? {
  let pattern = #"```(?:json)?\s*([\s\S]*?)\s*```"#
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return nil
  }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  guard
    let match = regex.firstMatch(in: text, range: range),
    let contentRange = Range(match.range(at: 1), in: text)
  else {
    return nil
  }
  return String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func findFirstJSONObjectCandidate(in text: String) -> String? {
  var searchIndex = text.startIndex
  while searchIndex < text.endIndex {
    guard let objectStart = text[searchIndex...].firstIndex(of: "{") else {
      return nil
    }
    if let candidate = extractBalancedJSONObject(from: text, start: objectStart), isJSONObjectText(candidate) {
      return candidate
    }
    searchIndex = text.index(after: objectStart)
  }
  return nil
}

private func isJSONObjectText(_ text: String) -> Bool {
  guard let data = text.data(using: .utf8) else {
    return false
  }
  guard let value = try? JSONSerialization.jsonObject(with: data) else {
    return false
  }
  return value is [String: Any]
}

private func extractBalancedJSONObject(from text: String, start: String.Index) -> String? {
  var depth = 0
  var inString = false
  var escaped = false
  var index = start

  while index < text.endIndex {
    let character = text[index]

    if inString {
      if escaped {
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        inString = false
      }
      index = text.index(after: index)
      continue
    }

    if character == "\"" {
      inString = true
    } else if character == "{" {
      depth += 1
    } else if character == "}" {
      depth -= 1
      if depth == 0 {
        return String(text[start...index])
      }
    }
    index = text.index(after: index)
  }

  return nil
}
