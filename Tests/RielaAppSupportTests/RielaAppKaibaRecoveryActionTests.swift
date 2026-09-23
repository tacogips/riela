#if os(macOS)
@testable import RielaAppSupport
import XCTest

final class RielaAppKaibaRecoveryActionTests: XCTestCase {
  func testRecoveryInstructionsAreFixedAndRedacted() {
    let instructions = [
      RielaAppKaibaRecoveryAction.openKaibaSettings.instruction,
      RielaAppKaibaRecoveryAction.configureWorkflowEnvironment.instruction,
      RielaAppKaibaRecoveryAction.selectEnabledInstance.instruction,
      RielaAppKaibaRecoveryAction.repairLegacyConnectionConfiguration.instruction,
      RielaAppKaibaRecoveryAction.testSelectedInstance.instruction
    ]

    XCTAssertEqual(instructions, [
      "Open Kaiba settings and repair the instance catalog.",
      "Configure the required credential environment variable for this workflow.",
      "Select an enabled Kaiba instance for every Kaiba node.",
      "Bind the intended named instance and remove legacy fields.",
      "Test the selected Kaiba instance from Kaiba settings."
    ])
    XCTAssertFalse(instructions.joined().localizedCaseInsensitiveContains("token"))
    XCTAssertFalse(instructions.joined().localizedCaseInsensitiveContains("bearer"))
  }
}
#endif
