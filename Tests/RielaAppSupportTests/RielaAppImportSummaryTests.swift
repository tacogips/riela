#if os(macOS)
import XCTest
@testable import RielaAppSupport

final class RielaAppImportSummaryTests: XCTestCase {
  func testProfileSwitchSummaryDescribesSafeNameAndAutostartPolicy() {
    XCTAssertEqual(
      RielaAppProfileSwitchSummary(
        rawProfileName: "work",
        profileName: RielaAppProfileName("work"),
        autostartsDaemonWorkflows: true
      ).statusMessage,
      "Profile: work"
    )
    XCTAssertEqual(
      RielaAppProfileSwitchSummary(
        rawProfileName: "work/team",
        profileName: RielaAppProfileName("work-team"),
        autostartsDaemonWorkflows: false
      ).statusMessage,
      "Profile: work-team (safe name for work/team); auto-start off"
    )
  }

  func testImportSummaryDescribesSingleUpdatedPackage() {
    let summary = RielaAppImportSummary(
      importedNames: [],
      updatedNames: ["demo"],
      failures: [],
      profileName: RielaAppProfileName("work"),
      startsImmediately: true
    )

    XCTAssertEqual(summary.statusMessage, "Updated demo in profile work")
  }

  func testImportSummaryDescribesUpdatedPackageWithPreservedAutostartOff() {
    let summary = RielaAppImportSummary(
      importedNames: [],
      updatedNames: ["demo"],
      failures: [],
      profileName: RielaAppProfileName("work"),
      startsImmediately: true,
      autostartOffNames: ["demo"]
    )

    XCTAssertEqual(summary.statusMessage, "Updated demo in profile work with auto-start off")
  }

  func testImportSummaryDescribesMixedImportsUpdatesAndFailures() {
    let summary = RielaAppImportSummary(
      importedNames: ["new-demo"],
      updatedNames: ["existing-demo"],
      failures: ["bad: Selected source is not a workflow folder"],
      profileName: RielaAppProfileName("work"),
      startsImmediately: false
    )

    XCTAssertEqual(
      summary.statusMessage,
      "Import completed with errors; imported: new-demo; updated: existing-demo; failed: bad: Selected source is not a workflow folder"
    )
  }

  func testImportSummaryDescribesMixedErrorsWithAutostartOffItems() {
    let summary = RielaAppImportSummary(
      importedNames: ["new-demo"],
      updatedNames: ["existing-demo"],
      failures: ["bad: Selected source is not a workflow folder"],
      profileName: RielaAppProfileName("work"),
      startsImmediately: false,
      autostartOffNames: ["new-demo", "existing-demo"]
    )

    XCTAssertEqual(
      summary.statusMessage,
      "Import completed with errors; imported: new-demo; updated: existing-demo; auto-start off: new-demo, existing-demo; failed: bad: Selected source is not a workflow folder"
    )
  }

  func testImportSummaryDescribesMixedImportsWithAutostartOffItems() {
    let summary = RielaAppImportSummary(
      importedNames: ["new-demo"],
      updatedNames: ["existing-demo"],
      failures: [],
      profileName: RielaAppProfileName("work"),
      startsImmediately: true,
      autostartOffNames: ["existing-demo"]
    )

    XCTAssertEqual(
      summary.statusMessage,
      "Imported 1 item and updated 1 item in profile work; auto-start off: existing-demo"
    )
  }

  func testProjectImportSummaryDescribesSingleAddedProject() {
    let summary = RielaAppProjectImportSummary(
      projects: [
        RielaAppProjectImportSummary.Project(name: "demo", workflowCount: 2, alreadyAdded: false)
      ],
      failures: [],
      profileName: RielaAppProfileName("work")
    )

    XCTAssertEqual(summary.statusMessage, "Added project to profile work: demo (2 workflows)")
  }

  func testProjectImportSummaryDescribesSingleExistingProject() {
    let summary = RielaAppProjectImportSummary(
      projects: [
        RielaAppProjectImportSummary.Project(name: "demo", workflowCount: 1, alreadyAdded: true)
      ],
      failures: [],
      profileName: RielaAppProfileName("work")
    )

    XCTAssertEqual(summary.statusMessage, "Project already in profile work: demo (1 workflow)")
  }

  func testProjectImportSummaryDescribesMultipleAndFailedProjects() {
    let summary = RielaAppProjectImportSummary(
      projects: [
        RielaAppProjectImportSummary.Project(name: "one", workflowCount: 1, alreadyAdded: false),
        RielaAppProjectImportSummary.Project(name: "two", workflowCount: 3, alreadyAdded: true)
      ],
      failures: ["bad: folder has no .riela/workflows or .riela/packages"],
      profileName: RielaAppProfileName("work")
    )

    XCTAssertEqual(
      summary.statusMessage,
      "Added 1 project to profile work; 1 already in profile (4 workflows); failed: bad: folder has no .riela/workflows or .riela/packages"
    )
  }

  func testProjectImportSummaryDescribesOnlyFailedProjects() {
    let summary = RielaAppProjectImportSummary(
      projects: [],
      failures: ["bad: folder has no .riela/workflows or .riela/packages"],
      profileName: RielaAppProfileName("work")
    )

    XCTAssertEqual(
      summary.statusMessage,
      "Project import failed: bad: folder has no .riela/workflows or .riela/packages"
    )
  }
}
#endif
