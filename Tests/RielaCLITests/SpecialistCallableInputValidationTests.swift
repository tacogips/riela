import XCTest
import RielaCore
@testable import RielaCLI

final class SpecialistCallableInputValidationTests: XCTestCase {
  func testMissingRequiredInputIsRejected() throws {
    let contract = NodeInputContract(jsonSchema: [
      "type": .string("object"), "required": .array([.string("request")]),
      "properties": .object(["request": .object(["type": .string("string")])])
    ])
    XCTAssertThrowsError(try SpecialistCallableInputValidation.validate(payload: [:], contract: contract))
    XCTAssertThrowsError(try SpecialistCallableInputValidation.validate(payload: ["request": .number(4)], contract: contract))
    XCTAssertNoThrow(try SpecialistCallableInputValidation.validate(payload: ["request": .string("work")], contract: contract))
  }

  func testUnsupportedSchemaFailsClosed() {
    let contract = NodeInputContract(jsonSchema: ["type": .string("object"), "$ref": .string("https://example.invalid/schema")])
    XCTAssertThrowsError(try SpecialistCallableInputValidation.validate(payload: [:], contract: contract))
  }

  func testAdditionalPropertiesAreRejectedAndLegacyContractsRemainCompatible() {
    let contract = NodeInputContract(jsonSchema: ["type": .string("object"), "additionalProperties": .bool(false)])
    XCTAssertThrowsError(try SpecialistCallableInputValidation.validate(payload: ["unexpected": .string("value")], contract: contract))
    XCTAssertNoThrow(try SpecialistCallableInputValidation.validate(payload: [:], contract: contract))
    XCTAssertNoThrow(try SpecialistCallableInputValidation.validate(payload: ["legacy": .string("value")], contract: nil))
  }
}
