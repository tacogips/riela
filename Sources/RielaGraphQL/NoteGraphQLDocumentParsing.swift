import Foundation
import RielaCore

public enum NoteGraphQLDocumentLimits {
  public static let maximumDocumentUTF8Bytes = 512 * 1024
  static let maximumSelectionDepth = 20
  static let maximumValueDepth = 10
  static let maximumBalancedBlockDepth = 64
}

enum GraphQLDocumentOperationType {
  case query
  case mutation
}

struct ParsedNoteGraphQLRootField {
  var operationType: GraphQLDocumentOperationType
  var fieldName: String
  var responseKey: String
  var arguments: JSONObject
  var selections: [ParsedNoteGraphQLSelectionField]
}

struct ParsedNoteGraphQLSelectionField {
  var fieldName: String
  var responseKey: String
  var selections: [ParsedNoteGraphQLSelectionField]
}

func parseNoteGraphQLRootField(
  in query: String,
  operationName: String?,
  variables: JSONObject,
  parseArguments: Bool
) throws -> ParsedNoteGraphQLRootField? {
  guard let fields = try parseNoteGraphQLRootFields(
    in: query,
    operationName: operationName,
    variables: variables,
    parseArguments: parseArguments
  ) else {
    return nil
  }
  guard fields.count <= 1 else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection(
      "GraphQL note documents must contain exactly one root selection"
    )
  }
  return fields.first
}

func parseNoteGraphQLRootFields(
  in query: String,
  operationName: String?,
  variables: JSONObject,
  parseArguments: Bool
) throws -> [ParsedNoteGraphQLRootField]? {
  try validateNoteGraphQLDocumentLength(query)
  if operationName == nil, try graphQLExecutableOperationCount(in: query) > 1 {
    throw NoteGraphQLDocumentExecutorError.invalidSelection(
      "GraphQL operationName is required when a document contains multiple operations"
    )
  }
  var index = query.startIndex
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex else {
      return nil
    }
    if query[index] == "{" {
      guard operationName == nil else {
        try skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
        continue
      }
      return try parseGraphQLRootSelections(
        in: query,
        index: &index,
        operationType: .query,
        variables: variables,
        parseArguments: parseArguments
      )
    }
    guard let operation = readGraphQLIdentifier(in: query, index: &index) else {
      return nil
    }
    if operation == "fragment" {
      try skipGraphQLDefinition(in: query, index: &index)
      continue
    }
    let operationType: GraphQLDocumentOperationType
    switch operation {
    case "query":
      operationType = .query
    case "mutation":
      operationType = .mutation
    default:
      return nil
    }
    let parsedOperationName = readOptionalGraphQLIdentifier(in: query, index: &index)
    skipGraphQLIgnored(in: query, index: &index)
    var operationVariables = variables
    if index < query.endIndex, query[index] == "(" {
      let defaultVariables = try parseGraphQLVariableDefinitions(in: query, index: &index)
      operationVariables = defaultVariables.merging(variables) { _, provided in provided }
    }
    guard try advanceToGraphQLSelectionSet(in: query, index: &index) else {
      return nil
    }
    if let operationName, parsedOperationName != operationName {
      try skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
      continue
    }
    return try parseGraphQLRootSelections(
      in: query,
      index: &index,
      operationType: operationType,
      variables: operationVariables,
      parseArguments: parseArguments
    )
  }
  return nil
}

public func noteGraphQLNamedOperationNames(in query: String) -> Set<String> {
  guard query.utf8.count <= NoteGraphQLDocumentLimits.maximumDocumentUTF8Bytes else {
    return []
  }
  var index = query.startIndex
  var names = Set<String>()
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex else {
      return names
    }
    if query[index] == "\"" {
      try? skipGraphQLStringLiteral(in: query, index: &index)
      continue
    }
    guard let operation = readGraphQLIdentifier(in: query, index: &index) else {
      index = query.index(after: index)
      continue
    }
    guard ["query", "mutation", "subscription"].contains(operation) else {
      continue
    }
    if let name = readOptionalGraphQLIdentifier(in: query, index: &index) {
      names.insert(name)
    }
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "(" {
      try? skipGraphQLBalanced(in: query, index: &index, open: "(", close: ")")
    }
    if (try? advanceToGraphQLSelectionSet(in: query, index: &index)) == true {
      try? skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
    }
  }
  return names
}

private func graphQLExecutableOperationCount(in query: String) throws -> Int {
  var index = query.startIndex
  var count = 0
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex else {
      return count
    }
    if query[index] == "{" {
      count += 1
      try skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
      continue
    }
    guard let operation = readGraphQLIdentifier(in: query, index: &index) else {
      index = query.index(after: index)
      continue
    }
    if operation == "fragment" {
      try skipGraphQLDefinition(in: query, index: &index)
      continue
    }
    guard ["query", "mutation", "subscription"].contains(operation) else {
      continue
    }
    count += 1
    _ = readOptionalGraphQLIdentifier(in: query, index: &index)
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "(" {
      try skipGraphQLBalanced(in: query, index: &index, open: "(", close: ")")
    }
    if try advanceToGraphQLSelectionSet(in: query, index: &index) {
      try skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
    }
  }
  return count
}

private func validateNoteGraphQLDocumentLength(_ query: String) throws {
  guard query.utf8.count <= NoteGraphQLDocumentLimits.maximumDocumentUTF8Bytes else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL document size limit exceeded")
  }
}

private func parseGraphQLRootSelections(
  in query: String,
  index: inout String.Index,
  operationType: GraphQLDocumentOperationType,
  variables: JSONObject,
  parseArguments: Bool
) throws -> [ParsedNoteGraphQLRootField] {
  guard index < query.endIndex, query[index] == "{" else {
    return []
  }
  index = query.index(after: index)
  var fields: [ParsedNoteGraphQLRootField] = []
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "}" {
      index = query.index(after: index)
      return fields
    }
    guard !query[index...].hasPrefix("...") else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL fragments are not supported in note documents")
    }
    guard let first = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL root selection is missing a field name")
    }
    var responseKey = first
    var fieldName = first
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == ":" {
      index = query.index(after: index)
      guard let aliasedFieldName = readGraphQLIdentifier(in: query, index: &index) else {
        throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL alias is missing a field name")
      }
      responseKey = first
      fieldName = aliasedFieldName
    }
    var arguments: JSONObject = [:]
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "(" {
      if parseArguments {
        arguments = try parseGraphQLArguments(in: query, index: &index, variables: variables)
      } else {
        try skipGraphQLBalanced(in: query, index: &index, open: "(", close: ")")
      }
    }
    let selections: [ParsedNoteGraphQLSelectionField]
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "{" {
      selections = try parseGraphQLSelectionSet(in: query, index: &index, depth: 1)
    } else {
      selections = []
    }
    fields.append(ParsedNoteGraphQLRootField(
      operationType: operationType,
      fieldName: fieldName,
      responseKey: responseKey,
      arguments: arguments,
      selections: selections
    ))
  }
  throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL root selection set was not closed")
}

private func parseGraphQLSelectionSet(
  in query: String,
  index: inout String.Index,
  depth: Int
) throws -> [ParsedNoteGraphQLSelectionField] {
  guard index < query.endIndex, query[index] == "{" else {
    return []
  }
  guard depth <= NoteGraphQLDocumentLimits.maximumSelectionDepth else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL selection depth limit exceeded")
  }
  index = query.index(after: index)
  var selections: [ParsedNoteGraphQLSelectionField] = []
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "}" {
      index = query.index(after: index)
      return selections
    }
    if query[index...].hasPrefix("...") {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL fragments are not supported in note documents")
    }
    guard let first = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL selection is missing a field name")
    }
    var responseKey = first
    var fieldName = first
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == ":" {
      index = query.index(after: index)
      guard let aliasedFieldName = readGraphQLIdentifier(in: query, index: &index) else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL alias is missing a field name")
      }
      responseKey = first
      fieldName = aliasedFieldName
    }
    try skipGraphQLSelectionSuffix(in: query, index: &index)
    let nestedSelections: [ParsedNoteGraphQLSelectionField]
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "{" {
      nestedSelections = try parseGraphQLSelectionSet(in: query, index: &index, depth: depth + 1)
    } else {
      nestedSelections = []
    }
    selections.append(ParsedNoteGraphQLSelectionField(
      fieldName: fieldName,
      responseKey: responseKey,
      selections: nestedSelections
    ))
  }
  throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL selection set was not closed")
}

private func skipGraphQLSelectionSuffix(in query: String, index: inout String.Index) throws {
  var keepSkipping = true
  while keepSkipping, index < query.endIndex {
    keepSkipping = false
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "(" {
      try skipGraphQLBalanced(in: query, index: &index, open: "(", close: ")")
      keepSkipping = true
    }
    skipGraphQLIgnored(in: query, index: &index)
    while index < query.endIndex, query[index] == "@" {
      index = query.index(after: index)
      guard readGraphQLIdentifier(in: query, index: &index) != nil else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL directive is missing a name")
      }
      skipGraphQLIgnored(in: query, index: &index)
      if index < query.endIndex, query[index] == "(" {
        try skipGraphQLBalanced(in: query, index: &index, open: "(", close: ")")
      }
      keepSkipping = true
      skipGraphQLIgnored(in: query, index: &index)
    }
  }
}

private func parseGraphQLArguments(
  in query: String,
  index: inout String.Index,
  variables: JSONObject
) throws -> JSONObject {
  guard index < query.endIndex, query[index] == "(" else {
    return [:]
  }
  index = query.index(after: index)
  var arguments: JSONObject = [:]
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == ")" {
      index = query.index(after: index)
      return arguments
    }
    guard let name = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL argument is missing a name")
    }
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex, query[index] == ":" else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL argument '\(name)' is missing ':'")
    }
    index = query.index(after: index)
    arguments[name] = try parseGraphQLValue(in: query, index: &index, variables: variables, depth: 1)
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL arguments were not closed")
}

private func parseGraphQLValue(
  in query: String,
  index: inout String.Index,
  variables: JSONObject,
  depth: Int
) throws -> JSONValue {
  guard depth <= NoteGraphQLDocumentLimits.maximumValueDepth else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL value depth limit exceeded")
  }
  skipGraphQLIgnored(in: query, index: &index)
  guard index < query.endIndex else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL value is missing")
  }
  switch query[index] {
  case "$":
    index = query.index(after: index)
    guard let variableName = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL variable is missing a name")
    }
    guard let value = variables[variableName] else {
      throw NoteGraphQLDocumentExecutorError.missingVariable(variableName)
    }
    return value
  case "\"":
    return .string(try readGraphQLString(in: query, index: &index))
  case "[":
    return try parseGraphQLArray(in: query, index: &index, variables: variables, depth: depth)
  case "{":
    return try parseGraphQLObject(in: query, index: &index, variables: variables, depth: depth)
  default:
    if query[index] == "-" || query[index].isNumber {
      return try parseGraphQLNumber(in: query, index: &index)
    }
    guard let identifier = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("unsupported GraphQL value")
    }
    switch identifier {
    case "true":
      return .bool(true)
    case "false":
      return .bool(false)
    case "null":
      return .null
    default:
      return .string(identifier)
    }
  }
}

private func parseGraphQLArray(
  in query: String,
  index: inout String.Index,
  variables: JSONObject,
  depth: Int
) throws -> JSONValue {
  index = query.index(after: index)
  var values: [JSONValue] = []
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "]" {
      index = query.index(after: index)
      return .array(values)
    }
    values.append(try parseGraphQLValue(in: query, index: &index, variables: variables, depth: depth + 1))
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL array was not closed")
}

private func parseGraphQLObject(
  in query: String,
  index: inout String.Index,
  variables: JSONObject,
  depth: Int
) throws -> JSONValue {
  index = query.index(after: index)
  var object: JSONObject = [:]
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "}" {
      index = query.index(after: index)
      return .object(object)
    }
    let key: String
    if index < query.endIndex, query[index] == "\"" {
      key = try readGraphQLString(in: query, index: &index)
    } else if let identifier = readGraphQLIdentifier(in: query, index: &index) {
      key = identifier
    } else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL object key is missing")
    }
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex, query[index] == ":" else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL object key '\(key)' is missing ':'")
    }
    index = query.index(after: index)
    object[key] = try parseGraphQLValue(in: query, index: &index, variables: variables, depth: depth + 1)
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL object was not closed")
}

private func parseGraphQLVariableDefinitions(
  in query: String,
  index: inout String.Index
) throws -> JSONObject {
  guard index < query.endIndex, query[index] == "(" else {
    return [:]
  }
  index = query.index(after: index)
  var defaults: JSONObject = [:]
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == ")" {
      index = query.index(after: index)
      return defaults
    }
    guard index < query.endIndex, query[index] == "$" else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL variable definition is missing '$'")
    }
    index = query.index(after: index)
    guard let variableName = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL variable definition is missing a name")
    }
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex, query[index] == ":" else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL variable '\(variableName)' is missing a type")
    }
    index = query.index(after: index)
    try skipGraphQLTypeReference(in: query, index: &index)
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "=" {
      index = query.index(after: index)
      defaults[variableName] = try parseGraphQLValue(in: query, index: &index, variables: [:], depth: 1)
    }
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL variable definitions were not closed")
}

private func skipGraphQLTypeReference(in query: String, index: inout String.Index) throws {
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex else {
      return
    }
    if query[index] == "=" || query[index] == ")" || query[index] == "," || query[index] == "$" {
      return
    }
    if readOptionalGraphQLIdentifier(in: query, index: &index) != nil {
      continue
    }
    if query[index] == "[" || query[index] == "]" || query[index] == "!" {
      index = query.index(after: index)
      continue
    }
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL variable type is invalid")
  }
}

private func parseGraphQLNumber(in query: String, index: inout String.Index) throws -> JSONValue {
  let start = index
  var isFloatingPoint = false
  if index < query.endIndex, query[index] == "-" {
    index = query.index(after: index)
  }
  while index < query.endIndex, query[index].isNumber {
    index = query.index(after: index)
  }
  if index < query.endIndex, query[index] == "." {
    isFloatingPoint = true
    index = query.index(after: index)
    while index < query.endIndex, query[index].isNumber {
      index = query.index(after: index)
    }
  }
  if index < query.endIndex, query[index] == "e" || query[index] == "E" {
    isFloatingPoint = true
    index = query.index(after: index)
    if index < query.endIndex, query[index] == "-" || query[index] == "+" {
      index = query.index(after: index)
    }
    while index < query.endIndex, query[index].isNumber {
      index = query.index(after: index)
    }
  }
  let raw = String(query[start..<index])
  if isFloatingPoint, let value = Double(raw) {
    return .number(value)
  }
  if let value = Int64(raw) {
    return .integer(value)
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("invalid GraphQL number: \(raw)")
}

private func readGraphQLIdentifier(in query: String, index: inout String.Index) -> String? {
  skipGraphQLIgnored(in: query, index: &index)
  return readOptionalGraphQLIdentifier(in: query, index: &index)
}

private func readOptionalGraphQLIdentifier(in query: String, index: inout String.Index) -> String? {
  skipGraphQLIgnored(in: query, index: &index)
  guard index < query.endIndex, isGraphQLNameStart(query[index]) else {
    return nil
  }
  let start = index
  index = query.index(after: index)
  while index < query.endIndex, isGraphQLNameContinue(query[index]) {
    index = query.index(after: index)
  }
  return String(query[start..<index])
}

private func readGraphQLString(in query: String, index: inout String.Index) throws -> String {
  guard index < query.endIndex, query[index] == "\"" else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL string is missing opening quote")
  }
  if query[index...].hasPrefix("\"\"\"") {
    return try readGraphQLBlockString(in: query, index: &index)
  }
  index = query.index(after: index)
  var result = ""
  while index < query.endIndex {
    let character = query[index]
    index = query.index(after: index)
    if character == "\"" {
      return result
    }
    if character == "\\" {
      guard index < query.endIndex else {
        throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL string escape is incomplete")
      }
      let escaped = query[index]
      index = query.index(after: index)
      switch escaped {
      case "\"", "\\", "/":
        result.append(escaped)
      case "b":
        result.append("\u{8}")
      case "f":
        result.append("\u{c}")
      case "n":
        result.append("\n")
      case "r":
        result.append("\r")
      case "t":
        result.append("\t")
      case "u":
        result.append(try readGraphQLUnicodeEscape(in: query, index: &index))
      default:
        throw NoteGraphQLDocumentExecutorError.invalidVariable("unsupported GraphQL string escape: \\\(escaped)")
      }
    } else if character.isNewline {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL string contains an unescaped newline")
    } else {
      result.append(character)
    }
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL string was not closed")
}

private func readGraphQLBlockString(in query: String, index: inout String.Index) throws -> String {
  guard query[index...].hasPrefix("\"\"\"") else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL block string is missing opening quote")
  }
  index = query.index(index, offsetBy: 3)
  var result = ""
  while index < query.endIndex {
    if query[index...].hasPrefix("\\\"\"\"") {
      result.append("\"\"\"")
      index = query.index(index, offsetBy: 4)
      continue
    }
    if query[index...].hasPrefix("\"\"\"") {
      index = query.index(index, offsetBy: 3)
      return normalizedGraphQLBlockString(result)
    }
    result.append(query[index])
    index = query.index(after: index)
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL block string was not closed")
}

private func normalizedGraphQLBlockString(_ raw: String) -> String {
  let normalized = raw
    .replacingOccurrences(of: "\r\n", with: "\n")
    .replacingOccurrences(of: "\r", with: "\n")
  var lines = normalized.components(separatedBy: "\n")
  while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
    lines.removeFirst()
  }
  while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
    lines.removeLast()
  }
  guard !lines.isEmpty else {
    return ""
  }
  let firstIndent = graphQLBlockStringIndent(lines[0])
  let indentCandidates = firstIndent == 0 ? lines.dropFirst() : lines[...].dropLast(0)
  let commonIndent = indentCandidates
    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    .map(graphQLBlockStringIndent)
    .min() ?? 0
  guard commonIndent > 0 else {
    return lines.joined(separator: "\n")
  }
  return lines.enumerated().map { index, line in
    if firstIndent == 0, index == 0 {
      return line
    }
    return String(line.dropFirst(min(commonIndent, line.count)))
  }.joined(separator: "\n")
}

private func graphQLBlockStringIndent(_ line: String) -> Int {
  line.prefix { $0 == " " || $0 == "\t" }.count
}

private func readGraphQLUnicodeEscape(in query: String, index: inout String.Index) throws -> Character {
  if index < query.endIndex, query[index] == "{" {
    index = query.index(after: index)
    let start = index
    while index < query.endIndex, query[index] != "}" {
      index = query.index(after: index)
    }
    guard index < query.endIndex, query[index] == "}" else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode escape was not closed")
    }
    let hex = String(query[start..<index])
    index = query.index(after: index)
    return try graphQLUnicodeScalar(from: hex)
  }
  let start = index
  for _ in 0..<4 {
    guard index < query.endIndex else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode escape is incomplete")
    }
    index = query.index(after: index)
  }
  let value = try graphQLUnicodeScalarValue(from: String(query[start..<index]))
  if (0xD800...0xDBFF).contains(value) {
    guard
      index < query.endIndex,
      query[index] == "\\",
      query.index(after: index) < query.endIndex,
      query[query.index(after: index)] == "u"
    else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode high surrogate is missing a low surrogate")
    }
    index = query.index(index, offsetBy: 2)
    let lowStart = index
    for _ in 0..<4 {
      guard index < query.endIndex else {
        throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode low surrogate is incomplete")
      }
      index = query.index(after: index)
    }
    let low = try graphQLUnicodeScalarValue(from: String(query[lowStart..<index]))
    guard (0xDC00...0xDFFF).contains(low) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode high surrogate is missing a low surrogate")
    }
    let combined = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
    return try graphQLUnicodeScalar(from: combined)
  }
  guard !(0xDC00...0xDFFF).contains(value) else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode low surrogate is missing a high surrogate")
  }
  return try graphQLUnicodeScalar(from: value)
}

private func graphQLUnicodeScalar(from hex: String) throws -> Character {
  try graphQLUnicodeScalar(from: graphQLUnicodeScalarValue(from: hex))
}

private func graphQLUnicodeScalarValue(from hex: String) throws -> UInt32 {
  guard
    !hex.isEmpty,
    hex.allSatisfy(\.isHexDigit),
    let value = UInt32(hex, radix: 16)
  else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode escape is invalid")
  }
  return value
}

private func graphQLUnicodeScalar(from value: UInt32) throws -> Character {
  guard let scalar = UnicodeScalar(value) else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode escape is invalid")
  }
  return Character(scalar)
}

private func skipGraphQLIgnored(in query: String, index: inout String.Index) {
  while index < query.endIndex {
    if query[index].isWhitespace || query[index] == "," {
      index = query.index(after: index)
    } else if query[index] == "#" {
      skipGraphQLComment(in: query, index: &index)
    } else {
      break
    }
  }
}

private func skipGraphQLComment(in query: String, index: inout String.Index) {
  while index < query.endIndex, !query[index].isNewline {
    index = query.index(after: index)
  }
}

private func skipGraphQLDefinition(in query: String, index: inout String.Index) throws {
  guard try advanceToGraphQLSelectionSet(in: query, index: &index) else {
    return
  }
  try skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
}

private func advanceToGraphQLSelectionSet(in query: String, index: inout String.Index) throws -> Bool {
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex else {
      return false
    }
    if query[index] == "{" {
      return true
    }
    if query[index] == "(" {
      try skipGraphQLBalanced(in: query, index: &index, open: "(", close: ")")
    } else if query[index] == "\"" {
      try skipGraphQLStringLiteral(in: query, index: &index)
    } else {
      index = query.index(after: index)
    }
  }
  return false
}

private func skipGraphQLBalanced(
  in query: String,
  index: inout String.Index,
  open: Character,
  close: Character
) throws {
  guard index < query.endIndex, query[index] == open else {
    return
  }
  var depth = 0
  while index < query.endIndex {
    if query[index] == "\"" {
      try skipGraphQLStringLiteral(in: query, index: &index)
      continue
    }
    if query[index] == "#" {
      skipGraphQLComment(in: query, index: &index)
      continue
    }
    if query[index] == open {
      depth += 1
      if depth > NoteGraphQLDocumentLimits.maximumBalancedBlockDepth {
        throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL block depth limit exceeded")
      }
    } else if query[index] == close {
      depth -= 1
      index = query.index(after: index)
      if depth == 0 {
        return
      }
      continue
    }
    index = query.index(after: index)
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL block was not closed")
}

private func skipGraphQLStringLiteral(in query: String, index: inout String.Index) throws {
  guard index < query.endIndex, query[index] == "\"" else {
    return
  }
  if query[index...].hasPrefix("\"\"\"") {
    index = query.index(index, offsetBy: 3)
    while index < query.endIndex {
      if query[index...].hasPrefix("\\\"\"\"") {
        index = query.index(index, offsetBy: 4)
      } else if query[index...].hasPrefix("\"\"\"") {
        index = query.index(index, offsetBy: 3)
        return
      } else {
        index = query.index(after: index)
      }
    }
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL block string was not closed")
  }
  index = query.index(after: index)
  while index < query.endIndex {
    if query[index] == "\\" {
      index = query.index(after: index)
      if index < query.endIndex {
        index = query.index(after: index)
      }
    } else if query[index] == "\"" {
      index = query.index(after: index)
      return
    } else {
      index = query.index(after: index)
    }
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL string was not closed")
}

private func isGraphQLNameStart(_ character: Character) -> Bool {
  guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
    return false
  }
  return scalar.value == 95
    || (65...90).contains(scalar.value)
    || (97...122).contains(scalar.value)
}

private func isGraphQLNameContinue(_ character: Character) -> Bool {
  guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
    return false
  }
  return isGraphQLNameStart(character) || (48...57).contains(scalar.value)
}
