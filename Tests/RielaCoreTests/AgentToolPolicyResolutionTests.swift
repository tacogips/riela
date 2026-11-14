import XCTest
@testable import RielaCore

final class AgentToolPolicyResolutionTests: XCTestCase {
  func testBindsArgumentsAsSingleValuesWithoutReinterpretingSuppliedTemplates() throws {
    let policy = AgentToolPolicy(codexArguments: ["-c", "{{catalogArgument}}", "--disable", "shell_tool"])
    let supplied = #"model_catalog_json="/path with spaces/{{data}}.json""#
    let result = try resolveAgentToolPolicy(policy, variables: ["catalogArgument": .string(supplied), "data": .string("ignore")])
    XCTAssertEqual(result?.codexArguments, ["-c", supplied, "--disable", "shell_tool"])
    XCTAssertEqual(policy.codexArguments[1], "{{catalogArgument}}")
  }

  func testMissingNullNulAndOversizedBindingsFailClosed() throws {
    let policy = AgentToolPolicy(codexArguments: ["{{catalogArgument}}"])
    for variables: JSONObject in [[:], ["catalogArgument": .null], ["catalogArgument": .string("a\0b")],
      ["catalogArgument": .string(String(repeating: "a", count: 65_537))]] {
      XCTAssertThrowsError(try resolveAgentToolPolicy(policy, variables: variables))
    }
  }
}
