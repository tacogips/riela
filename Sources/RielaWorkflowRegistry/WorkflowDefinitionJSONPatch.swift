import Foundation
import RielaCore

public enum WorkflowDefinitionJSONPatch {
  public static func apply(_ patch: JSONValue, to document: JSONValue) throws -> JSONValue {
    guard case let .array(operations) = patch else { throw invalidPatch("patch must be an array") }
    var result = document
    for operation in operations {
      guard case let .object(fields) = operation,
            case let .string(name)? = fields["op"],
            case let .string(pointer)? = fields["path"] else { throw invalidPatch("malformed patch operation") }
      let tokens = try decodePointer(pointer)
      switch name {
      case "add":
        guard let value = fields["value"] else { throw invalidPatch("add operation requires value") }
        try mutate(&result, tokens: tokens, operation: .add, value: value)
      case "remove": try mutate(&result, tokens: tokens, operation: .remove, value: nil)
      case "replace":
        guard let value = fields["value"] else { throw invalidPatch("replace operation requires value") }
        try mutate(&result, tokens: tokens, operation: .replace, value: value)
      case "test":
        guard let value = fields["value"] else { throw invalidPatch("test operation requires value") }
        guard try read(result, tokens: tokens) == value else { throw invalidPatch("test operation failed at \(pointer)") }
      default: throw invalidPatch("unsupported patch operation \(name)")
      }
    }
    return result
  }

  public static func pointer(_ tokens: [String]) -> String {
    tokens.map { "/" + $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined()
  }

  private enum Mutation { case add, remove, replace }

  private static func decodePointer(_ pointer: String) throws -> [String] {
    if pointer.isEmpty { return [] }
    guard pointer.hasPrefix("/") else { throw invalidPatch("pointer must start with slash") }
    return try pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { token in
      var decoded = ""
      var index = token.startIndex
      while index < token.endIndex {
        if token[index] == "~" {
          let next = token.index(after: index)
          guard next < token.endIndex else { throw invalidPatch("malformed pointer escape") }
          switch token[next] {
          case "0": decoded += "~"
          case "1": decoded += "/"
          default: throw invalidPatch("malformed pointer escape")
          }
          index = token.index(after: next)
        } else {
          decoded.append(token[index])
          index = token.index(after: index)
        }
      }
      return decoded
    }
  }

  private static func read(_ document: JSONValue, tokens: [String]) throws -> JSONValue {
    guard let first = tokens.first else { return document }
    switch document {
    case let .object(values):
      guard let child = values[first] else { throw invalidPatch("missing target") }
      return try read(child, tokens: Array(tokens.dropFirst()))
    case let .array(values):
      guard let index = arrayIndex(first, count: values.count), index < values.count else { throw invalidPatch("missing array target") }
      return try read(values[index], tokens: Array(tokens.dropFirst()))
    default: throw invalidPatch("pointer traverses a scalar")
    }
  }

  private static func mutate(_ document: inout JSONValue, tokens: [String], operation: Mutation, value: JSONValue?) throws {
    guard let last = tokens.last else {
      switch operation {
      case .add, .replace: document = value!
      case .remove: throw invalidPatch("cannot remove document root")
      }
      return
    }
    try mutateChild(&document, parents: Array(tokens.dropLast()), key: last, operation: operation, value: value)
  }

  private static func mutateChild(_ node: inout JSONValue, parents: [String], key: String, operation: Mutation, value: JSONValue?) throws {
    if let first = parents.first {
      switch node {
      case var .object(values):
        guard var child = values[first] else { throw invalidPatch("missing parent") }
        try mutateChild(&child, parents: Array(parents.dropFirst()), key: key, operation: operation, value: value)
        values[first] = child
        node = .object(values)
      case var .array(values):
        guard let index = arrayIndex(first, count: values.count), index < values.count else { throw invalidPatch("missing array parent") }
        var child = values[index]
        try mutateChild(&child, parents: Array(parents.dropFirst()), key: key, operation: operation, value: value)
        values[index] = child
        node = .array(values)
      default: throw invalidPatch("pointer traverses a scalar")
      }
      return
    }
    switch node {
    case var .object(values):
      switch operation {
      case .add: values[key] = value
      case .remove: guard values.removeValue(forKey: key) != nil else { throw invalidPatch("missing remove target") }
      case .replace: guard values[key] != nil else { throw invalidPatch("missing replace target") }; values[key] = value
      }
      node = .object(values)
    case var .array(values):
      if operation == .add {
        let index = key == "-" ? values.count : try arrayInsertionIndex(key, count: values.count)
        values.insert(value!, at: index)
      } else {
        guard let index = arrayIndex(key, count: values.count), index < values.count else { throw invalidPatch("missing array target") }
        if operation == .remove { values.remove(at: index) } else { values[index] = value! }
      }
      node = .array(values)
    default: throw invalidPatch("pointer parent is a scalar")
    }
  }

  private static func arrayIndex(_ token: String, count: Int) -> Int? {
    guard !token.isEmpty, token == "0" || !token.hasPrefix("0"), let index = Int(token), index >= 0, index < count else { return nil }
    return index
  }

  private static func arrayInsertionIndex(_ token: String, count: Int) throws -> Int {
    guard let index = Int(token), index >= 0, index <= count, token == String(index) else { throw invalidPatch("invalid array insertion index") }
    return index
  }

  private static func invalidPatch(_ message: String) -> WorkflowDefinitionServiceError {
    WorkflowDefinitionServiceError(code: .invalidPatch, message: message)
  }
}
