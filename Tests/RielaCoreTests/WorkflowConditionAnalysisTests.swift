import XCTest
@testable import RielaCore

final class WorkflowConditionAnalysisTests: XCTestCase {
  func testIdentifiersAndPrecedencePreserveCompleteExpression() throws {
    let condition = try ParsedWorkflowCondition("!(a-b || C) && always")
    XCTAssertEqual(condition.identifiers.map(\.name), ["a-b", "C"])
    XCTAssertEqual(condition.identifiers.map(\.span), [
      .init(start: 2, end: 5), .init(start: 9, end: 10)
    ])
    XCTAssertTrue(try condition.evaluate { _ in
      .boolean(false, source: .analysis)
    })
    XCTAssertFalse(try ParsedWorkflowCondition("never || false").evaluate { _ in .missing })
  }

  func testMissingAndWrongTypeAreDistinctEvenUnderShortCircuit() throws {
    let condition = try ParsedWorkflowCondition("true || missing")
    XCTAssertThrowsError(try condition.evaluate { _ in .missing }) { error in
      XCTAssertEqual(error as? WorkflowConditionError,
                     .missing(identifier: "missing", span: .init(start: 8, end: 15)))
    }
    XCTAssertThrowsError(try ParsedWorkflowCondition("!flag").evaluate { _ in .wrongType }) { error in
      XCTAssertEqual(error as? WorkflowConditionError,
                     .wrongType(identifier: "flag", span: .init(start: 1, end: 5)))
    }
    XCTAssertFalse(try ParsedWorkflowCondition("flag").evaluate { _ in
      .boolean(false, source: .when)
    })
  }

  func testMalformedExpressionsReportExactCharacterSpan() {
    let samples: [(String, WorkflowConditionSpan)] = [
      ("", .init(start: 0, end: 0)),
      ("true || !", .init(start: 9, end: 9)),
      ("a &&", .init(start: 4, end: 4)),
      ("(a", .init(start: 2, end: 2)),
      ("a)", .init(start: 1, end: 2)),
      ("a & b", .init(start: 2, end: 3)),
      ("()", .init(start: 1, end: 2))
    ]
    for (source, span) in samples {
      XCTAssertThrowsError(try ParsedWorkflowCondition(source), source) { error in
        XCTAssertEqual(error as? WorkflowConditionError, .syntax(span), source)
      }
    }
  }
}
