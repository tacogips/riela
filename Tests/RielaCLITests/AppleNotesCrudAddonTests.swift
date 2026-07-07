import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleNotesCrudAddonTests: XCTestCase {
  func testAppleNoteGetPassesNoteIdAsVariablesAndParsesNote() async throws {
    let fake = try CrudFakeAppleGateway(mode: "get")
    defer { fake.cleanup() }

    let output = try await runAppleNoteAddon(
      "riela/apple-note-get",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["noteId": .string("note-1")]
    )

    XCTAssertEqual(output.when["has_note"], true)
    let note = try XCTUnwrap(crudTestObject(output.payload["appleNote"]))
    XCTAssertEqual(note["id"], .string("note-1"))
    XCTAssertEqual(note["plaintext"], .string("plain body"))
    XCTAssertFalse(try String(contentsOf: fake.queryLogURL).contains("note-1"))
    XCTAssertTrue(try String(contentsOf: fake.variablesLogURL).contains(#""noteId":"note-1""#))
  }

  func testAppleNoteGetMaterializesBodyFileThroughDownloadKey() async throws {
    let fake = try CrudFakeAppleGateway(mode: "get-body-file")
    defer { fake.cleanup() }
    let downloadRoot = fake.rootURL.appendingPathComponent("downloads", isDirectory: true)
    try createCrudTestDirectory(downloadRoot, permissions: 0o700)

    let output = try await runAppleNoteAddon(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(downloadRoot.path)
      ],
      inputs: ["noteId": .string("note-large")]
    )

    let note = try XCTUnwrap(crudTestObject(output.payload["appleNote"]))
    let bodyFile = try XCTUnwrap(crudTestObject(note["bodyFile"]))
    let localPath = try XCTUnwrap(crudTestString(bodyFile["localPath"]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: localPath))
    XCTAssertEqual(crudTestObject(note["body"])?.getString("materializedPath"), localPath)
    let args = try String(contentsOf: fake.argumentLogURL)
    XCTAssertTrue(args.contains("file\n"))
    XCTAssertTrue(args.contains("--key\nbody-key\n"))
    XCTAssertTrue(args.contains("--output-dir\n\(downloadRoot.path)\n"))
  }

  func testAppleNoteGetMaterializeFailsWhenDownloadKeyMappingIsMissing() async throws {
    let fake = try CrudFakeAppleGateway(mode: "get-body-file-missing-download-mapping")
    defer { fake.cleanup() }
    let downloadRoot = fake.rootURL.appendingPathComponent("downloads", isDirectory: true)
    try createCrudTestDirectory(downloadRoot, permissions: 0o700)

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(downloadRoot.path)
      ],
      inputs: ["noteId": .string("note-large")],
      code: .providerError,
      messageContains: "body-key"
    )
  }

  func testAppleNoteGetMaterializeValidatesDownloadedLocalPath() async throws {
    let outsideFake = try CrudFakeAppleGateway(mode: "get-body-file-outside-download-root")
    let missingFake = try CrudFakeAppleGateway(mode: "get-body-file-missing-downloaded-file")
    defer {
      outsideFake.cleanup()
      missingFake.cleanup()
    }
    let outsideDownloadRoot = outsideFake.rootURL.appendingPathComponent("downloads", isDirectory: true)
    let missingDownloadRoot = missingFake.rootURL.appendingPathComponent("downloads", isDirectory: true)
    try createCrudTestDirectory(outsideDownloadRoot, permissions: 0o700)
    try createCrudTestDirectory(missingDownloadRoot, permissions: 0o700)

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(outsideFake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(outsideDownloadRoot.path)
      ],
      inputs: ["noteId": .string("note-large")],
      code: .providerError,
      messageContains: "outside outputRoot"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(missingFake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(missingDownloadRoot.path)
      ],
      inputs: ["noteId": .string("note-large")],
      code: .providerError,
      messageContains: "does not exist"
    )
  }

  func testAppleNoteGetMaterializeRejectsSymlinkRootsAndFiles() async throws {
    let rootSymlinkFake = try CrudFakeAppleGateway(mode: "get-body-file")
    let fileSymlinkFake = try CrudFakeAppleGateway(mode: "get-body-file-symlink-downloaded-file")
    defer {
      rootSymlinkFake.cleanup()
      fileSymlinkFake.cleanup()
    }
    let realDownloadRoot = rootSymlinkFake.rootURL.appendingPathComponent("real-downloads", isDirectory: true)
    let symlinkDownloadRoot = rootSymlinkFake.rootURL.appendingPathComponent("download-link", isDirectory: true)
    let fileSymlinkDownloadRoot = fileSymlinkFake.rootURL.appendingPathComponent("downloads", isDirectory: true)
    try createCrudTestDirectory(realDownloadRoot, permissions: 0o700)
    try FileManager.default.createSymbolicLink(at: symlinkDownloadRoot, withDestinationURL: realDownloadRoot)
    try createCrudTestDirectory(fileSymlinkDownloadRoot, permissions: 0o700)

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(rootSymlinkFake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(symlinkDownloadRoot.path)
      ],
      inputs: ["noteId": .string("note-large")],
      code: .policyBlocked,
      messageContains: "symbolic link"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(fileSymlinkFake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(fileSymlinkDownloadRoot.path)
      ],
      inputs: ["noteId": .string("note-large")],
      code: .providerError,
      messageContains: "symbolic link local path"
    )
  }

  func testAppleNoteGetMaterializeRejectsSymlinkAncestorBeforeCreate() async throws {
    let fake = try CrudFakeAppleGateway(mode: "get-body-file")
    defer { fake.cleanup() }
    let realParent = fake.rootURL.appendingPathComponent("real-parent", isDirectory: true)
    let symlinkParent = fake.rootURL.appendingPathComponent("symlink-parent", isDirectory: true)
    let nestedDownloadRoot = symlinkParent.appendingPathComponent("downloads", isDirectory: true)
    try createCrudTestDirectory(realParent, permissions: 0o700)
    try FileManager.default.createSymbolicLink(at: symlinkParent, withDestinationURL: realParent)

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(nestedDownloadRoot.path)
      ],
      inputs: ["noteId": .string("note-large")],
      code: .policyBlocked,
      messageContains: "symbolic link component"
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: realParent.appendingPathComponent("downloads").path))
  }

  func testAppleNoteGetMaterializeRejectsPublicRootsAndAcceptsOwnerPrivateRoot() async throws {
    let fake = try CrudFakeAppleGateway(mode: "get-body-file")
    defer { fake.cleanup() }
    let worldReadableRoot = fake.rootURL.appendingPathComponent("world-readable-downloads", isDirectory: true)
    let worldWritableRoot = fake.rootURL.appendingPathComponent("world-writable-downloads", isDirectory: true)
    let ownerPrivateRoot = fake.rootURL.appendingPathComponent("owner-private-downloads", isDirectory: true)
    try createCrudTestDirectory(worldReadableRoot, permissions: 0o755)
    try createCrudTestDirectory(worldWritableRoot, permissions: 0o777)
    try createCrudTestDirectory(ownerPrivateRoot, permissions: 0o700)

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(worldReadableRoot.path)
      ],
      inputs: ["noteId": .string("note-large")],
      code: .policyBlocked,
      messageContains: "owner-private"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(worldWritableRoot.path)
      ],
      inputs: ["noteId": .string("note-large")],
      code: .policyBlocked,
      messageContains: "owner-private"
    )

    let output = try await runAppleNoteAddon(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(ownerPrivateRoot.path)
      ],
      inputs: ["noteId": .string("note-large")]
    )
    let note = try XCTUnwrap(crudTestObject(output.payload["appleNote"]))
    XCTAssertNotNil(crudTestObject(note["body"])?.getString("materializedPath"))
  }

  func testAppleNoteGetMaterializeWithoutRootFailsPolicyBlocked() async throws {
    let fake = try CrudFakeAppleGateway(mode: "get-body-file")
    defer { fake.cleanup() }

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "materializeBody": .bool(true)
      ],
      inputs: ["noteId": .string("note-large")],
      code: .policyBlocked,
      messageContains: "materializeBody requires"
    )
  }

  func testAppleNoteCreateSuccessAndMissingTitleValidation() async throws {
    let fake = try CrudFakeAppleGateway(mode: "create")
    defer { fake.cleanup() }

    let output = try await runAppleNoteAddon(
      "riela/apple-note-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["title": .string("New Note"), "bodyText": .string("hello")]
    )

    XCTAssertEqual(output.payload["created"], .bool(true))
    XCTAssertEqual(crudTestObject(output.payload["appleNote"])?.getString("id"), "created-1")
    let variables = try String(contentsOf: fake.variablesLogURL)
    XCTAssertTrue(variables.contains(#""title":"New Note""#))
    XCTAssertTrue(variables.contains(#""bodyText":"hello""#))

    try await assertAppleNoteFailure(
      "riela/apple-note-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["bodyText": .string("hello")],
      code: .policyBlocked,
      messageContains: "title is required"
    )
  }

  func testAppleNoteCrudRejectsWhitespaceOnlyRequiredInputs() async throws {
    let fake = try CrudFakeAppleGateway(mode: "create")
    defer { fake.cleanup() }
    let config: JSONObject = ["binaryPath": .string(fake.executableURL.path)]

    try await assertAppleNoteFailure(
      "riela/apple-note-create",
      config: config,
      inputs: ["title": .string(" \n\t "), "bodyText": .string("body")],
      code: .policyBlocked,
      messageContains: "title is required"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-create",
      config: config,
      inputs: ["title": .string("title"), "bodyText": .string(" \n\t ")],
      code: .policyBlocked,
      messageContains: "requires bodyHtml or bodyText"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-update-body",
      config: config,
      inputs: ["noteId": .string("note-1"), "bodyHtml": .string(" \n\t ")],
      code: .policyBlocked,
      messageContains: "requires bodyHtml or bodyText"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: config,
      inputs: ["noteId": .string(" \n\t ")],
      code: .policyBlocked,
      messageContains: "noteId is required"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-delete",
      config: config,
      inputs: ["noteId": .string(" \n\t ")],
      code: .policyBlocked,
      messageContains: "noteId is required"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-move",
      config: config,
      inputs: ["noteId": .string("note-1"), "folderId": .string(" \n\t ")],
      code: .policyBlocked,
      messageContains: "folderId is required"
    )
  }

  func testAppleNoteUpdateReplaceAndAppendModes() async throws {
    let replaceFake = try CrudFakeAppleGateway(mode: "update")
    let appendFake = try CrudFakeAppleGateway(mode: "update")
    defer {
      replaceFake.cleanup()
      appendFake.cleanup()
    }

    let replaceOutput = try await runAppleNoteAddon(
      "riela/apple-note-update-body",
      config: ["binaryPath": .string(replaceFake.executableURL.path)],
      inputs: ["noteId": .string("note-1"), "mode": .string("REPLACE"), "bodyText": .string("replacement")]
    )
    XCTAssertEqual(replaceOutput.payload["updated"], .bool(true))
    XCTAssertTrue(try String(contentsOf: replaceFake.variablesLogURL).contains(#""mode":"REPLACE""#))

    let appendOutput = try await runAppleNoteAddon(
      "riela/apple-note-update-body",
      config: ["binaryPath": .string(appendFake.executableURL.path), "mode": .string("APPEND")],
      inputs: ["noteId": .string("note-1"), "bodyText": .string("appendix")]
    )
    XCTAssertEqual(appendOutput.payload["updated"], .bool(true))
    XCTAssertTrue(try String(contentsOf: appendFake.variablesLogURL).contains(#""mode":"APPEND""#))
  }

  func testAppleNoteDeleteAndMoveSuccess() async throws {
    let deleteFake = try CrudFakeAppleGateway(mode: "delete")
    let moveFake = try CrudFakeAppleGateway(mode: "move")
    defer {
      deleteFake.cleanup()
      moveFake.cleanup()
    }

    let deleteOutput = try await runAppleNoteAddon(
      "riela/apple-note-delete",
      config: ["binaryPath": .string(deleteFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")]
    )
    XCTAssertEqual(deleteOutput.payload["deleted"], .bool(true))
    XCTAssertEqual(crudTestObject(deleteOutput.payload["deleteResult"])?.getBool("success"), true)

    let moveOutput = try await runAppleNoteAddon(
      "riela/apple-note-move",
      config: ["binaryPath": .string(moveFake.executableURL.path)],
      inputs: ["noteId": .string("note-1"), "folderId": .string("folder-2")]
    )
    XCTAssertEqual(moveOutput.payload["moved"], .bool(true))
    XCTAssertEqual(crudTestObject(moveOutput.payload["appleNote"])?.getString("folderId"), "folder-2")
    XCTAssertTrue(try String(contentsOf: moveFake.variablesLogURL).contains(#""folderId":"folder-2""#))
  }

  func testAppleNoteGraphQLErrorsPreserveLockedAndPermissionDetails() async throws {
    let lockedFake = try CrudFakeAppleGateway(mode: "note-locked")
    let permissionFake = try CrudFakeAppleGateway(mode: "permission-denied")
    defer {
      lockedFake.cleanup()
      permissionFake.cleanup()
    }

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(lockedFake.executableURL.path)],
      inputs: ["noteId": .string("locked")],
      code: .providerError,
      messageContains: "NOTE_LOCKED"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-delete",
      config: ["binaryPath": .string(permissionFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")],
      code: .providerError,
      messageContains: "permission denied"
    )
  }

  func testAppleNoteCrudMapsProcessAndEnvelopeFailures() async throws {
    let nonzeroFake = try CrudFakeAppleGateway(mode: "nonzero")
    let malformedFake = try CrudFakeAppleGateway(mode: "malformed")
    let missingMutationFake = try CrudFakeAppleGateway(mode: "missing-mutation")
    let nonObjectNoteFake = try CrudFakeAppleGateway(mode: "get-nonobject-note")
    defer {
      nonzeroFake.cleanup()
      malformedFake.cleanup()
      missingMutationFake.cleanup()
      nonObjectNoteFake.cleanup()
    }

    try await assertAppleNoteFailure(
      "riela/apple-note-create",
      config: ["binaryPath": .string(nonzeroFake.executableURL.path)],
      inputs: ["title": .string("New"), "bodyText": .string("body")],
      code: .providerError,
      messageContains: "exit code 9"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-create",
      config: ["binaryPath": .string(malformedFake.executableURL.path)],
      inputs: ["title": .string("New"), "bodyText": .string("body")],
      code: .invalidOutput,
      messageContains: "not valid JSON"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-create",
      config: ["binaryPath": .string(missingMutationFake.executableURL.path)],
      inputs: ["title": .string("New"), "bodyText": .string("body")],
      code: .invalidOutput,
      messageContains: "data.createNote is missing"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(nonObjectNoteFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")],
      code: .invalidOutput,
      messageContains: "data.note must be an object or null"
    )
  }

  func testAppleNoteCrudMapsBinaryTimeoutEnvAndVersionFailures() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-notes-crud-nonexec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let nonExecutable = root.appendingPathComponent("apple-gateway")
    try Data("#!/bin/sh\n".utf8).write(to: nonExecutable)

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(nonExecutable.path)],
      inputs: ["noteId": .string("note-1")],
      code: .policyBlocked,
      messageContains: "config.binaryPath is not executable"
    )

    let sleepFake = try CrudFakeAppleGateway(mode: "sleep")
    let childStdoutFake = try CrudFakeAppleGateway(mode: "timeout-child-holds-stdout")
    let childStdoutAfterExitFake = try CrudFakeAppleGateway(mode: "child-holds-stdout-after-success")
    let childMutationFake = try CrudFakeAppleGateway(mode: "timeout-child-writes-marker")
    defer {
      sleepFake.cleanup()
      childStdoutFake.cleanup()
      childStdoutAfterExitFake.cleanup()
      childMutationFake.cleanup()
    }
    let startedAt = Date()
    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(sleepFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")],
      code: .timeout,
      messageContains: "deadline",
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
    )
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)

    let inheritedPipeStartedAt = Date()
    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(childStdoutFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")],
      code: .timeout,
      messageContains: "deadline",
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
    )
    XCTAssertLessThan(Date().timeIntervalSince(inheritedPipeStartedAt), 2)

    let inheritedPipeNoDeadlineStartedAt = Date()
    let inheritedPipeOutput = try await runAppleNoteAddon(
      "riela/apple-note-get",
      config: ["binaryPath": .string(childStdoutAfterExitFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")]
    )
    XCTAssertEqual(inheritedPipeOutput.when["has_note"], true)
    XCTAssertLessThan(Date().timeIntervalSince(inheritedPipeNoDeadlineStartedAt), 2)

    try await assertAppleNoteFailure(
      "riela/apple-note-delete",
      config: ["binaryPath": .string(childMutationFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")],
      code: .timeout,
      messageContains: "deadline",
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
    )
    try await Task.sleep(nanoseconds: 700_000_000)
    XCTAssertFalse(FileManager.default.fileExists(atPath: childMutationFake.descendantMarkerURL.path))

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(sleepFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")],
      env: ["UNSAFE": .object(["fromEnv": .string("UNSAFE")])],
      code: .policyBlocked,
      messageContains: "does not support addon.env"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(sleepFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")],
      version: "2",
      code: .policyBlocked,
      messageContains: "unsupported"
    )
  }

  func testAppleNoteCrudVariablesAreNotInjectedIntoGraphQLDocument() async throws {
    let fake = try CrudFakeAppleGateway(mode: "create")
    defer { fake.cleanup() }
    let title = "quote \" brace } newline\nsentinel"

    _ = try await runAppleNoteAddon(
      "riela/apple-note-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["title": .string(title), "bodyText": .string("body")]
    )

    let query = try String(contentsOf: fake.queryLogURL)
    let variables = try String(contentsOf: fake.variablesLogURL)
    XCTAssertFalse(query.contains("sentinel"))
    XCTAssertFalse(query.contains(title))
    XCTAssertTrue(variables.contains(#""title":"quote \" brace } newline\nsentinel""#))
  }

  func testAppleNoteCrudResolvedUserTextIsNotTemplatedTwice() async throws {
    let fake = try CrudFakeAppleGateway(mode: "create")
    defer { fake.cleanup() }

    _ = try await runAppleNoteAddon(
      "riela/apple-note-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: [
        "title": .string("{{workflowTitle}}"),
        "bodyText": .string("{{workflowBody}}")
      ],
      resolvedInputPayload: [
        "workflowTitle": .string("Keep literal {{doNotExpandTitle}}"),
        "workflowBody": .string("Body literal {{doNotExpandBody}}"),
        "doNotExpandTitle": .string("expanded-title"),
        "doNotExpandBody": .string("expanded-body")
      ]
    )

    let variables = try String(contentsOf: fake.variablesLogURL)
    XCTAssertTrue(variables.contains(#""title":"Keep literal {{doNotExpandTitle}}""#), variables)
    XCTAssertTrue(variables.contains(#""bodyText":"Body literal {{doNotExpandBody}}""#), variables)
    XCTAssertFalse(variables.contains("expanded-title"), variables)
    XCTAssertFalse(variables.contains("expanded-body"), variables)
  }

  private func runAppleNoteAddon(
    _ addonName: String,
    version: String = "1",
    config: JSONObject = [:],
    inputs: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    resolvedInputPayload: JSONObject = [:],
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
      WorkflowAddonExecutionInput(
        workflowId: "apple-notes-crud",
        stepId: "apple-note-step",
        nodeId: "apple-note-step",
        addon: WorkflowNodeAddonRef(
          name: addonName,
          version: version,
          config: config,
          env: env,
          inputs: inputs
        ),
        variables: [:],
        resolvedInputPayload: resolvedInputPayload
      ),
      context: context
    )
  }

  private func assertAppleNoteFailure(
    _ addonName: String,
    config: JSONObject,
    inputs: JSONObject,
    env: JSONObject? = nil,
    version: String = "1",
    code: AdapterExecutionErrorCode,
    messageContains: String,
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws {
    do {
      _ = try await runAppleNoteAddon(
        addonName,
        version: version,
        config: config,
        inputs: inputs,
        env: env,
        context: context
      )
      XCTFail("expected Apple Notes CRUD add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }
}

private struct CrudFakeAppleGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var argumentLogURL: URL
  var queryLogURL: URL
  var variablesLogURL: URL
  var descendantMarkerURL: URL

  init(mode: String) throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-notes-crud-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent("fake-apple-gateway")
    argumentLogURL = rootURL.appendingPathComponent("args.log")
    queryLogURL = rootURL.appendingPathComponent("query.graphql")
    variablesLogURL = rootURL.appendingPathComponent("variables.json")
    descendantMarkerURL = rootURL.appendingPathComponent("descendant-marker")
    try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
    try script(mode: mode).write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private func script(mode: String) -> String {
    """
    #!/bin/sh
    {
      printf "CALL\\n"
      for arg in "$@"; do printf "%s\\n" "$arg"; done
    } >> "\(argumentLogURL.path)"

    command="$1"
    if [ "$command" = "file" ]; then
      shift
      subcommand="$1"
      shift
      key=""
      output_dir=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --key)
            shift
            key="$1"
            ;;
          --output-dir)
            shift
            output_dir="$1"
            ;;
        esac
        shift
      done
      mkdir -p "$output_dir"
      local_path="$output_dir/body.txt"
      printf "large body" > "$local_path"
      if [ "\(mode)" = "get-body-file-missing-download-mapping" ]; then
        printf '{"files":[{"downloadKey":"other-key","localPath":"%s","byteSize":10}]}\\n' "$local_path"
        exit 0
      fi
      if [ "\(mode)" = "get-body-file-outside-download-root" ]; then
        outside_path="\(rootURL.path)/outside-body.txt"
        printf "large body" > "$outside_path"
        printf '{"files":[{"downloadKey":"%s","localPath":"%s","byteSize":10}]}\\n' "$key" "$outside_path"
        exit 0
      fi
      if [ "\(mode)" = "get-body-file-missing-downloaded-file" ]; then
        missing_path="$output_dir/missing-body.txt"
        printf '{"files":[{"downloadKey":"%s","localPath":"%s","byteSize":10}]}\\n' "$key" "$missing_path"
        exit 0
      fi
      if [ "\(mode)" = "get-body-file-symlink-downloaded-file" ]; then
        outside_path="\(rootURL.path)/outside-symlink-body.txt"
        printf "large body" > "$outside_path"
        rm -f "$local_path"
        ln -s "$outside_path" "$local_path"
        printf '{"files":[{"downloadKey":"%s","localPath":"%s","byteSize":10}]}\\n' "$key" "$local_path"
        exit 0
      fi
      printf '{"files":[{"downloadKey":"%s","localPath":"%s","byteSize":10}]}\\n' "$key" "$local_path"
      exit 0
    fi

    query=""
    variables=""
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --query)
          shift
          query="$1"
          ;;
        --variables)
          shift
          variables="$1"
          ;;
      esac
      shift
    done
    printf "%s" "$query" > "\(queryLogURL.path)"
    printf "%s" "$variables" > "\(variablesLogURL.path)"

    case "\(mode)" in
      get)
        /bin/cat <<'JSON'
    {
      "data": {
        "note": {
          "id": "note-1",
          "accountId": "account-1",
          "folderId": "folder-1",
          "name": "Project",
          "snippet": "plain",
          "plaintext": "plain body",
          "isPasswordProtected": false,
          "isShared": false,
          "creationDate": "2026-07-07T00:00:00Z",
          "modificationDate": "2026-07-07T01:00:00Z"
        }
      },
      "extensions": {"requestId": "crud-get"}
    }
    JSON
        ;;
      get-body-file|get-body-file-missing-download-mapping|get-body-file-outside-download-root|get-body-file-missing-downloaded-file|get-body-file-symlink-downloaded-file)
        /bin/cat <<'JSON'
    {
      "data": {
        "note": {
          "id": "note-large",
          "accountId": "account-1",
          "folderId": "folder-1",
          "name": "Large",
          "snippet": "large",
          "bodyFile": {"downloadKey": "body-key", "kind": "html", "byteSize": 1000},
          "isPasswordProtected": false,
          "isShared": false,
          "creationDate": "2026-07-07T00:00:00Z",
          "modificationDate": "2026-07-07T01:00:00Z"
        }
      },
      "extensions": {"requestId": "crud-get-body"}
    }
    JSON
        ;;
      create)
        /bin/cat <<'JSON'
    {
      "data": {
        "createNote": {
          "id": "created-1",
          "accountId": "account-1",
          "folderId": "folder-1",
          "name": "New Note",
          "snippet": "hello",
          "creationDate": "2026-07-07T00:00:00Z",
          "modificationDate": "2026-07-07T00:00:00Z"
        }
      },
      "extensions": {"requestId": "crud-create"}
    }
    JSON
        ;;
      update)
        /bin/cat <<'JSON'
    {"data":{"updateNoteBody":{"id":"note-1","name":"Updated","snippet":"updated","modificationDate":"2026-07-07T02:00:00Z"}},"extensions":{"requestId":"crud-update"}}
    JSON
        ;;
      delete)
        /bin/cat <<'JSON'
    {"data":{"deleteNote":{"success":true}},"extensions":{"requestId":"crud-delete"}}
    JSON
        ;;
      move)
        /bin/cat <<'JSON'
    {"data":{"moveNote":{"id":"note-1","folderId":"folder-2","name":"Moved","modificationDate":"2026-07-07T03:00:00Z"}},"extensions":{"requestId":"crud-move"}}
    JSON
        ;;
      note-locked)
        printf '{"data":null,"errors":[{"message":"note is locked","extensions":{"code":"NOTE_LOCKED"}}],"extensions":{"requestId":"locked"}}\\n'
        ;;
      permission-denied)
        printf '{"data":null,"errors":[{"message":"notes permission denied","extensions":{"code":"PERMISSION_DENIED"}}],"extensions":{"requestId":"denied"}}\\n'
        ;;
      nonzero)
        echo 'upstream failed' >&2
        exit 9
        ;;
      malformed)
        printf 'not-json\\n'
        ;;
      missing-mutation)
        printf '{"data":{},"extensions":{"requestId":"missing"}}\\n'
        ;;
      get-nonobject-note)
        printf '{"data":{"note":"malformed"},"extensions":{"requestId":"bad-note"}}\\n'
        ;;
      sleep)
        sleep 5
        ;;
      timeout-child-holds-stdout)
        (sleep 5) &
        sleep 5
        ;;
    \(childStdoutAfterSuccessCase())
      timeout-child-writes-marker)
        (sleep 0.4; printf "mutated-after-timeout" > "\(descendantMarkerURL.path)") &
        sleep 5
        ;;
    esac
    """
  }

  private func childStdoutAfterSuccessCase() -> String {
    """
      child-holds-stdout-after-success)
        (sleep 5) &
        /bin/cat <<'JSON'
    {
      "data": {
        "note": {
          "id": "note-1",
          "accountId": "account-1",
          "folderId": "folder-1",
          "name": "Project",
          "snippet": "plain",
          "plaintext": "plain body",
          "isPasswordProtected": false,
          "isShared": false,
          "creationDate": "2026-07-07T00:00:00Z",
          "modificationDate": "2026-07-07T01:00:00Z"
        }
      },
      "extensions": {"requestId": "crud-get-child-stdout"}
    }
    JSON
        ;;
    """
  }
}

private func createCrudTestDirectory(_ url: URL, permissions: Int) throws {
  try FileManager.default.createDirectory(
    at: url,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: permissions]
  )
  try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

private extension JSONObject {
  func getString(_ key: String) -> String? {
    crudTestString(self[key])
  }

  func getBool(_ key: String) -> Bool? {
    guard case let .bool(value)? = self[key] else {
      return nil
    }
    return value
  }
}

private func crudTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}

private func crudTestString(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}
