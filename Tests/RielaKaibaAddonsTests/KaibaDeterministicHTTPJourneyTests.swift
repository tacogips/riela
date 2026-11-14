import KaibaClient
import XCTest

final class KaibaDeterministicHTTPJourneyTests: XCTestCase {
  func testReadinessReadGraphQLIngestAndMemoryUseTheDeterministicHTTPFixture() async throws {
    let transport = KaibaHTTPFixture()
    let client = try fixtureKaibaClient(transport)

    let readiness = try await client.probeReadiness()
    XCTAssertEqual(readiness.status, .ready)

    let notes = try await client.listNotes(limit: 1)
    XCTAssertEqual(notes.result.accepted, true)
    XCTAssertEqual(notes.value?.first?.noteId.rawValue, "note-1")

    let graphQL: KaibaGraphQLResponse<KaibaJSONValue> = try await client.execute(
      .init(document: "query Fixture { fixture }")
    )
    XCTAssertNotNil(graphQL.data.objectValue?["root"])

    let ingest = try await client.ingestNotebookPages(
      idempotencyKey: "deterministic-http-journey",
      title: "Fixture Ingest",
      pages: [.init(bodyMarkdown: "fixture page")]
    )
    XCTAssertEqual(ingest.result.accepted, true)
    XCTAssertEqual(ingest.notebook?.notebookId.rawValue, "notebook-1")

    let memory = try await client.longTermMemoryNotebook()
    XCTAssertEqual(memory.result.accepted, true)
    XCTAssertEqual(memory.value?.notebookId.rawValue, "notebook-1")

    let recall = try await client.recallLongTermMemory(query: "fixture")
    XCTAssertEqual(recall.result.accepted, true)
    XCTAssertEqual(recall.value?.first?.note.noteId.rawValue, "note-1")

    let documents = transport.requests.compactMap { String(data: $0.body, encoding: .utf8) }
    XCTAssertTrue(documents.contains { $0.contains("KaibaClientReadiness") })
    XCTAssertTrue(documents.contains { $0.contains("KaibaListNotes") })
    XCTAssertTrue(documents.contains { $0.contains("query Fixture") })
    XCTAssertTrue(documents.contains { $0.contains("KaibaIngestNotebookPages") })
    XCTAssertTrue(documents.contains { $0.contains("KaibaLongTermMemoryNotebook") })
    XCTAssertTrue(documents.contains { $0.contains("KaibaRecallLongTermMemory") })
  }
}
