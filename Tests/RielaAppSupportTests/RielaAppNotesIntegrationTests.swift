#if os(macOS)
import AppKit
import RielaAppSupport
import RielaNote
@testable import RielaNoteWorkspace
import RielaServer
@testable import RielaApp
import XCTest

/// Integration coverage for the note seams that outlived the SwiftUI Notes and
/// Note Settings windows: the profile-scoped note root, the settings store, S3
/// profile resolution, the registration challenge flow, and the daemon server
/// configuration derived from note settings. The user-facing surfaces now live
/// in the web app (`web/src`) backed by the /api/v1 note workspace routes.
@MainActor
final class RielaAppNotesIntegrationTests: XCTestCase {
  func testNoteRootUsesHomeScopedProfileDirectory() throws {
    let root = try scratchRoot(name: "riela-app-note-root-\(UUID().uuidString)")
    let app = RielaApp()
    app.appHomeDirectory = root

    let noteRoot = app.noteRootURL(profileName: RielaAppProfileName("work/team"))

    XCTAssertEqual(noteRoot.path, root.appendingPathComponent(".riela/profiles/work-team/note").path)
  }

  func testStatusMenuOpensNotesOnTheWeb() throws {
    let app = RielaApp()
    app.rebuildMenu()

    let titles = try XCTUnwrap(app.statusItem.menu?.items.map(\.title))

    XCTAssertEqual(titles.first, "Instances...")
    XCTAssertTrue(titles.contains("Notes (Web)..."))
    XCTAssertFalse(titles.contains("Note Settings..."))
    XCTAssertEqual(app.statusItem.menu?.items.first { $0.title == "Notes (Web)..." }?.target as? RielaApp, app)
  }

  func testNotebookExpansionProviderConfiguredOnlyWhenBundleIsDiscoverable() throws {
    let scratch = try scratchRoot(name: "riela-app-note-expansion-provider-\(UUID().uuidString)")
    let workflowRoot = scratch.appendingPathComponent("examples", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("note-notebook-compact", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: workflowDirectory.appendingPathComponent("workflow.json"))
    let executable = scratch.appendingPathComponent("riela")
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    XCTAssertNotNil(RielaNoteWorkflowNotebookCompactProvider.defaultProvider(environment: [
      "RIELA_NOTE_NOTEBOOK_COMPACT_WORKFLOW_DIR": workflowRoot.path,
      "RIELA_NOTE_NOTEBOOK_COMPACT_RIELA_EXECUTABLE": executable.path
    ]))
    XCTAssertNil(RielaNoteWorkflowNotebookCompactProvider.defaultProvider(environment: [
      "RIELA_NOTE_NOTEBOOK_COMPACT_WORKFLOW_DIR": scratch
        .appendingPathComponent("missing-examples", isDirectory: true).path,
      "RIELA_NOTE_NOTEBOOK_COMPACT_RIELA_EXECUTABLE": scratch
        .appendingPathComponent("missing-riela").path
    ]))
  }

  func testS3ProfileResolvesFromEnvironment() throws {
    let profiles = try RielaAppNoteS3ProfileResolver().profiles(
      settings: RielaAppNoteSettings(),
      environment: [
        "RIELA_NOTE_S3_PROFILE": "app-s3",
        "RIELA_NOTE_S3_ENDPOINT": "https://s3.example.test",
        "RIELA_NOTE_S3_REGION": "ap-northeast-1",
        "RIELA_NOTE_S3_BUCKET": "notes",
        "RIELA_NOTE_S3_KEY_PREFIX": "profile/default",
        "AWS_ACCESS_KEY_ID": "access-key",
        "AWS_SECRET_ACCESS_KEY": "secret-key"
      ]
    )

    XCTAssertEqual(profiles.map(\.name), ["app-s3"])
    XCTAssertEqual(profiles.first?.endpoint.absoluteString, "https://s3.example.test")
    XCTAssertEqual(profiles.first?.keyPrefix, "profile/default")
  }

  func testS3ProfileResolvesNamedProfileFromSettings() throws {
    let settings = RielaAppNoteSettings(
      s3Profiles: [
        RielaAppNoteS3ProfileSettings(
          name: "settings-s3",
          endpoint: "https://settings-s3.example.test",
          region: "ap-northeast-1",
          bucket: "notes",
          accessKeyIdEnv: "NOTE_ACCESS_KEY_ID",
          secretAccessKeyEnv: "NOTE_SECRET_ACCESS_KEY",
          keyPrefix: "profiles/default"
        )
      ]
    )

    let resolved = try RielaAppNoteS3ProfileResolver().profiles(
      settings: settings,
      environment: [
        "NOTE_ACCESS_KEY_ID": "access-key",
        "NOTE_SECRET_ACCESS_KEY": "secret-key"
      ]
    )
    XCTAssertEqual(resolved.map(\.name), ["settings-s3"])
    XCTAssertEqual(resolved.first?.endpoint.absoluteString, "https://settings-s3.example.test")
    XCTAssertEqual(resolved.first?.bucket, "notes")
    XCTAssertEqual(resolved.first?.keyPrefix, "profiles/default")

    // Profiles whose credential environment variables are absent are skipped
    // rather than failing the whole workspace.
    let unresolved = try RielaAppNoteS3ProfileResolver().profiles(settings: settings, environment: [:])
    XCTAssertEqual(unresolved, [])
  }

  func testS3ProfileRejectsPartialEnvironment() {
    XCTAssertThrowsError(try RielaAppNoteS3ProfileResolver().profiles(
      settings: RielaAppNoteSettings(),
      environment: ["RIELA_NOTE_S3_ENDPOINT": "https://s3.example.test"]
    )) { error in
      XCTAssertEqual(error as? RielaAppNoteS3ProfileError, .incompleteProfile)
    }
  }

  func testAppearanceSettingsDefaultToDarkAndRoundTrip() throws {
    let appRoot = try scratchRoot(name: "riela-app-appearance-\(UUID().uuidString)")
    let store = RielaAppAppearanceSettingsStore(appRootURL: appRoot)

    XCTAssertEqual(store.load().colorScheme, .dark)

    try store.save(RielaAppAppearanceSettings(colorScheme: .light))
    XCTAssertEqual(store.load().colorScheme, .light)

    // Unknown persisted values fall back to the dark default instead of failing.
    try Data(#"{"colorScheme":"solarized"}"#.utf8).write(to: store.settingsURL)
    XCTAssertEqual(store.load().colorScheme, .dark)
  }

  func testNoteSettingsStorePersistsExposureAndServiceManagesClients() throws {
    let noteRoot = try scratchRoot(name: "riela-app-note-settings-\(UUID().uuidString)")
      .appendingPathComponent("note", isDirectory: true)
    try FileManager.default.createDirectory(at: noteRoot, withIntermediateDirectories: true)
    let store = RielaAppNoteSettingsStore(noteRoot: noteRoot)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot.path))

    XCTAssertFalse(store.load().exposesNoteAPI)
    try store.save(RielaAppNoteSettings(exposesNoteAPI: true))
    XCTAssertTrue(store.load().exposesNoteAPI)

    let client = try service.registerAPIClient(displayName: "Local test", bearerToken: "secret-token")
    XCTAssertEqual(try service.listAPIClients().map(\.displayName), ["Local test"])

    _ = try service.revokeAPIClient(clientId: client.clientId)
    XCTAssertEqual(try service.listAPIClients(), [])
    XCTAssertEqual(try service.listAPIClients(includeRevoked: true).first?.displayName, "Local test")
  }

  func testRegistrationChallengeFlowRegistersClient() async throws {
    let noteRoot = try scratchRoot(name: "riela-app-note-register-\(UUID().uuidString)")
      .appendingPathComponent("note", isDirectory: true)
    try FileManager.default.createDirectory(at: noteRoot, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot.path))
    let authenticator = QRClientRegistrationAuthenticator(
      service: service,
      registrationScope: noteRoot.standardizedFileURL.path
    )

    let challenge = try await authenticator.createRegistrationChallenge(
      publicBaseURL: "http://192.0.2.10:9876"
    )
    XCTAssertTrue(challenge.registrationURL.contains("/note/register?code=\(challenge.code)"))
    XCTAssertTrue(challenge.registrationURL.hasPrefix("http://192.0.2.10:9876/"))

    let credential = try await authenticator.redeemRegistrationCode(
      code: challenge.code,
      displayName: "Client 1"
    )
    XCTAssertEqual(credential.displayName, "Client 1")
    XCTAssertTrue(credential.bearerToken.hasPrefix("rn_"))
    XCTAssertEqual(credential.bearerToken.count, 46)
    XCTAssertEqual(try service.listAPIClients().map(\.displayName), ["Client 1"])
  }

  func testRegistrationChallengeRedeemsThroughServedNoteAPIRoute() async throws {
    let noteRoot = try scratchRoot(name: "riela-app-note-route-redeem-\(UUID().uuidString)")
      .appendingPathComponent("note", isDirectory: true)
    try FileManager.default.createDirectory(at: noteRoot, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot.path))
    let registrationBaseURL = "http://192.0.2.10:9876"
    let authenticator = QRClientRegistrationAuthenticator(
      service: service,
      registrationScope: noteRoot.standardizedFileURL.path
    )
    let challenge = try await authenticator.createRegistrationChallenge(publicBaseURL: registrationBaseURL)
    let listener = try await InProcessWorkflowServeListenerFactory().startListener(
      for: WorkflowServeResolvedWorkflow(workflowId: "note-api", selectedIdentity: "note-api"),
      request: WorkflowServeStartRequest(
        selection: .scopedName("note-api"),
        server: RielaServerConfiguration(
          host: "192.0.2.10",
          port: 9876,
          noteAPIEnabled: true,
          noteRoot: noteRoot.path
        )
      ),
      generationId: "note-settings-route-redeem"
    )
    let inProcess = try XCTUnwrap(listener as? InProcessWorkflowServeListenerHandle)
    let registrationURL = try XCTUnwrap(URLComponents(string: challenge.registrationURL))
    let code = try XCTUnwrap(registrationURL.queryItems?.first { $0.name == "code" }?.value)

    let registration = await inProcess.routeHandler.route(
      .init(
        method: "POST",
        path: registrationURL.path,
        body: Data(#"{"code":"\#(code)","displayName":"Phone"}"#.utf8)
      ),
      context: .init()
    )

    XCTAssertEqual(registration.status, 200)
    XCTAssertEqual(challenge.registrationURL.hasPrefix(registrationBaseURL), true)
    XCTAssertEqual(try service.listAPIClients().map(\.displayName), ["Phone"])
    try await listener.shutdown()
  }

  func testDaemonServerConfigurationReflectsNoteAPIExposureSetting() throws {
    let root = try scratchRoot(name: "riela-app-note-api-server-config-\(UUID().uuidString)")
    let app = RielaApp()
    app.appHomeDirectory = root
    app.daemonProfileName = .default

    XCTAssertFalse(app.daemonServerConfiguration(profileName: .default).noteAPIEnabled)
    XCTAssertEqual(
      app.daemonServerConfiguration(profileName: .default).noteRoot,
      app.noteRootURL(profileName: .default).path
    )

    let settingsStore = RielaAppNoteSettingsStore(noteRoot: app.noteRootURL(profileName: .default))
    try settingsStore.save(RielaAppNoteSettings(
      exposesNoteAPI: true,
      s3Profiles: [
        RielaAppNoteS3ProfileSettings(
          name: "daemon-s3",
          endpoint: "https://daemon-s3.example.test",
          region: "ap-northeast-1",
          bucket: "notes",
          accessKeyIdEnv: "DAEMON_ACCESS_KEY_ID",
          secretAccessKeyEnv: "DAEMON_SECRET_ACCESS_KEY",
          keyPrefix: "profiles/default"
        )
      ]
    ))

    let configuration = app.daemonServerConfiguration(profileName: .default)
    XCTAssertTrue(configuration.noteAPIEnabled)
    XCTAssertEqual(configuration.noteS3Profiles.map(\.name), ["daemon-s3"])
    XCTAssertEqual(configuration.noteS3Profiles.first?.endpoint, "https://daemon-s3.example.test")
    XCTAssertEqual(configuration.noteS3Profiles.first?.accessKeyIdEnv, "DAEMON_ACCESS_KEY_ID")
    XCTAssertEqual(configuration.noteS3Profiles.first?.secretAccessKeyEnv, "DAEMON_SECRET_ACCESS_KEY")
    XCTAssertEqual(configuration.noteS3Profiles.first?.keyPrefix, "profiles/default")
  }

  func testAppNoteRegistrationBaseURLUsesRunningDaemonEndpoint() async throws {
    let root = try scratchRoot(name: "riela-app-note-api-runtime-endpoint-\(UUID().uuidString)")
    let workflowDirectory = root.appendingPathComponent("workflow", isDirectory: true)
    try writeMinimalWorkflow(id: "note-api-runtime-endpoint", to: workflowDirectory)
    let app = RielaApp()
    app.appHomeDirectory = root
    app.daemonProfileName = .default
    let noteRoot = app.noteRootURL(profileName: .default)
    try RielaAppNoteSettingsStore(noteRoot: noteRoot).save(RielaAppNoteSettings(exposesNoteAPI: true))
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "note-api-runtime-endpoint",
      workflowId: "note-api-runtime-endpoint",
      displayName: "Note API Runtime Endpoint",
      sourceDescription: "test source",
      workflowDirectory: workflowDirectory.path,
      workingDirectory: root.path,
      eventRoot: nil,
      eventSources: []
    )

    await app.daemonRuntime.start(
      candidate,
      configuration: WorkflowServeRuntimeConfiguration(workingDirectory: root.path),
      server: app.daemonServerConfiguration(profileName: .default)
    )

    let baseURL = try XCTUnwrap(app.noteAPIRegistrationBaseURL(profileName: .default))
    XCTAssertTrue(baseURL.hasPrefix("http://127.0.0.1:"))
    XCTAssertFalse(baseURL.hasSuffix(":8787"))
    await app.daemonRuntime.stop(identity: candidate.id)
  }

  private func scratchRoot(name: String) throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func writeMinimalWorkflow(id: String, to workflowDirectory: URL) throws {
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    let workflow = """
    {
      "workflowId": "\(id)",
      "defaults": {
        "nodeTimeoutMs": 1000,
        "maxLoopIterations": 3
      },
      "entryStepId": "first",
      "nodeRegistry": [
        { "id": "first" }
      ],
      "steps": [
        { "id": "first", "nodeId": "first" }
      ],
      "nodes": [
        { "id": "first", "nodeFile": "nodes/first.json" }
      ]
    }
    """
    try workflow.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
  }
}
#endif
