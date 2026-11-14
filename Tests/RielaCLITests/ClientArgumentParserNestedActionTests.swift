import XCTest
@testable import RielaCLI

final class ClientArgumentParserNestedActionTests: XCTestCase {
  func testArgumentParserAcceptsEveryTypedNestedAction() {
    let invocations = [
      PackageRegistryClientAction.allRawValues.map { ["package", "registry", $0] },
      NoteNotebookClientAction.allRawValues.map { ["note", "notebook", $0] },
      NoteStorageClientAction.allRawValues.map { ["note", "storage", $0] },
      NoteClientRegistrationAction.allRawValues.map { ["note", "client", $0] },
      NoteAutoActionClientAction.allRawValues.map { ["note", "auto-action", $0] },
      GraphQLClientAction.allRawValues.map { ["graphql", $0] },
      EventsClientAction.allRawValues.filter { $0 != "schedules" }.map { ["events", $0] },
      EventSchedulesClientAction.allRawValues.map { ["events", "schedules", $0] },
      HookClientVendor.allRawValues.map { ["hook", $0] }
    ].flatMap { $0 }

    for invocation in invocations {
      XCTAssertNoThrow(try RielaArgumentParser().parse(invocation), invocation.joined(separator: " "))
    }
  }

  func testArgumentParserRejectsUnknownTypedNestedActions() {
    let invocations = [
      ["package", "registry", "unknown"],
      ["note", "notebook", "unknown"],
      ["note", "storage", "unknown"],
      ["note", "client", "unknown"],
      ["note", "auto-action", "unknown"],
      ["graphql", "unknown"],
      ["events", "unknown"],
      ["events", "schedules", "unknown"],
      ["hook", "unknown"]
    ]

    for invocation in invocations {
      XCTAssertThrowsError(try RielaArgumentParser().parse(invocation), invocation.joined(separator: " "))
    }
  }
}
