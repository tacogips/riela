import Foundation
import RielaCore

func nonEmptyStringValue(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value, !text.isEmpty else {
    return nil
  }
  return text
}

func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}

func firstNonEmptyString(_ values: JSONValue?...) -> String? {
  values.compactMap(nonEmptyStringValue).first
}

func firstBool(_ values: JSONValue?...) -> Bool? {
  values.compactMap(boolValue).first
}

private func boolValue(_ value: JSONValue?) -> Bool? {
  switch value {
  case let .bool(flag):
    flag
  case let .string(text):
    switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "1", "yes", "on":
      true
    case "false", "0", "no", "off":
      false
    default:
      nil
    }
  default:
    nil
  }
}
