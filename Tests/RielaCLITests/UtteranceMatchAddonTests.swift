import Foundation
import RielaCore
import XCTest

@testable import RielaCLI

final class UtteranceMatchAddonTests: XCTestCase {
  func testNormalizationTable() {
    let table: [(String, String)] = [
      ("ねえ、リエラ。エアコンを消して！", "ねえりえらえあこんを消して"),
      ("ﾈｴ ﾘｴﾗ ｴｱｺﾝ", "ねえりえらえあこん"),
      ("リエラ　電気つけて？", "りえら電気つけて"),
      ("Hey Riela, turn ON the lights!", "heyrielaturnonthelights"),
      ("ＨＥＹ　ＲＩＥＬＡ", "heyriela"),
      ("コーヒー・ラーメン", "こーひーらーめん"),
      ("ｶﾞｷﾞ", "がぎ"),
      ("  \n", "")
    ]
    for (input, expected) in table {
      XCTAssertEqual(UtteranceNormalizer.normalize(input), expected, input)
    }
  }

  func testWakePhraseStripsAndMatchesIntent() async throws {
    let output = try await run(text: "ねえリエラ、エアコン消して")
    let utterance = try XCTUnwrap(utteranceFields(output))
    XCTAssertEqual(utterance["wake"], .bool(true))
    XCTAssertEqual(utterance["wakePhrase"], .string("ねえリエラ"))
    XCTAssertEqual(utterance["command"], .string("エアコン消して"))
    XCTAssertEqual(utterance["normalizedCommand"], .string("えあこん消して"))
    XCTAssertEqual(utterance["intent"], .string("aircon_off"))
    XCTAssertEqual(utterance["normalized"], .string("ねえりえらえあこん消して"))
    XCTAssertEqual(output.when["always"], true)
    XCTAssertEqual(output.when["wake"], true)
    XCTAssertEqual(output.when["no_wake"], false)
    XCTAssertEqual(output.when["intent"], true)
    XCTAssertEqual(output.when["freeform"], false)
    XCTAssertEqual(output.when["intent_aircon_off"], true)
    XCTAssertEqual(output.when["intent_lights_on"], false)
  }

  func testWakeNotAtStartIsNoWake() async throws {
    let output = try await run(text: "それでリエラ、電気つけて")
    let utterance = try XCTUnwrap(utteranceFields(output))
    XCTAssertEqual(utterance["wake"], .bool(false))
    XCTAssertEqual(utterance["intent"], .null)
    XCTAssertEqual(utterance["command"], .string(""))
    XCTAssertEqual(output.when["no_wake"], true)
    XCTAssertEqual(output.when["wake"], false)
    XCTAssertEqual(output.when["intent"], false)
    XCTAssertEqual(output.when["freeform"], false)
    XCTAssertEqual(output.when["intent_lights_on"], false)
  }

  func testFreeformKeepsOriginalCommandSpacing() async throws {
    let output = try await run(text: "Hey Riela, what is the weather tomorrow?")
    let utterance = try XCTUnwrap(utteranceFields(output))
    XCTAssertEqual(utterance["wakePhrase"], .string("Hey Riela"))
    XCTAssertEqual(utterance["command"], .string("what is the weather tomorrow"))
    XCTAssertEqual(output.when["freeform"], true)
    XCTAssertEqual(output.when["intent"], false)
  }

  func testMultipleIntentsReportFirstAndLabelEach() async throws {
    let output = try await run(text: "リエラ 電気をつけてエアコンを消して")
    let utterance = try XCTUnwrap(utteranceFields(output))
    XCTAssertEqual(utterance["intent"], .string("aircon_off"))
    XCTAssertEqual(utterance["intents"], .array([.string("aircon_off"), .string("lights_on")]))
    XCTAssertEqual(output.when["intent_aircon_off"], true)
    XCTAssertEqual(output.when["intent_lights_on"], true)
  }

  func testKatakanaPatternMatchesHalfWidthAndHiraganaText() async throws {
    let output = try await run(text: "りえら ｴｱｺﾝけして")
    XCTAssertEqual(output.when["intent_aircon_off"], true)
  }

  func testWakeOptionalProceedsWithoutWake() async throws {
    let output = try await run(text: "電気つけて", requireWakePhrase: false)
    XCTAssertEqual(output.when["no_wake"], true)
    XCTAssertEqual(output.when["intent_lights_on"], true)
    XCTAssertEqual(utteranceFields(output)?["command"], .string("電気つけて"))
  }

  func testInvalidConfigurationsAreRejected() async throws {
    let cases: [(String, JSONObject)] = [
      ("invalid regex", ["text": .string("x"), "wakePhrases": .array([.string("riela")]),
        "intents": .array([.object(["id": .string("bad"), "patterns": .array([.string("(unclosed")])])])]),
      ("bad intent id", ["text": .string("x"), "wakePhrases": .array([.string("riela")]),
        "intents": .array([.object(["id": .string("Bad-Id"), "patterns": .array([.string("a")])])])]),
      ("duplicate id", ["text": .string("x"), "wakePhrases": .array([.string("riela")]),
        "intents": .array([
          .object(["id": .string("a"), "patterns": .array([.string("a")])]),
          .object(["id": .string("a"), "patterns": .array([.string("b")])])
        ])]),
      ("too many patterns", ["text": .string("x"), "wakePhrases": .array([.string("riela")]),
        "intents": .array([.object(["id": .string("a"),
          "patterns": .array(Array(repeating: .string("a"), count: 17))])])]),
      ("too many intents", ["text": .string("x"), "wakePhrases": .array([.string("riela")]),
        "intents": .array((0..<65).map { .object(["id": .string("i\($0)"), "patterns": .array([.string("a")])]) })]),
      ("pattern too long", ["text": .string("x"), "wakePhrases": .array([.string("riela")]),
        "intents": .array([.object(["id": .string("a"),
          "patterns": .array([.string(String(repeating: "a", count: 257))])])])]),
      ("text too large", ["text": .string(String(repeating: "a", count: 8 * 1024 + 1)),
        "wakePhrases": .array([.string("riela")])]),
      ("missing wake phrases", ["text": .string("x")]),
      ("missing text", ["wakePhrases": .array([.string("riela")])]),
      ("unknown option", ["text": .string("x"), "wakePhrases": .array([.string("riela")]), "extra": .bool(true)])
    ]
    for (label, options) in cases {
      do {
        _ = try await execute(options: options)
        XCTFail("\(label) should be rejected")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .invalidInput, "\(label): \(error.message)")
      }
    }
  }

  func testRejectsAddonEnvironment() async throws {
    let input = WorkflowAddonExecutionInput(
      workflowId: "voice", stepId: "match", nodeId: "match",
      addon: .init(
        name: "riela/utterance-match", version: "1",
        config: ["options": .object(["text": .string("x"), "requireWakePhrase": .bool(false)])],
        env: ["X": .object(["fromEnv": .string("X")])]),
      variables: [:])
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: ["X": "1"]).execute(input, context: .init())
      XCTFail("addon.env should be rejected")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
  }

  func testIsRegistered() {
    XCTAssertNotNil(BuiltinStatefulAddonRegistry.handlers["riela/utterance-match"])
  }

  private func run(text: String, requireWakePhrase: Bool = true) async throws -> AdapterExecutionOutput {
    try await execute(options: [
      "text": .string(text),
      "wakePhrases": .array([.string("ねえリエラ"), .string("リエラ"), .string("Hey Riela")]),
      "requireWakePhrase": .bool(requireWakePhrase),
      "intents": .array([
        .object(["id": .string("aircon_off"), "patterns": .array([.string("エアコン(を)?(消|け)して"), .string("冷房止めて")])]),
        .object(["id": .string("lights_on"), "patterns": .array([.string("電気(を)?つけて")])])
      ])
    ])
  }

  private func execute(options: JSONObject) async throws -> AdapterExecutionOutput {
    let input = WorkflowAddonExecutionInput(
      workflowId: "voice", stepId: "match", nodeId: "match",
      addon: .init(name: "riela/utterance-match", version: "1", config: ["options": .object(options)]),
      variables: [:])
    return try await BuiltinWorkflowAddonResolver(environment: [:]).execute(input, context: .init())
  }

  private func utteranceFields(_ output: AdapterExecutionOutput) -> JSONObject? {
    guard case let .object(fields)? = output.payload["utterance"] else { return nil }
    return fields
  }
}
