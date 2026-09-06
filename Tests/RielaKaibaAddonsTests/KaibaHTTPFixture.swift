import Foundation
import KaibaClient

final class KaibaHTTPFixture: KaibaHTTPTransporting, @unchecked Sendable {
  private let lock = NSLock()
  private let lostResponseOperations: Set<String>
  private var recorded: [KaibaHTTPRequest] = []
  private var committedIdempotencyKeys = Set<String>()
  private var lostResponseKeys = Set<String>()
  private var idempotencyBodies: [String: Data] = [:]

  init(lostResponseOperations: Set<String> = []) {
    self.lostResponseOperations = lostResponseOperations
  }

  var requests: [KaibaHTTPRequest] { lock.withLock { recorded } }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    let requestBody = fixtureRequestBody(request)
    let operation = fixtureOperationName(requestBody.query)
    let outcome = try lock.withLock { () throws -> FixtureMutationOutcome in
      recorded.append(request)
      guard let key = requestBody.idempotencyKey else { return .init(replay: false, conflict: false) }
      if let previous = idempotencyBodies[key], previous != request.body {
        return .init(replay: false, conflict: true)
      }
      idempotencyBodies[key] = request.body
      let replay = committedIdempotencyKeys.contains(key)
      committedIdempotencyKeys.insert(key)
      if lostResponseOperations.contains(operation), lostResponseKeys.insert(key).inserted {
        throw URLError(.networkConnectionLost)
      }
      return .init(replay: replay, conflict: false)
    }
    let body = try JSONSerialization.data(
      withJSONObject: fixtureResponse(
        for: requestBody.query,
        replay: outcome.replay,
        conflict: outcome.conflict
      ),
      options: [.sortedKeys]
    )
    return .init(statusCode: 200, body: body)
  }
}

private func fixtureResponse(
  for query: String,
  replay: Bool,
  conflict: Bool
) -> [String: Any] {
  if query.contains("KaibaClientReadiness") {
    return ["data": ["kaibaReadiness": ["result": [
      "accepted": !conflict,
      "status": conflict ? "idempotency_conflict" : "ok"
    ]]]]
  }
  return ["data": ["root": fixtureRoot(for: query, replay: replay, conflict: conflict)]]
}

func fixtureKaibaClient(_ transport: KaibaHTTPFixture = .init()) throws -> KaibaClient {
  try KaibaClient(
    endpoint: URL(string: "http://127.0.0.1:8787/graphql")!,
    authentication: .unauthenticated,
    transport: transport
  )
}

private struct FixtureRequestBody {
  let query: String
  let idempotencyKey: String?
}

private struct FixtureMutationOutcome {
  let replay: Bool
  let conflict: Bool
}

private func fixtureRequestBody(_ request: KaibaHTTPRequest) -> FixtureRequestBody {
  guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
    return .init(query: "", idempotencyKey: nil)
  }
  let query = body["query"] as? String ?? ""
  let variables = body["variables"] as? [String: Any]
  let input = variables?["input"] as? [String: Any]
  return .init(query: query, idempotencyKey: input?["idempotencyKey"] as? String)
}

private func fixtureOperationName(_ query: String) -> String {
  guard let range = query.range(of: "Kaiba") else { return "unknown" }
  let suffix = query[range.lowerBound...]
  return suffix.prefix { $0.isLetter || $0.isNumber }.description
}

private func fixtureRoot(for query: String, replay: Bool, conflict: Bool) -> [String: Any] {
  var root: [String: Any] = ["result": [
    "accepted": !conflict,
    "status": conflict ? "idempotency_conflict" : "ok",
    "diagnostics": ["server-secret"]
  ]]
  if query.contains("KaibaListNotes") || query.contains("KaibaGetNote") {
    root["value"] = query.contains("KaibaGetNote") ? fixtureNote() : [fixtureNote()]
  } else if query.contains("KaibaSearchNotes") {
    root["value"] = [["note": fixtureNote(), "snippet": "fixture match", "rank": 1.0, "matchedTags": [], "isLinkedNeighbor": false, "termCoverage": 1.0]]
  } else if query.contains("KaibaNoteGraph") {
    root["value"] = [["seedNoteId": "note-1", "note": fixtureNote(), "edgeKind": "related", "weight": 1.0, "hopCount": 1, "pathNoteIds": ["note-1", "note-2"]]]
  } else if query.contains("KaibaNoteFiles") || query.contains("KaibaNotebookFiles") {
    root["value"] = [["noteId": "note-1", "notebookId": "notebook-1", "role": "related", "position": 0, "file": fixtureFile()]]
  } else if query.contains("KaibaNoteComments") {
    root["value"] = [fixtureComment()]
  } else if query.contains("KaibaLongTermMemoryNotebook") {
    root["value"] = fixtureNotebook()
  } else if query.contains("KaibaRecallLongTermMemory") {
    root["value"] = [["note": fixtureNote(), "snippet": "durable fixture fact", "rank": 1.0, "isAssociation": false, "edgeKind": NSNull(), "weight": NSNull(), "hopCount": NSNull(), "pathNoteIds": ["note-1"]]]
  } else if query.contains("KaibaLinkLongTermMemory") {
    root["value"] = [["fromNoteId": "note-1", "toNoteId": "note-2", "linkKind": "related", "provenance": "workflow", "createdAt": "2026-01-01T00:00:00Z"]]
  } else if query.contains("KaibaAppendLongTermMemory") {
    root["notes"] = [fixtureNote()]
    root["idempotentReplay"] = replay
  } else {
    root["note"] = fixtureNote()
    root["notebook"] = fixtureNotebook()
    root["notes"] = [fixtureNote()]
    root["file"] = fixtureFile()
    root["noteFiles"] = [["noteId": "note-1", "role": "related", "position": 0, "file": fixtureFile()]]
    root["notebookFiles"] = [["notebookId": "notebook-1", "role": "source-document", "file": fixtureFile()]]
    root["comment"] = fixtureComment()
  }
  return root
}

private func fixtureNote() -> [String: Any] {
  [
    "noteId": "note-1", "notebookId": "notebook-1", "noteNumber": 1,
    "title": "Fixture", "bodyMarkdown": "# fixture\n\nbody", "readOnly": false,
    "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
    "metaJSON": NSNull(), "tags": [], "createdBy": NSNull(), "updatedBy": NSNull()
  ]
}

private func fixtureNotebook() -> [String: Any] {
  [
    "notebookId": "notebook-1", "title": "Fixture Notebook", "readOnly": false,
    "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
    "metaJSON": NSNull(), "tags": [], "firstNotePreview": NSNull(), "noteCount": 1,
    "libraryId": NSNull(), "ownerUserId": NSNull(), "createdBy": NSNull(), "updatedBy": NSNull()
  ]
}

private func fixtureFile() -> [String: Any] {
  [
    "fileId": "file-1", "storageKind": "local", "localPath": "/provider/private",
    "s3Profile": NSNull(), "s3Bucket": NSNull(), "s3Key": NSNull(),
    "mediaType": "text/plain", "byteSize": 7, "sha256": "abc",
    "originalFilename": "fixture.txt", "createdAt": "2026-01-01T00:00:00Z",
    "migratedAt": NSNull()
  ]
}

private func fixtureComment() -> [String: Any] {
  ["commentId": "comment-1", "noteId": "note-1", "notebookId": NSNull(), "bodyMarkdown": "Agent fixture", "author": "assistant", "createdAt": "2026-01-01T00:00:00Z"]
}
