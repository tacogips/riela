import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

private struct NotionJSONOperationCase {
  var name: String
  var operation: String
  var arguments: JSONObject
  var tier: String
}

final class NotionGatewayAddonTests: XCTestCase {
  private func input(_ name: String, query: String, env: JSONObject? = nil) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(workflowId: "notion-test", stepId: "notion-step", nodeId: "notion-node",
      addon: WorkflowNodeAddonRef(name: name, version: "1", config: ["queryTemplate": .string(query),
        "variablesTemplate": .object(["id": .string("{{pageId}}")])], env: env),
      variables: ["pageId": .string("synthetic-page")], resolvedInputPayload: [:])
  }

  private func jsonInput(_ name: String, operation: String, arguments: JSONObject,
                         env: JSONObject? = nil) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(workflowId: "notion-test", stepId: "notion-step", nodeId: "notion-node",
      addon: WorkflowNodeAddonRef(name: name, version: "1", config: [
        "operation": .string(operation), "arguments": .object(arguments)
      ], env: env), resolvedInputPayload: [:])
  }

  func testJSONModeSupportsCatalogNotionOperations() async throws {
    let environment = ["BOUND_NOTION": "synthetic-token"]
    let credentialBinding: JSONObject = ["NOTION_API_KEY": .object(["fromEnv": .string("BOUND_NOTION")])]
    let cases = [
      NotionJSONOperationCase(name: "riela/notion-gateway-write", operation: "ensurePagePath", arguments: [
        "parentId": .string("00000000-0000-0000-0000-000000000001"),
        "titles": .array([.string("Inbox"), .string("2026")]),
        "children": .array([]), "markdown": .string("synthetic")
      ], tier: "writer"),
      NotionJSONOperationCase(name: "riela/notion-gateway-read", operation: "findChildPage", arguments: [
        "parentId": .string("00000000-0000-0000-0000-000000000001"), "title": .string("Inbox")
      ], tier: "reader"),
      NotionJSONOperationCase(name: "riela/notion-gateway-write", operation: "findChildPage", arguments: [
        "parentId": .string("00000000-0000-0000-0000-000000000001"), "title": .string("Inbox")
      ], tier: "writer")
    ]

    for testCase in cases {
      let recorder = RecordingGatewayGraphQLRunner(response: #"{"data":{"result":{"id":"synthetic-page"}}}"#)
      let output = try await BuiltinWorkflowAddonResolver(
        environment: environment, localGatewayGraphQLRunner: recorder.runner
      ).execute(jsonInput(testCase.name, operation: testCase.operation,
                          arguments: testCase.arguments, env: credentialBinding), context: .init())
      let call = try XCTUnwrap(recorder.lastCall(), testCase.operation)
      XCTAssertEqual(recorder.allCalls().count, 1, testCase.operation)
      XCTAssertEqual(call.tier, testCase.tier, testCase.operation)
      XCTAssertTrue(call.document.contains("\(testCase.operation)("), testCase.operation)
      XCTAssertEqual(call.environment["NOTION_API_KEY"], "synthetic-token", testCase.operation)
      XCTAssertTrue(output.completionPassed, testCase.operation)
    }
  }

  func testReaderJSONModeRejectsEnsurePagePathBeforeDispatch() async throws {
    let recorder = RecordingGatewayGraphQLRunner()
    do {
      _ = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: recorder.runner).execute(
        jsonInput("riela/notion-gateway-read", operation: "ensurePagePath", arguments: [
          "parentId": .string("00000000-0000-0000-0000-000000000001"),
          "titles": .array([.string("Inbox")])
        ]), context: .init())
      XCTFail("reader catalog accepted writer-only ensurePagePath")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
    XCTAssertTrue(recorder.allCalls().isEmpty)
  }

  func testUploadLocalFileUsesCreateThenSendAndReturnsAppendableBlock() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/notion-upload-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("capture.JPEG")
    let bytes = Data([0, 1, 2, 253, 254, 255])
    try bytes.write(to: file)
    let recorder = RecordingGatewayGraphQLRunner(responses: [
      #"{"data":{"createFileUpload":{"id":"upload-123"}}}"#,
      #"{"data":{"sendFileUpload":{"id":"upload-123","status":"uploaded"}}}"#
    ])
    let resolver = BuiltinWorkflowAddonResolver(environment: ["NOTION_API_KEY": "synthetic-token", "UNRELATED": "secret"],
      workingDirectory: root, localGatewayGraphQLRunner: recorder.runner)
    let result = try await resolver.execute(jsonInput("riela/notion-gateway-write", operation: "uploadLocalFile", arguments: [
      "path": .string("capture.JPEG"), "caption": .string("Scene capture")
    ], env: ["NOTION_API_KEY": .object(["fromEnv": .string("NOTION_API_KEY")])]), context: .init())
    let calls = recorder.allCalls()
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(calls.map(\.tier), ["writer", "writer"])
    XCTAssertTrue(calls[0].document.contains("createFileUpload"))
    XCTAssertTrue(calls[1].document.contains("sendFileUpload"))
    XCTAssertEqual(calls[0].environment, ["NOTION_API_KEY": "synthetic-token"])
    let createVariables = try XCTUnwrap(calls[0].variablesJSON).data(using: .utf8)
      .flatMap { try? JSONDecoder().decode(JSONObject.self, from: $0) }
    XCTAssertEqual(createVariables?["filename"], .string("capture.JPEG"))
    XCTAssertEqual(createVariables?["contentType"], .string("image/jpeg"))
    let sendVariables = try XCTUnwrap(calls[1].variablesJSON).data(using: .utf8)
      .flatMap { try? JSONDecoder().decode(JSONObject.self, from: $0) }
    XCTAssertEqual(sendVariables?["id"], .string("upload-123"))
    XCTAssertEqual(sendVariables?["dataBase64"], .string(bytes.base64EncodedString()))
    guard case let .object(namespace)? = result.payload["notionGateway"] else {
      return XCTFail("missing notionGateway namespace")
    }
    XCTAssertEqual(namespace["fileUploadId"], .string("upload-123"))
    XCTAssertEqual(namespace["filename"], .string("capture.JPEG"))
    XCTAssertEqual(namespace["contentType"], .string("image/jpeg"))
    XCTAssertEqual(namespace["sizeBytes"], .integer(Int64(bytes.count)))
    XCTAssertEqual(namespace["status"], .string("uploaded"))
    XCTAssertEqual(result.payload["block"], .object([
      "object": .string("block"), "type": .string("image"),
      "image": .object([
        "type": .string("file_upload"), "file_upload": .object(["id": .string("upload-123")]),
        "caption": .array([.object(["type": .string("text"), "text": .object(["content": .string("Scene capture")])])])
      ])
    ]))
  }

  func testUploadLocalFileRejectsUnsafePathsAndReaderOperation() async throws {
    let validConfig: JSONObject = ["operation": .string("uploadLocalFile"), "arguments": .object(["path": .string("capture.png")])]
    XCTAssertTrue(BuiltinGatewayRequestChecks.issues(WorkflowNodeAddonRef(
      name: "riela/notion-gateway-write", version: "1", config: validConfig
    )).isEmpty)
    XCTAssertFalse(BuiltinGatewayRequestChecks.issues(WorkflowNodeAddonRef(
      name: "riela/notion-gateway-read", version: "1", config: validConfig
    )).isEmpty)
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/notion-upload-policy-tests", isDirectory: true)
    let outside = root.deletingLastPathComponent().appendingPathComponent("notion-upload-outside.bin")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([1]).write(to: outside)
    let smallFile = root.appendingPathComponent("inside.bin")
    try Data([1]).write(to: smallFile)
    let link = root.appendingPathComponent("escape.bin")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let largeFile = root.appendingPathComponent("large.bin")
    FileManager.default.createFile(atPath: largeFile.path, contents: Data(repeating: 1, count: 20 * 1_024 * 1_024 + 1))
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let runner = RecordingGatewayGraphQLRunner()
    let resolver = BuiltinWorkflowAddonResolver(workingDirectory: root, localGatewayGraphQLRunner: runner.runner)
    for path in [outside.path, link.path, root.path, root.appendingPathComponent("missing.bin").path, largeFile.path] {
      do {
        _ = try await resolver.execute(jsonInput("riela/notion-gateway-write", operation: "uploadLocalFile", arguments: ["path": .string(path)]), context: .init())
        XCTFail("unsafe path accepted: \(path)")
      } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
    }
    do {
      _ = try await resolver.execute(jsonInput("riela/notion-gateway-read", operation: "uploadLocalFile", arguments: ["path": .string(smallFile.path)]), context: .init())
      XCTFail("reader accepted uploadLocalFile")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
    XCTAssertTrue(runner.allCalls().isEmpty)
  }

  func testUploadLocalFileDoesNotRetryFailedSendAndSelectsAttachmentMutation() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/notion-upload-kind-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([7, 8]).write(to: root.appendingPathComponent("payload.bin"))
    let runner = RecordingGatewayGraphQLRunner(failure: AdapterExecutionError(.providerError, "send failed"),
      responses: [#"{"data":{"createAttachmentUpload":{"id":"file-9"}}}"#], failureAtCall: 2)
    let resolver = BuiltinWorkflowAddonResolver(workingDirectory: root, localGatewayGraphQLRunner: runner.runner)
    do {
      _ = try await resolver.execute(jsonInput("riela/notion-gateway-write", operation: "uploadLocalFile", arguments: [
        "path": .string("payload.bin")
      ]), context: AdapterExecutionContext())
      XCTFail("send failure was ignored")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .providerError) }
    XCTAssertEqual(runner.allCalls().count, 2)
    XCTAssertTrue(runner.allCalls()[0].document.contains("createAttachmentUpload"))
    XCTAssertTrue(runner.allCalls()[1].document.contains("sendAttachmentUpload"))
    let variablesJSON = try XCTUnwrap(runner.allCalls()[0].variablesJSON)
    let variablesData = try XCTUnwrap(variablesJSON.data(using: String.Encoding.utf8))
    let variables = try JSONDecoder().decode(JSONObject.self, from: variablesData)
    XCTAssertEqual(variables["contentType"], .string("application/octet-stream"))
  }

  func testPublishPageEnsuresPathAndChunksTopLevelBlocksInOrder() async throws {
    let responses = [
      #"{"data":{"ensurePagePath":{"id":"folder-id"}}}"#,
      #"{"data":{"createPage":{"id":"page-id","url":"https://notion.test/page-id"}}}"#,
      #"{"data":{"appendBlocks":{"id":"page-id"}}}"#,
      #"{"data":{"appendBlocks":{"id":"page-id"}}}"#
    ]
    let recorder = RecordingGatewayGraphQLRunner(responses: responses)
    var args: JSONObject = ["parentId": .string("parent-id"), "path": .array([.string("ART"), .string("YouTube")]),
      "title": .string("Video"), "children": .array((0..<230).map { .object(["type": .string("paragraph"), "paragraph": .object(["text": .string("\($0)")])]) })]
    args["position"] = .object(["type": .string("page_start")])
    let result = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: recorder.runner).execute(
      jsonInput("riela/notion-gateway-write", operation: "publishPage", arguments: args), context: .init())
    let calls = recorder.allCalls()
    XCTAssertEqual(calls.count, 4)
    XCTAssertTrue(calls[0].document.contains("ensurePagePath"))
    XCTAssertTrue(calls[1].document.contains("createPage"))
    XCTAssertEqual(calls[2].variablesJSON?.contains("page-id"), true)
    XCTAssertEqual(calls[3].variablesJSON?.contains("page-id"), true)
    let createVars = try XCTUnwrap(calls[1].variablesJSON?.data(using: .utf8)).flatMap { try? JSONDecoder().decode(JSONObject.self, from: $0) }
    XCTAssertEqual(createVars?["parentId"], .string("folder-id"))
    XCTAssertEqual(result.payload["data"], .object(["publishPage": .object([
      "pageId": .string("page-id"), "url": .string("https://notion.test/page-id"), "parentId": .string("folder-id"),
      "uploadedFiles": .array([]), "failedUploads": .array([]), "appendRequests": .integer(2), "blocks": .integer(230)
    ])]))
  }

  func testPublishPageRejectsMarkdownAndReaderAddon() async throws {
    let valid: JSONObject = ["parentId": .string("p"), "title": .string("t"), "children": .array([])]
    XCTAssertFalse(BuiltinGatewayRequestChecks.issues(WorkflowNodeAddonRef(name: "riela/notion-gateway-read", version: "1",
      config: ["operation": .string("publishPage"), "arguments": .object(valid)])).isEmpty)
    do {
      _ = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: RecordingGatewayGraphQLRunner().runner).execute(
        jsonInput("riela/notion-gateway-write", operation: "publishPage", arguments: valid.merging(["markdown": .string("no")]) { _, rhs in rhs }), context: .init())
      XCTFail("markdown was accepted")
    } catch let error as AdapterExecutionError { XCTAssertTrue(error.message.contains("does not support markdown")) }
  }

  func testPublishPageUploadsOneDistinctNestedImageAndPreservesToggle() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/notion-publish-images", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1, 2, 3]).write(to: root.appendingPathComponent("same.jpg"))
    let image: JSONValue = .object(["type": .string("image"), "image": .object([
      "type": .string("local_file"), "local_file": .object(["path": .string("same.jpg")]),
      "caption": .array([.object(["type": .string("text"), "text": .object(["content": .string("caption")])])])
    ])])
    let toggle: JSONValue = .object(["type": .string("toggle"), "toggle": .object(["rich_text": .array([]), "children": .array([image])])])
    let recorder = RecordingGatewayGraphQLRunner(responses: [
      #"{"data":{"createFileUpload":{"id":"upload-1"}}}"#,
      #"{"data":{"sendFileUpload":{"id":"upload-1","status":"uploaded"}}}"#,
      #"{"data":{"createPage":{"id":"page-1","url":"u"}}}"#
    ])
    let resolver = BuiltinWorkflowAddonResolver(workingDirectory: root, localGatewayGraphQLRunner: recorder.runner)
    let result = try await resolver.execute(jsonInput("riela/notion-gateway-write", operation: "publishPage", arguments: [
      "parentId": .string("p"), "title": .string("t"), "children": .array([image, toggle])
    ]), context: .init())
    XCTAssertEqual(recorder.allCalls().count, 3)
    guard case let .object(data)? = result.payload["data"], case let .object(published)? = data["publishPage"],
          case let .array(uploaded)? = published["uploadedFiles"] else { return XCTFail("missing publish result") }
    XCTAssertEqual(uploaded.count, 1)
    XCTAssertEqual(published["failedUploads"], .array([]))
    XCTAssertTrue(recorder.allCalls()[2].variablesJSON?.contains("file_upload") == true)
    XCTAssertTrue(recorder.allCalls()[2].variablesJSON?.contains("upload-1") == true)
  }

  func testPublishPageTurnsFailedUploadIntoPlaceholderAndReportsIt() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/notion-publish-failed", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root.appendingPathComponent("missing.jpg"))
    let recorder = RecordingGatewayGraphQLRunner(response: #"{"data":{"createPage":{"id":"page-1","url":"u"}}}"#,
      failure: AdapterExecutionError(.providerError, "upload failed"), failureAtCall: 1)
    let result = try await BuiltinWorkflowAddonResolver(workingDirectory: root, localGatewayGraphQLRunner: recorder.runner).execute(
      jsonInput("riela/notion-gateway-write", operation: "publishPage", arguments: ["parentId": .string("p"), "title": .string("t"),
        "children": .array([.object(["type": .string("image"), "image": .object(["type": .string("local_file"),
          "local_file": .object(["path": .string("missing.jpg")])])])])]), context: .init())
    guard case let .object(data)? = result.payload["data"], case let .object(published)? = data["publishPage"],
          case let .array(failed)? = published["failedUploads"] else { return XCTFail("missing failure results") }
    XCTAssertEqual(failed.count, 1)
    XCTAssertTrue(recorder.allCalls().last?.variablesJSON?.contains("画像を保存できませんでした: missing.jpg") == true)
  }

  func testPublishPageAppendFailureReportsCreatedPageAsIncomplete() async throws {
    let recorder = RecordingGatewayGraphQLRunner(response: #"{"data":{"createPage":{"id":"page-1","url":"u"}}}"#,
      failure: AdapterExecutionError(.providerError, "append failed"), failureAtCall: 2)
    do {
      _ = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: recorder.runner).execute(
        jsonInput("riela/notion-gateway-write", operation: "publishPage", arguments: ["parentId": .string("p"), "title": .string("t"),
          "children": .array((0..<101).map { .object(["type": .string("paragraph"), "paragraph": .object(["n": .integer(Int64($0))])]) })]), context: .init())
      XCTFail("append error was ignored")
    } catch let error as AdapterExecutionError {
      XCTAssertTrue(error.message.contains("\"pageId\":\"page-1\""))
      XCTAssertTrue(error.message.contains("\"incomplete\":true"))
      XCTAssertTrue(error.message.contains("append failed"))
    }
    XCTAssertEqual(recorder.allCalls().count, 2)
  }

  func testPublishPageSplitsLongTextAndRichTextArrays() async throws {
    let recorder = RecordingGatewayGraphQLRunner(response: #"{"data":{"createPage":{"id":"page-1","url":"u"}}}"#)
    let richText = (0..<101).map { _ in JSONValue.object(["type": .string("text"), "text": .object(["content": .string(String(repeating: "x", count: 2_100))])]) }
    _ = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: recorder.runner).execute(
      jsonInput("riela/notion-gateway-write", operation: "publishPage", arguments: ["parentId": .string("p"), "title": .string("t"),
        "children": .array([.object(["type": .string("paragraph"), "paragraph": .object(["rich_text": .array(richText)])])])]), context: .init())
    let variables = try XCTUnwrap(recorder.lastCall()?.variablesJSON?.data(using: .utf8)).flatMap { try? JSONDecoder().decode(JSONObject.self, from: $0) }
    guard case let .array(blocks)? = variables?["children"] else { return XCTFail("missing create blocks") }
    XCTAssertGreaterThan(blocks.count, 1)
    let json = try XCTUnwrap(String(data: JSONEncoder().encode(JSONValue.array(blocks)), encoding: .utf8))
    XCTAssertFalse(json.contains(String(repeating: "x", count: 2_001)))
  }

  func testPublishPageMovesDepthThreeChildrenToTheReturnedBlockId() async throws {
    let recorder = RecordingGatewayGraphQLRunner(responses: [
      #"{"data":{"createPage":{"id":"page-1","url":"u"}}}"#,
      #"{"data":{"blockChildren":{"results":[{"id":"root-block"}]}}}"#,
      #"{"data":{"blockChildren":{"results":[{"id":"nested-block"}]}}}"#,
      #"{"data":{"appendBlocks":{"results":[]}}}"#
    ])
    let deep: JSONValue = .object(["type": .string("toggle"), "toggle": .object(["rich_text": .array([]), "children": .array([
      .object(["type": .string("paragraph"), "paragraph": .object(["rich_text": .array([]), "children": .array([
        .object(["type": .string("paragraph"), "paragraph": .object(["rich_text": .array([])])])
      ])])])
    ])])])
    _ = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: recorder.runner).execute(
      jsonInput("riela/notion-gateway-write", operation: "publishPage", arguments: ["parentId": .string("p"), "title": .string("t"),
        "children": .array([deep])]), context: .init())
    let calls = recorder.allCalls()
    XCTAssertEqual(calls.count, 4)
    XCTAssertTrue(calls[1].document.contains("blockChildren"))
    XCTAssertTrue(calls[3].variablesJSON?.contains("nested-block") == true)
  }

  func testPinnedRoleVariablesAndOnlyExplicitCredentialBinding() async throws {
    for (name, tier) in [("riela/notion-gateway-read", "reader"), ("riela/notion-gateway-write", "writer")] {
      let recorder = RecordingGatewayGraphQLRunner(response: #"{"data":{"page":{"id":"synthetic-page","has_more":true,"next_cursor":"cursor"}},"errors":[],"extensions":{"requestId":"synthetic"}}"#)
      let resolver = BuiltinWorkflowAddonResolver(environment: ["NOTION_API_KEY": "unbound", "BOUND_NOTION": "synthetic-token", "UNRELATED_SECRET": "excluded"],
        localGatewayGraphQLRunner: recorder.runner)
      let result = try await resolver.execute(input(name, query: "query($id:ID!){page(id:$id)}", env: ["NOTION_API_KEY": .object(["fromEnv": .string("BOUND_NOTION")])]), context: AdapterExecutionContext())
      let call = try XCTUnwrap(recorder.lastCall())
      XCTAssertEqual(call.tier, tier)
      XCTAssertEqual(call.environment["NOTION_API_KEY"], "synthetic-token")
      XCTAssertNil(call.environment["UNRELATED_SECRET"])
      XCTAssertNil(call.environment["BOUND_NOTION"])
      XCTAssertEqual(call.variablesJSON, #"{"id":"synthetic-page"}"#)
      XCTAssertEqual(result.payload["data"], .object(["page": .object(["id": .string("synthetic-page"), "has_more": .bool(true), "next_cursor": .string("cursor")])]))
      XCTAssertEqual(result.provider, "notion-gateway")
    }
  }

  func testEnvironmentTargetRejectsBeforeDispatch() async throws {
    let recorder = RecordingGatewayGraphQLRunner()
    do {
      _ = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: recorder.runner).execute(
        input("riela/notion-gateway-read", query: "{page(id:\"x\")}", env: ["PATH": .string("BAD")]), context: AdapterExecutionContext())
      XCTFail("invalid credential target accepted")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
    XCTAssertTrue(recorder.allCalls().isEmpty)
  }

  func testGatewayErrorDoesNotReplayAndRetainsSafeOutcome() async throws {
    let recorder = RecordingGatewayGraphQLRunner(response: #"{"data":{},"errors":[{"message":"Notion returned HTTP503 [notionDiagnostics mutationOutcome=unknown retryAfterSeconds=3]"}]}"#)
    do {
      _ = try await BuiltinWorkflowAddonResolver(localGatewayGraphQLRunner: recorder.runner).execute(
        input("riela/notion-gateway-write", query: "mutation{archivePage(id:\"x\")}"), context: AdapterExecutionContext())
      XCTFail("error accepted")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertTrue(error.message.contains("mutationOutcome=unknown"))
      XCTAssertTrue(error.message.contains("retryAfterSeconds=3"))
    }
    XCTAssertEqual(recorder.allCalls().count, 1)
  }

  #if os(macOS)
  func testLinkedWriterValidatesPagePositionBeforeCredentialsOrNetwork() async throws {
    let result = try await runNativeGatewayCLI(.init(gateway: .notion, role: "writer", arguments: [
      "graphql", "--query", "mutation($position:JSON){createPage(parentId:\"00000000-0000-0000-0000-000000000001\",title:\"fixture\",position:$position)}",
      "--variables", #"{"position":{"type":"invalid"}}"#
    ]), environment: [:])
    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Invalid page insertion position"))
    XCTAssertFalse(result.stdout.contains("AUTHENTICATION_REQUIRED"))
  }

  func testLinkedReaderRejectsMutationWithoutCredentialsOrNetwork() async throws {
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
        input("riela/notion-gateway-read", query: "mutation{archivePage(id:\"00000000-0000-0000-0000-000000000001\")}"), context: AdapterExecutionContext())
      XCTFail("reader mutation accepted")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertFalse(error.message.contains("AUTHENTICATION_REQUIRED"))
    }
    let schema = try await runNativeGatewayCLI(.init(gateway: .notion, role: "reader", arguments: ["schema"]), environment: [:])
    XCTAssertEqual(schema.exitCode, 0)
    XCTAssertFalse(schema.stdout.contains("createPage"))
    XCTAssertTrue(schema.stdout.contains("findChildPage(parentId: ID!, title: String!)"))
    let writerSchema = try await runNativeGatewayCLI(.init(gateway: .notion, role: "writer", arguments: ["schema"]), environment: [:])
    XCTAssertTrue(writerSchema.stdout.contains("findChildPage(parentId: ID!, title: String!)"))
    XCTAssertTrue(writerSchema.stdout.contains("ensurePagePath(parentId: ID!, titles: [String!]!, children: JSON, markdown: String)"))
    let createPage = try XCTUnwrap(writerSchema.stdout.split(separator: "\n").first { $0.contains("createPage(") })
    XCTAssertTrue(createPage.contains("position: JSON"))
    XCTAssertTrue(writerSchema.stdout.contains("createFileUpload"))
    XCTAssertTrue(writerSchema.stdout.contains("sendFileUpload"))
    XCTAssertTrue(writerSchema.stdout.contains("position: JSON"))
    XCTAssertTrue(writerSchema.stdout.contains("createAttachmentUpload"))
    XCTAssertTrue(writerSchema.stdout.contains("sendAttachmentUpload"))
    XCTAssertTrue(schema.stdout.contains("downloadBlockFile"))
    XCTAssertFalse(schema.stdout.contains("createAttachmentUpload"))
    XCTAssertTrue(schema.stdout.contains("downloadBlockImage"))
    XCTAssertFalse(schema.stdout.contains("sendFileUpload"))
  }
  #endif
}
