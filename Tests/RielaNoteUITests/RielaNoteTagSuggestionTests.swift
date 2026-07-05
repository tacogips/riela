import RielaNote
@testable import RielaNoteUI
import XCTest

final class RielaNoteTagSuggestionTests: XCTestCase {
  func testTagSuggestionsFilterExistingTagsAndQuery() {
    let topic = Self.tag(name: "topic:swift")
    let project = Self.tag(name: "project:riela")
    let existing = TagAssignment(
      tag: topic,
      provenance: .human,
      assignedBy: "user",
      deletable: true,
      createdAt: "2026-07-04T00:00:00Z"
    )

    let suggestions = rielaNoteTagSuggestions(
      availableTags: [project, topic, Self.tag(name: "person:ada")],
      existingAssignments: [existing],
      query: "Pro"
    )

    XCTAssertEqual(suggestions.map(\.name), ["project:riela"])
  }

  private static func tag(name: String) -> Tag {
    Tag(
      tagId: "tag-\(name)",
      name: name,
      classId: "topic",
      isSystem: false,
      createdAt: "2026-07-04T00:00:00Z"
    )
  }
}
