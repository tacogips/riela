import RielaJavaScript
import XCTest

final class JavaScriptCoreBooleanEvaluatorTests: XCTestCase {
  func testEvaluatesBooleanExpressionWithObjectVariables() throws {
    let evaluator = JavaScriptCoreBooleanEvaluator()

    let matched = try evaluator.evaluateBoolean(
      expression: "telegram.message.text.includes('@mika') && telegram.chat.id === '100'",
      variables: [
        "telegram": [
          "message": ["text": "hello @mika"],
          "chat": ["id": "100"]
        ]
      ]
    )

    XCTAssertTrue(matched)
  }

  func testReturnsFalseForFalseBooleanExpression() throws {
    let matched = try JavaScriptCoreBooleanEvaluator().evaluateBoolean(
      expression: "telegram.message.text.includes('@mika')",
      variables: ["telegram": ["message": ["text": "hello @yui"]]]
    )

    XCTAssertFalse(matched)
  }

  func testEvaluatesRegexExpression() throws {
    let matched = try JavaScriptCoreBooleanEvaluator().evaluateBoolean(
      expression: "/(^|\\W)(mika|claude)(\\W|$)/i.test(telegram.message.text)",
      variables: ["telegram": ["message": ["text": "hello, Claude"]]]
    )

    XCTAssertTrue(matched)
  }

  func testThrowsSyntaxErrorOnInvalidJavaScript() {
    XCTAssertThrowsError(try JavaScriptCoreBooleanEvaluator().evaluateBoolean(
      expression: "telegram.message.text.includes(",
      variables: ["telegram": ["message": ["text": "hello"]]]
    )) { error in
      guard case .syntaxError = error as? JavaScriptBooleanEvaluationError else {
        XCTFail("Expected syntax error, got \(error)")
        return
      }
    }
  }

  func testThrowsOnRuntimeFailure() {
    XCTAssertThrowsError(try JavaScriptCoreBooleanEvaluator().evaluateBoolean(
      expression: "telegram.missing.text.includes('@mika')",
      variables: ["telegram": ["message": ["text": "hello"]]]
    ))
  }

  func testThrowsOnNonBooleanResult() {
    XCTAssertThrowsError(try JavaScriptCoreBooleanEvaluator().evaluateBoolean(
      expression: "telegram.message.text",
      variables: ["telegram": ["message": ["text": "hello"]]]
    )) { error in
      XCTAssertEqual(error as? JavaScriptBooleanEvaluationError, .nonBooleanResult("hello"))
    }
  }
}
