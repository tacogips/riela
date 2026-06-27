#if os(macOS)
import XCTest
@testable import RielaAppSupport

final class RielaAppImportPreferencePolicyTests: XCTestCase {
  func testNewImportUsesCurrentAutostartPolicy() {
    XCTAssertEqual(
      RielaAppImportPreferencePolicy.preference(
        identity: "workflow",
        existingPreference: nil,
        replacedExisting: false,
        startsImmediately: true
      ),
      RielaAppDaemonWorkflowPreference(identity: "workflow", available: true, active: true)
    )
    XCTAssertEqual(
      RielaAppImportPreferencePolicy.preference(
        identity: "workflow",
        existingPreference: nil,
        replacedExisting: false,
        startsImmediately: false
      ),
      RielaAppDaemonWorkflowPreference(identity: "workflow", available: true, active: false)
    )
  }

  func testReplacingExistingImportPreservesProfilePreference() {
    let existing = RielaAppDaemonWorkflowPreference(
      identity: "workflow",
      available: true,
      active: false
    )

    let preference = RielaAppImportPreferencePolicy.preference(
      identity: "workflow",
      existingPreference: existing,
      replacedExisting: true,
      startsImmediately: true
    )

    XCTAssertEqual(preference, existing)
  }

  func testReplacingWithoutExistingPreferenceUsesCurrentAutostartPolicy() {
    let preference = RielaAppImportPreferencePolicy.preference(
      identity: "workflow",
      existingPreference: nil,
      replacedExisting: true,
      startsImmediately: true
    )

    XCTAssertEqual(
      preference,
      RielaAppDaemonWorkflowPreference(identity: "workflow", available: true, active: true)
    )
  }

  func testStartAfterImportRequiresSavedAvailableAndActivePreference() {
    XCTAssertTrue(RielaAppImportPreferencePolicy.shouldStartAfterImport(
      preference: RielaAppDaemonWorkflowPreference(identity: "workflow", available: true, active: true),
      startsImportedCandidates: true
    ))
    XCTAssertFalse(RielaAppImportPreferencePolicy.shouldStartAfterImport(
      preference: RielaAppDaemonWorkflowPreference(identity: "workflow", available: true, active: false),
      startsImportedCandidates: true
    ))
    XCTAssertFalse(RielaAppImportPreferencePolicy.shouldStartAfterImport(
      preference: RielaAppDaemonWorkflowPreference(identity: "workflow", available: true, active: true),
      startsImportedCandidates: false
    ))
  }
}
#endif
