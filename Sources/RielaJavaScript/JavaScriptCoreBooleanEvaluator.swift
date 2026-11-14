import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

public enum JavaScriptBooleanEvaluationError: Error, Equatable, Sendable, CustomStringConvertible {
  case contextCreationFailed
  case unavailable(String)
  case syntaxError(String)
  case exception(String)
  case nonBooleanResult(String)

  public var description: String {
    switch self {
    case .contextCreationFailed:
      "JavaScriptCore context creation failed"
    case let .unavailable(message):
      message
    case let .syntaxError(message):
      "JavaScript syntax error: \(message)"
    case let .exception(message):
      "JavaScript exception: \(message)"
    case let .nonBooleanResult(type):
      "JavaScript expression must return a boolean, got \(type)"
    }
  }
}

public struct JavaScriptCoreBooleanEvaluator: Sendable {
  public init() {}

  public func evaluateBoolean(expression: String, variables: [String: Any]) throws -> Bool {
    #if canImport(JavaScriptCore)
    guard let context = JSContext() else {
      throw JavaScriptBooleanEvaluationError.contextCreationFailed
    }

    var exception: String?
    context.exceptionHandler = { _, value in
      exception = value?.toString() ?? "unknown JavaScript exception"
    }

    for (name, value) in variables {
      context.setObject(value, forKeyedSubscript: name as NSString)
    }

    let wrappedExpression = "(function() { return (\(expression)); })()"
    guard let result = context.evaluateScript(wrappedExpression) else {
      throw JavaScriptBooleanEvaluationError.contextCreationFailed
    }
    if let exception {
      if exception.contains("SyntaxError") {
        throw JavaScriptBooleanEvaluationError.syntaxError(exception)
      }
      throw JavaScriptBooleanEvaluationError.exception(exception)
    }
    guard result.isBoolean else {
      throw JavaScriptBooleanEvaluationError.nonBooleanResult(result.toString() ?? "unknown")
    }
    return result.toBool()
    #else
    _ = expression
    _ = variables
    throw JavaScriptBooleanEvaluationError.unavailable(
      "JavaScript expression filters require JavaScriptCore on this platform"
    )
    #endif
  }
}
