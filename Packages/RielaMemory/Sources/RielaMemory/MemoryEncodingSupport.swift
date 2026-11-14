import Foundation

func encodedJSONString(_ value: MemoryJSONValue) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(value)
  guard let string = String(data: data, encoding: .utf8) else {
    throw RielaMemoryError.invalidJSON("encoded JSON is not UTF-8")
  }
  return string
}

func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(value)
  guard let string = String(data: data, encoding: .utf8) else {
    throw RielaMemoryError.invalidJSON("encoded JSON is not UTF-8")
  }
  return string
}

func placeholders(_ count: Int) -> String {
  Array(repeating: "?", count: count).joined(separator: ", ")
}

func nonEmpty(_ value: String?) -> String? {
  guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
    return nil
  }
  return trimmed
}

func currentTimestamp() -> String {
  ISO8601DateFormatter().string(from: Date())
}
