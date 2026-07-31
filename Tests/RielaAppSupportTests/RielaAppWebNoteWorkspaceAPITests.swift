#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCore
import RielaNote
import RielaServer
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppWebNoteWorkspaceAPITests: XCTestCase {
  private let profile = RielaAppProfileName.defaultRawValue

  func testSystemMemoryNotebookReadOnlyRoutePersistsAndChecksProfile() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let path = "/api/v1/notes/notebooks/\(NoteStoreSchema.systemMemoryNotebookId)/read-only"

    let unlocked = try jsonObject(await fixture.app.webAPIResponse(
      for: postRequest(path: path, body: [
        "expectedProfile": profile,
        "readOnly": false
      ]),
      csrfToken: "csrf"
    ))
    XCTAssertEqual((unlocked["notebook"] as? [String: Any])?["readOnly"] as? Bool, false)

    let conflict = await fixture.app.webAPIResponse(
      for: postRequest(path: path, body: [
        "expectedProfile": "other-profile",
        "readOnly": true
      ]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(conflict.status, 409)
    XCTAssertEqual(errorCode(conflict), "profile_conflict")
  }

  func testNoteSettingsRoundTripIncludesS3Profiles() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let initial = try jsonObject(await fixture.app.webAPIResponse(
      for: RielaHTTPRequest(method: "GET", path: "/api/v1/settings/notes"),
      csrfToken: "csrf"
    ))
    XCTAssertEqual(initial["exposesNoteAPI"] as? Bool, false)
    XCTAssertEqual((initial["s3Profiles"] as? [Any])?.count, 0)
    XCTAssertNotNil(initial["noteRoot"] as? String)
    let revision = try XCTUnwrap(initial["revision"] as? Int)

    let put = await fixture.app.webAPIResponse(
      for: putRequest(path: "/api/v1/settings/notes", body: [
        "expectedRevision": revision,
        "expectedProfile": profile,
        "exposesNoteAPI": true,
        "s3Profiles": [[
          "name": "primary",
          "endpoint": "https://s3.example.com",
          "region": "ap-northeast-1",
          "bucket": "bucket-a",
          "keyPrefix": "notes/"
        ]]
      ]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(put.status, 200)
    let updated = try jsonObject(put)
    XCTAssertEqual(updated["exposesNoteAPI"] as? Bool, true)
    let profiles = try XCTUnwrap(updated["s3Profiles"] as? [[String: Any]])
    XCTAssertEqual(profiles.count, 1)
    XCTAssertEqual(profiles[0]["name"] as? String, "primary")
    XCTAssertEqual(profiles[0]["accessKeyIdEnv"] as? String, "AWS_ACCESS_KEY_ID")

    let updatedRevision = try XCTUnwrap(updated["revision"] as? Int)
    let invalid = await fixture.app.webAPIResponse(
      for: putRequest(path: "/api/v1/settings/notes", body: [
        "expectedRevision": updatedRevision,
        "expectedProfile": profile,
        "s3Profiles": [["name": "x", "endpoint": "", "region": "", "bucket": ""]]
      ]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(invalid.status, 400)
  }

  func testNoteClientRoutesListRegisterAndRevoke() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let list = try jsonObject(await fixture.app.webAPIResponse(
      for: RielaHTTPRequest(method: "GET", path: "/api/v1/settings/notes/clients"),
      csrfToken: "csrf"
    ))
    XCTAssertEqual((list["items"] as? [Any])?.count, 0)
    let revision = try XCTUnwrap(list["revision"] as? Int)

    // The fixture has no served note API endpoint, so registration is a 409.
    let register = await fixture.app.webAPIResponse(
      for: postRequest(path: "/api/v1/settings/notes/clients/registrations", body: [
        "expectedRevision": revision,
        "expectedProfile": profile
      ]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(register.status, 409)
    XCTAssertEqual(errorCode(register), "registration_unavailable")

    let revoke = await fixture.app.webAPIResponse(
      for: RielaHTTPRequest(
        method: "DELETE",
        path: "/api/v1/settings/notes/clients/nonexistent",
        body: jsonBody(["expectedRevision": revision, "expectedProfile": profile])
      ),
      csrfToken: "csrf"
    )
    XCTAssertEqual(revoke.status, 400)
  }

  func testAppearanceSettingsRoundTrip() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let initial = try jsonObject(await fixture.app.webAPIResponse(
      for: RielaHTTPRequest(method: "GET", path: "/api/v1/settings/appearance"),
      csrfToken: "csrf"
    ))
    XCTAssertEqual(initial["colorScheme"] as? String, "dark")
    XCTAssertEqual(initial["options"] as? [String], ["dark", "light"])
    let revision = try XCTUnwrap(initial["revision"] as? Int)

    let put = await fixture.app.webAPIResponse(
      for: putRequest(path: "/api/v1/settings/appearance", body: [
        "expectedRevision": revision,
        "colorScheme": "light"
      ]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(put.status, 200)
    let putJSON = try jsonObject(put)
    XCTAssertEqual(putJSON["colorScheme"] as? String, "light")
    XCTAssertEqual(fixture.app.appearanceSettingsStore.load().colorScheme, .light)

    let invalid = await fixture.app.webAPIResponse(
      for: putRequest(path: "/api/v1/settings/appearance", body: [
        "expectedRevision": try XCTUnwrap(putJSON["revision"] as? Int),
        "colorScheme": "sepia"
      ]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(invalid.status, 400)
  }

  func testNoteWorkspaceMemoDetailBodyCommentsAndLinks() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = fixture.app

    let memo = try jsonObject(await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/memos", body: [
        "expectedProfile": profile,
        "bodyMarkdown": "# First memo\nbody text"
      ]),
      csrfToken: "csrf"
    ))
    let memoDetail = try XCTUnwrap(memo["detail"] as? [String: Any])
    let memoNote = try XCTUnwrap(memoDetail["note"] as? [String: Any])
    let memoNoteId = try XCTUnwrap(memoNote["noteId"] as? String)

    let detail = try jsonObject(await app.webAPIResponse(
      for: RielaHTTPRequest(method: "GET", path: "/api/v1/notes/\(memoNoteId)/detail"),
      csrfToken: "csrf"
    ))
    XCTAssertNotNil(detail["detail"])

    let updated = try jsonObject(await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/\(memoNoteId)/body", body: [
        "expectedProfile": profile,
        "bodyMarkdown": "# Updated memo"
      ]),
      csrfToken: "csrf"
    ))
    let updatedNote = try XCTUnwrap((updated["detail"] as? [String: Any])?["note"] as? [String: Any])
    XCTAssertEqual(updatedNote["bodyMarkdown"] as? String, "# Updated memo")

    let commented = try jsonObject(await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/\(memoNoteId)/comments", body: [
        "expectedProfile": profile,
        "bodyMarkdown": "A comment"
      ]),
      csrfToken: "csrf"
    ))
    let comments = try XCTUnwrap((commented["detail"] as? [String: Any])?["comments"] as? [[String: Any]])
    XCTAssertEqual(comments.count, 1)

    let second = try jsonObject(await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/memos", body: [
        "expectedProfile": profile,
        "bodyMarkdown": "Second memo"
      ]),
      csrfToken: "csrf"
    ))
    let secondNoteId = try XCTUnwrap(
      ((second["detail"] as? [String: Any])?["note"] as? [String: Any])?["noteId"] as? String
    )

    let linked = try jsonObject(await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/\(memoNoteId)/links", body: [
        "expectedProfile": profile,
        "targetNoteId": secondNoteId,
        "linkKind": "related"
      ]),
      csrfToken: "csrf"
    ))
    let links = try XCTUnwrap((linked["detail"] as? [String: Any])?["links"] as? [[String: Any]])
    XCTAssertEqual(links.count, 1)
    let linkedNotes = try XCTUnwrap((linked["detail"] as? [String: Any])?["linkedNotes"] as? [String: Any])
    XCTAssertNotNil(linkedNotes[secondNoteId])

    let window = try jsonObject(await app.webAPIResponse(
      for: RielaHTTPRequest(method: "GET", path: "/api/v1/notes/\(memoNoteId)/window", query: "pageSize=5"),
      csrfToken: "csrf"
    ))
    XCTAssertNotNil(window["notes"] as? [Any])

    let conflict = await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/memos", body: [
        "expectedProfile": "other-profile",
        "bodyMarkdown": "x"
      ]),
      csrfToken: "csrf"
    )
    XCTAssertEqual(conflict.status, 409)
    XCTAssertEqual(errorCode(conflict), "profile_conflict")
  }

  func testWorkflowProviderRoutesFailClosedWithoutConfiguration() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = fixture.app

    let memo = try jsonObject(await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/memos", body: [
        "expectedProfile": profile,
        "bodyMarkdown": "memo"
      ]),
      csrfToken: "csrf"
    ))
    let noteId = try XCTUnwrap(
      ((memo["detail"] as? [String: Any])?["note"] as? [String: Any])?["noteId"] as? String
    )
    let notebookId = try XCTUnwrap(
      ((memo["detail"] as? [String: Any])?["note"] as? [String: Any])?["notebookId"] as? String
    )

    let rewrite = await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/\(noteId)/rewrite", body: [
        "expectedProfile": profile,
        "instruction": "shorten",
        "bodyMarkdown": "memo"
      ]),
      csrfToken: "csrf"
    )
    if rewrite.status != 200 {
      XCTAssertEqual(rewrite.status, 409)
      XCTAssertEqual(errorCode(rewrite), "provider_not_configured")
    }

    let expand = await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/notebooks/\(notebookId)/expansion/prepare", body: [
        "expectedProfile": profile
      ]),
      csrfToken: "csrf"
    )
    if expand.status != 200 {
      XCTAssertEqual(expand.status, 409)
      XCTAssertEqual(errorCode(expand), "provider_not_configured")
    }
  }

  func testAgentTurnConversationAndConfigAgentRoutes() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = fixture.app

    _ = await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/memos", body: [
        "expectedProfile": profile,
        "bodyMarkdown": "The kanban orchestration design notes"
      ]),
      csrfToken: "csrf"
    )

    let turnResponse = try jsonObject(await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/agent/turns", body: [
        "expectedProfile": profile,
        "message": "kanban orchestration"
      ]),
      csrfToken: "csrf"
    ))
    let turn = try XCTUnwrap(turnResponse["turn"] as? [String: Any])
    XCTAssertEqual(turn["userMarkdown"] as? String, "kanban orchestration")
    XCTAssertNotNil(turn["assistantMarkdown"] as? String)
    let citations = try XCTUnwrap(turn["citations"] as? [[String: Any]])

    let saved = try jsonObject(await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/agent/conversations", body: [
        "expectedProfile": profile,
        "title": "Kanban chat",
        "turns": [[
          "userMarkdown": turn["userMarkdown"] as? String ?? "",
          "assistantMarkdown": turn["assistantMarkdown"] as? String ?? "",
          "citations": citations
        ]]
      ]),
      csrfToken: "csrf"
    ))
    let conversationNotebookId = try XCTUnwrap(saved["notebookId"] as? String)

    let appended = try jsonObject(await app.webAPIResponse(
      for: postRequest(
        path: "/api/v1/notes/agent/conversations/\(conversationNotebookId)/turns",
        body: [
          "expectedProfile": profile,
          "turn": [
            "userMarkdown": "follow-up",
            "assistantMarkdown": "answer",
            "citations": []
          ]
        ]
      ),
      csrfToken: "csrf"
    ))
    XCTAssertEqual(appended["notebookId"] as? String, conversationNotebookId)

    let proposal = try jsonObject(await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/config-agent/proposals", body: [
        "expectedProfile": profile,
        "message": "track research papers"
      ]),
      csrfToken: "csrf"
    ))
    let proposalObject = try XCTUnwrap(proposal["proposal"] as? [String: Any])
    XCTAssertNotNil(proposalObject["assistantMarkdown"] as? String)

    let applied = try jsonObject(await app.webAPIResponse(
      for: postRequest(path: "/api/v1/notes/config-agent/applications", body: [
        "expectedProfile": profile,
        "proposal": proposalObject
      ]),
      csrfToken: "csrf"
    ))
    let scaffold = try XCTUnwrap(applied["workflowScaffold"] as? [String: Any])
    XCTAssertNotNil(scaffold["workflowPath"] as? String)
  }

  private func makeFixture() throws -> (app: RielaApp, root: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let app = RielaApp()
    app.appHomeDirectory = root
    app.profileStore = RielaAppProfileStore(appRootURL: root)
    try app.profileStore.prepareInitialProfile(.default, persistsSelection: false)
    let noteRoot = app.noteRootURL(profileName: .default)
    try FileManager.default.createDirectory(at: noteRoot, withIntermediateDirectories: true)
    return (app, root)
  }

  private func postRequest(path: String, body: [String: Any]) -> RielaHTTPRequest {
    RielaHTTPRequest(method: "POST", path: path, body: jsonBody(body))
  }

  private func putRequest(path: String, body: [String: Any]) -> RielaHTTPRequest {
    RielaHTTPRequest(method: "PUT", path: path, body: jsonBody(body))
  }

  private func jsonBody(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  private func jsonObject(_ response: RielaHTTPResponse) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }

  private func errorCode(_ response: RielaHTTPResponse) -> String? {
    guard let object = try? jsonObject(response) else {
      return nil
    }
    return (object["error"] as? [String: Any])?["code"] as? String
  }
}
#endif
