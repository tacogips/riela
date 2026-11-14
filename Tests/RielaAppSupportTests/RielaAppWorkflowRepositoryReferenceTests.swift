#if os(macOS)
import XCTest
@testable import RielaAppSupport

final class RielaAppWorkflowRepositoryReferenceTests: XCTestCase {
  func testParsesRepositoryURL() throws {
    let reference = try RielaAppWorkflowRepositoryReference.parse("https://github.com/tacogips/riela-packages")

    XCTAssertEqual(reference.owner, "tacogips")
    XCTAssertEqual(reference.repository, "riela-packages")
    XCTAssertNil(reference.branch)
    XCTAssertEqual(reference.id, "tacogips/riela-packages")
    XCTAssertEqual(reference.cloneURL, "https://github.com/tacogips/riela-packages.git")
    XCTAssertEqual(reference.webURL, "https://github.com/tacogips/riela-packages")
  }

  func testParsesRepositoryURLVariants() throws {
    XCTAssertEqual(
      try RielaAppWorkflowRepositoryReference.parse("https://github.com/tacogips/riela-packages.git").repository,
      "riela-packages"
    )
    XCTAssertEqual(
      try RielaAppWorkflowRepositoryReference.parse("https://github.com/tacogips/riela-packages/").id,
      "tacogips/riela-packages"
    )
    XCTAssertEqual(
      try RielaAppWorkflowRepositoryReference.parse("tacogips/riela-packages").id,
      "tacogips/riela-packages"
    )
  }

  func testParsesBranchPinnedTreeURL() throws {
    let reference = try RielaAppWorkflowRepositoryReference.parse(
      "https://github.com/tacogips/riela-packages/tree/release-1"
    )

    XCTAssertEqual(reference.branch, "release-1")
    XCTAssertEqual(reference.id, "tacogips/riela-packages@release-1")
  }

  func testRejectsUnsupportedReferences() {
    let unsupported = [
      "",
      "https://gitlab.com/tacogips/riela-packages",
      "http://github.com/tacogips/riela-packages",
      "https://github.com/tacogips",
      "https://github.com/tacogips/riela-packages/tree/main/packages/chat-bot",
      "https://github.com/tacogips/riela-packages/blob/main",
      "git@github.com:tacogips/riela-packages.git",
      "github.com/tacogips/riela-packages"
    ]
    for value in unsupported {
      XCTAssertThrowsError(try RielaAppWorkflowRepositoryReference.parse(value), value)
    }
  }

  func testRejectsUnsafeComponents() {
    XCTAssertThrowsError(try RielaAppWorkflowRepositoryReference.parse("https://github.com/../riela-packages"))
    XCTAssertThrowsError(try RielaAppWorkflowRepositoryReference.parse("owner name/repo"))
  }

  func testStateAddRemoveWorkflowRepositories() throws {
    var state = RielaAppDaemonWorkflowState()
    let first = try RielaAppWorkflowRepositoryReference.parse("tacogips/riela-packages")
    let second = try RielaAppWorkflowRepositoryReference.parse("acme/workflows")

    state.addWorkflowRepository(first)
    state.addWorkflowRepository(second)
    state.addWorkflowRepository(first)

    XCTAssertEqual(state.workflowRepositories.map(\.id), ["acme/workflows", "tacogips/riela-packages"])
    XCTAssertTrue(state.containsWorkflowRepository(id: first.id))

    state.removeWorkflowRepository(id: first.id)

    XCTAssertEqual(state.workflowRepositories.map(\.id), ["acme/workflows"])
    XCTAssertFalse(state.containsWorkflowRepository(id: first.id))
  }

  func testStateRoundTripsWorkflowRepositories() throws {
    var state = RielaAppDaemonWorkflowState()
    state.addWorkflowRepository(try RielaAppWorkflowRepositoryReference.parse(
      "https://github.com/tacogips/riela-packages/tree/main"
    ))

    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(RielaAppDaemonWorkflowState.self, from: data)

    XCTAssertEqual(decoded.workflowRepositories, state.workflowRepositories)
  }

  func testLegacyStateWithoutRepositoriesDecodes() throws {
    let legacyJSON = Data("""
    {"version": 1, "preferences": {}, "workflowDirectories": [], "projectDirectories": []}
    """.utf8)

    let decoded = try JSONDecoder().decode(RielaAppDaemonWorkflowState.self, from: legacyJSON)

    XCTAssertTrue(decoded.workflowRepositories.isEmpty)
  }
}
#endif
