import Foundation

public struct WorkflowConditionSpan: Equatable, Sendable {
  public let start: Int
  public let end: Int

  public init(start: Int, end: Int) {
    self.start = start
    self.end = end
  }
}

public enum WorkflowConditionValueSource: Equatable, Sendable {
  case when, payload, legacyDefault, analysis
}

public enum WorkflowConditionLookupResult: Equatable, Sendable {
  case missing
  case wrongType
  case boolean(Bool, source: WorkflowConditionValueSource)
}

public enum WorkflowConditionError: Error, Equatable, Sendable {
  case syntax(WorkflowConditionSpan)
  case missing(identifier: String, span: WorkflowConditionSpan)
  case wrongType(identifier: String, span: WorkflowConditionSpan)
}

public struct ParsedWorkflowCondition: Equatable, Sendable {
  public struct IdentifierUse: Equatable, Sendable {
    public let name: String
    public let span: WorkflowConditionSpan
  }

  indirect enum Expression: Equatable, Sendable {
    case literal(Bool)
    case identifier(IdentifierUse)
    case not(Expression)
    case and(Expression, Expression)
    case or(Expression, Expression)
  }

  let expression: Expression
  public let identifiers: [IdentifierUse]

  public init(_ source: String) throws {
    var parser = try WorkflowConditionParser(source)
    expression = try parser.parse()
    identifiers = parser.identifiers
  }

  public func evaluate(lookup: (String) -> WorkflowConditionLookupResult) throws -> Bool {
    try evaluate(expression, lookup: lookup)
  }

  private func evaluate(
    _ expression: Expression,
    lookup: (String) -> WorkflowConditionLookupResult
  ) throws -> Bool {
    switch expression {
    case let .literal(value): return value
    case let .identifier(use):
      switch lookup(use.name) {
      case .missing: throw WorkflowConditionError.missing(identifier: use.name, span: use.span)
      case .wrongType: throw WorkflowConditionError.wrongType(identifier: use.name, span: use.span)
      case let .boolean(value, _): return value
      }
    case let .not(child): return try !evaluate(child, lookup: lookup)
    case let .and(lhs, rhs):
      let left = try evaluate(lhs, lookup: lookup)
      let right = try evaluate(rhs, lookup: lookup)
      return left && right
    case let .or(lhs, rhs):
      let left = try evaluate(lhs, lookup: lookup)
      let right = try evaluate(rhs, lookup: lookup)
      return left || right
    }
  }
}

private struct WorkflowConditionParser {
  private enum Kind: Equatable {
    case and, or, not, leftParen, rightParen, identifier(String)
  }

  private struct Token {
    let kind: Kind
    let span: WorkflowConditionSpan
  }

  private let tokens: [Token]
  private let sourceLength: Int
  private var index = 0
  private(set) var identifiers: [ParsedWorkflowCondition.IdentifierUse] = []

  init(_ source: String) throws {
    let characters = Array(source)
    sourceLength = characters.count
    var result: [Token] = []
    var offset = 0
    while offset < characters.count {
      let character = characters[offset]
      if character.isWhitespace { offset += 1; continue }
      let start = offset
      if character == "&", offset + 1 < characters.count, characters[offset + 1] == "&" {
        offset += 2
        result.append(Token(kind: .and, span: .init(start: start, end: offset)))
      } else if character == "|", offset + 1 < characters.count, characters[offset + 1] == "|" {
        offset += 2
        result.append(Token(kind: .or, span: .init(start: start, end: offset)))
      } else if character == "!" || character == "(" || character == ")" {
        offset += 1
        let kind: Kind = character == "!" ? .not : (character == "(" ? .leftParen : .rightParen)
        result.append(Token(kind: kind, span: .init(start: start, end: offset)))
      } else if character.isWorkflowIdentifierStart {
        offset += 1
        while offset < characters.count, characters[offset].isWorkflowIdentifierContinuation {
          offset += 1
        }
        result.append(Token(kind: .identifier(String(characters[start..<offset])),
                            span: .init(start: start, end: offset)))
      } else {
        throw WorkflowConditionError.syntax(.init(start: start, end: start + 1))
      }
    }
    tokens = result
  }

  mutating func parse() throws -> ParsedWorkflowCondition.Expression {
    let result = try parseOr()
    if let token = current { throw WorkflowConditionError.syntax(token.span) }
    return result
  }

  private mutating func parseOr() throws -> ParsedWorkflowCondition.Expression {
    var result = try parseAnd()
    while current?.kind == .or {
      index += 1
      result = .or(result, try parseAnd())
    }
    return result
  }

  private mutating func parseAnd() throws -> ParsedWorkflowCondition.Expression {
    var result = try parseUnary()
    while current?.kind == .and {
      index += 1
      result = .and(result, try parseUnary())
    }
    return result
  }

  private mutating func parseUnary() throws -> ParsedWorkflowCondition.Expression {
    if current?.kind == .not {
      index += 1
      return .not(try parseUnary())
    }
    return try parsePrimary()
  }

  private mutating func parsePrimary() throws -> ParsedWorkflowCondition.Expression {
    guard let token = current else {
      throw WorkflowConditionError.syntax(.init(start: sourceLength, end: sourceLength))
    }
    index += 1
    switch token.kind {
    case .leftParen:
      let expression = try parseOr()
      guard current?.kind == .rightParen else {
        throw WorkflowConditionError.syntax(current?.span ?? .init(start: sourceLength, end: sourceLength))
      }
      index += 1
      return expression
    case let .identifier(name):
      switch name {
      case "true", "always": return .literal(true)
      case "false", "never": return .literal(false)
      default:
        let use = ParsedWorkflowCondition.IdentifierUse(name: name, span: token.span)
        identifiers.append(use)
        return .identifier(use)
      }
    default:
      throw WorkflowConditionError.syntax(token.span)
    }
  }

  private var current: Token? { index < tokens.count ? tokens[index] : nil }
}

private extension Character {
  var isWorkflowIdentifierStart: Bool {
    guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
    return scalar.value == 95 || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
  }

  var isWorkflowIdentifierContinuation: Bool {
    guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
    return isWorkflowIdentifierStart || scalar.value == 45 || (48...57).contains(scalar.value)
  }
}
