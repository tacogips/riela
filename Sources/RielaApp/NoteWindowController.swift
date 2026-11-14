#if os(macOS)
import AppKit
import RielaAppSupport
import RielaNote
import RielaNoteDispatch
import RielaNoteUI
import SwiftUI

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate {
  let noteRoot: URL
  let profileName: RielaAppProfileName
  let s3Profiles: [S3StorageProfile]
  let service: NoteService
  private let onOpenSettings: () -> Void
  private let onWindowWillClose: () -> Void
  private let maintenanceTicker: NoteAutoActionMaintenanceTicker?

  init(
    noteRoot: URL,
    profileName: RielaAppProfileName,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    autoActionLauncher: (any NoteAutoActionWorkflowLaunching)? = nil,
    onOpenSettings: @escaping () -> Void = {},
    onWindowWillClose: @escaping () -> Void = {}
  ) throws {
    self.noteRoot = noteRoot
    self.profileName = profileName
    let noteSettings = RielaAppNoteSettingsStore(noteRoot: noteRoot).load()
    self.s3Profiles = try RielaAppNoteS3ProfileResolver().profiles(settings: noteSettings, environment: environment)
    self.onOpenSettings = onOpenSettings
    self.onWindowWillClose = onWindowWillClose

    try FileManager.default.createDirectory(at: noteRoot, withIntermediateDirectories: true)
    let service = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot.path),
      autoActionDispatcher: autoActionLauncher.map { NoteAutoActionWorkflowDispatcher(launcher: $0) }
    )
    self.service = service
    self.maintenanceTicker = autoActionLauncher == nil
      ? nil
      : NoteAutoActionMaintenanceTicker(service: service)
    let client = NoteServiceRielaNoteUIClient(
      service: service,
      s3Profiles: s3Profiles,
      linkProposalProvider: RielaWorkflowNoteLinkProposalProvider.defaultProvider(environment: environment),
      editRewriteProvider: RielaWorkflowNoteEditRewriteProvider.defaultProvider(
        environment: environment,
        allowEnvironmentOverrides: true
      ),
      selectionQuestionProvider: RielaWorkflowNoteSelectionQuestionProvider.defaultProvider(
        environment: environment,
        allowEnvironmentOverrides: true
      ),
      defaultTranslationTargetLanguage: noteSettings.normalizedTranslationTargetLanguage
    )
    let hostingController = NSHostingController(
      rootView: RielaNoteRootView(client: client, onOpenSettings: onOpenSettings)
        .environment(\.rielaNoteOpenFile, RielaNoteOpenFileAction { url in
          NSWorkspace.shared.open(url)
        })
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Notes - \(profileName.rawValue)"
    window.minSize = NSSize(width: 760, height: 520)
    window.contentViewController = hostingController
    super.init(window: window)
    window.delegate = self
    window.center()
    if let maintenanceTicker {
      Task { await maintenanceTicker.start() }
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  func windowWillClose(_ notification: Notification) {
    if let maintenanceTicker {
      Task { await maintenanceTicker.stop() }
    }
    onWindowWillClose()
  }
}

struct RielaAppNoteS3ProfileResolver {
  func profiles(
    settings: RielaAppNoteSettings = RielaAppNoteSettings(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> [S3StorageProfile] {
    if !settings.s3Profiles.isEmpty {
      return try settings.s3Profiles.compactMap { profile in
        try resolveProfileIfCredentialsAreAvailable(profile, environment: environment)
      }
    }
    let endpointRaw = environment["RIELA_NOTE_S3_ENDPOINT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let region = environment["RIELA_NOTE_S3_REGION"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let bucket = environment["RIELA_NOTE_S3_BUCKET"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !endpointRaw.isEmpty || !region.isEmpty || !bucket.isEmpty else {
      return []
    }
    guard let endpoint = URL(string: endpointRaw), !region.isEmpty, !bucket.isEmpty else {
      throw RielaAppNoteS3ProfileError.incompleteProfile
    }
    return [
      try S3StorageProfile.environmentBacked(
        name: environment["RIELA_NOTE_S3_PROFILE"] ?? "default-s3",
        endpoint: endpoint,
        region: region,
        bucket: bucket,
        accessKeyIdEnv: environment["RIELA_NOTE_S3_ACCESS_KEY_ID_ENV"] ?? "AWS_ACCESS_KEY_ID",
        secretAccessKeyEnv: environment["RIELA_NOTE_S3_SECRET_ACCESS_KEY_ENV"] ?? "AWS_SECRET_ACCESS_KEY",
        sessionTokenEnv: environment["RIELA_NOTE_S3_SESSION_TOKEN_ENV"],
        keyPrefix: environment["RIELA_NOTE_S3_KEY_PREFIX"] ?? "",
        environment: environment
      )
    ]
  }

  private func resolveProfileIfCredentialsAreAvailable(
    _ profile: RielaAppNoteS3ProfileSettings,
    environment: [String: String]
  ) throws -> S3StorageProfile? {
    do {
      return try resolvedProfile(profile, environment: environment)
    } catch NoteFileStoreError.missingEnvironmentValue {
      return nil
    }
  }

  private func resolvedProfile(
    _ profile: RielaAppNoteS3ProfileSettings,
    environment: [String: String]
  ) throws -> S3StorageProfile {
    let endpointRaw = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    let region = profile.region.trimmingCharacters(in: .whitespacesAndNewlines)
    let bucket = profile.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let endpoint = URL(string: endpointRaw), !region.isEmpty, !bucket.isEmpty else {
      throw RielaAppNoteS3ProfileError.incompleteProfile
    }
    return try S3StorageProfile.environmentBacked(
      name: profile.name.isEmpty ? "default-s3" : profile.name,
      endpoint: endpoint,
      region: region,
      bucket: bucket,
      accessKeyIdEnv: profile.accessKeyIdEnv,
      secretAccessKeyEnv: profile.secretAccessKeyEnv,
      sessionTokenEnv: profile.sessionTokenEnv,
      keyPrefix: profile.keyPrefix,
      environment: environment
    )
  }
}

enum RielaAppNoteS3ProfileError: Error, Equatable {
  case incompleteProfile
}
#endif
