#if os(macOS)
import AppKit
import RielaAppSupport
import RielaNote
@testable import RielaNoteUI
import RielaServer
import SwiftUI
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppNotesIntegrationTests: XCTestCase {
  func testNoteRootUsesHomeScopedProfileDirectory() throws {
    let root = try scratchRoot(name: "riela-app-note-root-\(UUID().uuidString)")
    let app = RielaApp()
    app.appHomeDirectory = root

    let noteRoot = app.noteRootURL(profileName: RielaAppProfileName("work/team"))

    XCTAssertEqual(noteRoot.path, root.appendingPathComponent(".riela/profiles/work-team/note").path)
  }

  func testStatusMenuContainsNotesActions() throws {
    let app = RielaApp()
    app.rebuildMenu()

    let titles = try XCTUnwrap(app.statusItem.menu?.items.map(\.title))

    XCTAssertEqual(titles.first, "Instances...")
    XCTAssertTrue(titles.contains("Notes..."))
    XCTAssertTrue(titles.contains("Note Settings..."))
    XCTAssertEqual(app.statusItem.menu?.items.first { $0.title == "Notes..." }?.target as? RielaApp, app)
  }

  func testNoteWindowHostsRielaNoteRootViewAndCreatesStore() throws {
    let scratch = try scratchRoot(name: "riela-app-note-window-\(UUID().uuidString)")
    let noteRoot = scratch
      .appendingPathComponent("note", isDirectory: true)

    let controller = try NoteWindowController(noteRoot: noteRoot, profileName: .default)
    let contentController = try XCTUnwrap(controller.window?.contentViewController)
    let pngData = try renderPNGData(view: contentController.view)
    let screenshotURL = scratch.appendingPathComponent("note-window-render.png")
    try pngData.write(to: screenshotURL)

    XCTAssertTrue(FileManager.default.fileExists(atPath: noteRoot.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: noteRoot.appendingPathComponent("note-store.sqlite").path))
    XCTAssertTrue(String(describing: type(of: contentController)).contains("RielaNoteRootView"))
    XCTAssertGreaterThan(pngData.count, 1_000)
    controller.close()
  }

  func testRegularSearchPopupRendersActiveTagKanban() async throws {
    let noteRoot = try scratchRoot(
      name: "riela-app-note-kanban-\(UUID().uuidString)"
    )
    let service = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot.path)
    )
    let parent = try service.defineTag(name: "portfolio")
    let child = try service.defineTag(
      name: "project",
      parentTagId: parent.tagId
    )
    let notebook = try service.createNotebook(title: "Current project")
    _ = try service.applyNotebookTags(
      notebookId: notebook.notebookId,
      tags: [child.name],
      provenance: .human
    )
    _ = try service.setNotebookProgress(
      notebookId: notebook.notebookId,
      progress: .progress
    )
    let viewModel = RielaNoteLibraryViewModel(
      client: NoteServiceRielaNoteUIClient(service: service)
    )
    await viewModel.load()
    await viewModel.toggleSearchTag(parent.name)
    let popup = RielaNoteSearchPopupSheet(
      viewModel: viewModel,
      onClose: {}
    )
    XCTAssertEqual(popup.contentMode, .tagKanban)

    let hostingController = NSHostingController(rootView: popup)
    let pngData = try renderPNGData(view: hostingController.view)
    try pngData.write(
      to: noteRoot.appendingPathComponent("tag-kanban-popup-render.png")
    )

    XCTAssertGreaterThan(pngData.count, 1_000)
    XCTAssertEqual(viewModel.notebooks.map(\.notebookId), [notebook.notebookId])
    XCTAssertEqual(viewModel.notebooks.first?.progress, .progress)

    let failureMessage = "Progress update failed."
    viewModel.notebookProgressMutationFailure = viewModel.notebookSnapshotContext.map {
      RielaNoteNotebookMutationFailure(
        context: $0,
        message: failureMessage
      )
    }
    viewModel.state = .failed(failureMessage)
    let failedPopup = RielaNoteSearchPopupSheet(
      viewModel: viewModel,
      onClose: {}
    )
    XCTAssertEqual(
      failedPopup.contentMode,
      .tagKanbanFailed(failureMessage)
    )
    let failedHostingController = NSHostingController(rootView: failedPopup)
    let failedPNGData = try renderPNGData(view: failedHostingController.view)
    try failedPNGData.write(
      to: noteRoot.appendingPathComponent("tag-kanban-popup-failure-render.png")
    )
    XCTAssertGreaterThan(failedPNGData.count, 1_000)
  }

  func testNoteWindowLoadsS3ProfileFromEnvironment() throws {
    let scratch = try scratchRoot(name: "riela-app-note-window-s3-\(UUID().uuidString)")
    let noteRoot = scratch
      .appendingPathComponent("note", isDirectory: true)

    let controller = try NoteWindowController(
      noteRoot: noteRoot,
      profileName: .default,
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

    XCTAssertEqual(controller.s3Profiles.map(\.name), ["app-s3"])
    XCTAssertEqual(controller.s3Profiles.first?.endpoint.absoluteString, "https://s3.example.test")
    XCTAssertEqual(controller.s3Profiles.first?.keyPrefix, "profile/default")
    controller.close()
  }

  func testNoteWindowLoadsNamedS3ProfileFromSettings() throws {
    let scratch = try scratchRoot(name: "riela-app-note-window-settings-s3-\(UUID().uuidString)")
    let noteRoot = scratch
      .appendingPathComponent("note", isDirectory: true)
    let settingsStore = RielaAppNoteSettingsStore(noteRoot: noteRoot)
    try settingsStore.save(RielaAppNoteSettings(
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
    ))

    let controller = try NoteWindowController(
      noteRoot: noteRoot,
      profileName: .default,
      environment: [
        "NOTE_ACCESS_KEY_ID": "access-key",
        "NOTE_SECRET_ACCESS_KEY": "secret-key"
      ]
    )

    XCTAssertEqual(controller.s3Profiles.map(\.name), ["settings-s3"])
    XCTAssertEqual(controller.s3Profiles.first?.endpoint.absoluteString, "https://settings-s3.example.test")
    XCTAssertEqual(controller.s3Profiles.first?.bucket, "notes")
    XCTAssertEqual(controller.s3Profiles.first?.keyPrefix, "profiles/default")
    controller.close()
  }

  func testNoteWindowOpensWhenSavedS3ProfileCredentialsAreMissing() throws {
    let scratch = try scratchRoot(name: "riela-app-note-window-settings-s3-missing-env-\(UUID().uuidString)")
    let noteRoot = scratch
      .appendingPathComponent("note", isDirectory: true)
    let settingsStore = RielaAppNoteSettingsStore(noteRoot: noteRoot)
    try settingsStore.save(RielaAppNoteSettings(
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
    ))

    let controller = try NoteWindowController(
      noteRoot: noteRoot,
      profileName: .default,
      environment: [:]
    )

    XCTAssertEqual(controller.s3Profiles, [])
    controller.close()
  }

  func testNoteWindowRejectsPartialS3ProfileEnvironment() throws {
    let scratch = try scratchRoot(name: "riela-app-note-window-partial-s3-\(UUID().uuidString)")
    let noteRoot = scratch
      .appendingPathComponent("note", isDirectory: true)

    XCTAssertThrowsError(try NoteWindowController(
      noteRoot: noteRoot,
      profileName: .default,
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

  func testNoteSettingsWindowPersistsColorScheme() throws {
    let scratch = try scratchRoot(name: "riela-app-appearance-window-\(UUID().uuidString)")
    let noteRoot = scratch.appendingPathComponent("note", isDirectory: true)
    let appearanceStore = RielaAppAppearanceSettingsStore(
      appRootURL: scratch.appendingPathComponent("app-root", isDirectory: true)
    )
    let controller = try NoteSettingsWindowController(
      noteRoot: noteRoot,
      profileName: .default,
      appearanceStore: appearanceStore
    )

    controller.setColorScheme(.light)
    XCTAssertEqual(appearanceStore.load().colorScheme, .light)

    controller.setColorScheme(.dark)
    XCTAssertEqual(appearanceStore.load().colorScheme, .dark)
    controller.close()
  }

  func testNoteSettingsPersistsExposureAndManagesClients() throws {
    let noteRoot = try scratchRoot(name: "riela-app-note-settings-\(UUID().uuidString)")
      .appendingPathComponent("note", isDirectory: true)
    let controller = try NoteSettingsWindowController(noteRoot: noteRoot, profileName: .default)

    XCTAssertFalse(controller.settingsStore.load().exposesNoteAPI)

    try controller.settingsStore.save(RielaAppNoteSettings(exposesNoteAPI: true))
    XCTAssertTrue(controller.settingsStore.load().exposesNoteAPI)

    let client = try controller.service.registerAPIClient(displayName: "Local test", bearerToken: "secret-token")
    XCTAssertEqual(try controller.service.listAPIClients().map(\.displayName), ["Local test"])

    _ = try controller.service.revokeAPIClient(clientId: client.clientId)
    XCTAssertEqual(try controller.service.listAPIClients(), [])
    XCTAssertEqual(try controller.service.listAPIClients(includeRevoked: true).first?.displayName, "Local test")
    controller.close()
  }

  func testNoteSettingsEditsS3Profile() throws {
    let noteRoot = try scratchRoot(name: "riela-app-note-settings-s3-\(UUID().uuidString)")
      .appendingPathComponent("note", isDirectory: true)
    let controller = try NoteSettingsWindowController(noteRoot: noteRoot, profileName: .default)
    try controller.settingsStore.save(RielaAppNoteSettings(exposesNoteAPI: true))

    controller.setS3ProfileEditor(RielaAppNoteS3ProfileSettings(
      name: "window-s3",
      endpoint: "https://window-s3.example.test",
      region: "ap-northeast-1",
      bucket: "notes",
      accessKeyIdEnv: "WINDOW_ACCESS_KEY_ID",
      secretAccessKeyEnv: "WINDOW_SECRET_ACCESS_KEY",
      sessionTokenEnv: "WINDOW_SESSION_TOKEN",
      keyPrefix: "profiles/default"
    ))
    try controller.saveS3ProfileFromEditor()

    let saved = controller.settingsStore.load()
    XCTAssertTrue(saved.exposesNoteAPI)
    XCTAssertEqual(saved.s3Profiles.map(\.name), ["window-s3"])
    XCTAssertEqual(saved.s3Profiles.first?.endpoint, "https://window-s3.example.test")
    XCTAssertEqual(saved.s3Profiles.first?.secretAccessKeyEnv, "WINDOW_SECRET_ACCESS_KEY")
    XCTAssertEqual(saved.s3Profiles.first?.sessionTokenEnv, "WINDOW_SESSION_TOKEN")
    XCTAssertEqual(saved.s3Profiles.first?.keyPrefix, "profiles/default")
    XCTAssertFalse(String(data: try JSONEncoder().encode(saved), encoding: .utf8)?.contains("secret-key") ?? true)

    try controller.clearS3ProfilesFromSettings()
    XCTAssertTrue(controller.settingsStore.load().exposesNoteAPI)
    XCTAssertEqual(controller.settingsStore.load().s3Profiles, [])
    controller.close()
  }

  func testNoteSettingsWindowRendersS3ProfileEditor() throws {
    let noteRoot = try scratchRoot(name: "riela-app-note-settings-render-\(UUID().uuidString)")
      .appendingPathComponent("note", isDirectory: true)
    let controller = try NoteSettingsWindowController(noteRoot: noteRoot, profileName: .default)
    let contentView = try XCTUnwrap(controller.window?.contentView)
    let pngData = try renderPNGData(view: contentView)

    XCTAssertTrue(containsLabel("S3 Storage Profile", in: contentView))
    XCTAssertTrue(containsLabel("Endpoint", in: contentView))
    XCTAssertGreaterThan(pngData.count, 1_000)
    controller.close()
  }

  func testNoteSettingsRegistersClientThroughChallengeFlow() async throws {
    let noteRoot = try scratchRoot(name: "riela-app-note-settings-register-\(UUID().uuidString)")
      .appendingPathComponent("note", isDirectory: true)
    let controller = try NoteSettingsWindowController(
      noteRoot: noteRoot,
      profileName: .default,
      registrationBaseURL: "http://192.0.2.10:9876"
    )

    let credential = try await controller.registerNextClientUsingChallenge()

    XCTAssertEqual(credential.displayName, "Client 1")
    XCTAssertTrue(credential.bearerToken.hasPrefix("rn_"))
    XCTAssertEqual(credential.bearerToken.count, 46)
    XCTAssertEqual(try controller.service.listAPIClients().map(\.displayName), ["Client 1"])
    controller.close()
  }

  func testNoteSettingsRegistrationRequiresServedEndpoint() async throws {
    let noteRoot = try scratchRoot(name: "riela-app-note-settings-register-unavailable-\(UUID().uuidString)")
      .appendingPathComponent("note", isDirectory: true)
    let controller = try NoteSettingsWindowController(noteRoot: noteRoot, profileName: .default)

    do {
      _ = try await controller.createRegistrationChallengeForSheet()
      XCTFail("Expected registration challenge creation to require an active Note API endpoint.")
    } catch {
      XCTAssertEqual(error as? RielaAppNoteRegistrationError, .endpointUnavailable)
    }
    controller.close()
  }

  func testNoteSettingsBuildsQRRegistrationChallengeSheet() async throws {
    let noteRoot = try scratchRoot(name: "riela-app-note-settings-qr-\(UUID().uuidString)")
      .appendingPathComponent("note", isDirectory: true)
    let controller = try NoteSettingsWindowController(
      noteRoot: noteRoot,
      profileName: .default,
      registrationBaseURL: "http://192.0.2.10:9876"
    )

    let challenge = try await controller.createRegistrationChallengeForSheet()
    let accessoryView = controller.registrationChallengeAccessoryView(challenge)
    let pngData = try renderPNGData(view: accessoryView)
    let imageView = firstDescendantImageView(in: accessoryView)

    XCTAssertTrue(challenge.registrationURL.contains("/note/register?code=\(challenge.code)"))
    XCTAssertTrue(challenge.registrationURL.hasPrefix("http://192.0.2.10:9876/"))
    XCTAssertNotNil(imageView?.image)
    XCTAssertGreaterThan(pngData.count, 1_000)
    controller.close()
  }

  func testNoteSettingsChallengeRedeemsThroughServedNoteAPIRoute() async throws {
    let noteRoot = try scratchRoot(name: "riela-app-note-settings-route-redeem-\(UUID().uuidString)")
      .appendingPathComponent("note", isDirectory: true)
    let registrationBaseURL = "http://192.0.2.10:9876"
    let controller = try NoteSettingsWindowController(
      noteRoot: noteRoot,
      profileName: .default,
      registrationBaseURL: registrationBaseURL
    )
    let challenge = try await controller.createRegistrationChallengeForSheet()
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
    XCTAssertEqual(try controller.service.listAPIClients().map(\.displayName), ["Phone"])
    try await listener.shutdown()
    controller.close()
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

  private func renderPNGData(view: NSView) throws -> Data {
    view.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
    view.layoutSubtreeIfNeeded()
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw NSError(domain: "RielaAppNotesIntegrationTests", code: 1)
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw NSError(domain: "RielaAppNotesIntegrationTests", code: 2)
    }
    return data
  }

  private func firstDescendantImageView(in view: NSView) -> NSImageView? {
    if let imageView = view as? NSImageView {
      return imageView
    }
    for subview in view.subviews {
      if let imageView = firstDescendantImageView(in: subview) {
        return imageView
      }
    }
    return nil
  }

  private func containsLabel(_ value: String, in view: NSView) -> Bool {
    if let label = view as? NSTextField, label.stringValue == value {
      return true
    }
    for subview in view.subviews where containsLabel(value, in: subview) {
      return true
    }
    return false
  }
}
#endif
