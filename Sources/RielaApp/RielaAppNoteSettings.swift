#if os(macOS)
import Foundation
import RielaNote

struct RielaAppNoteSettings: Codable, Equatable, Sendable {
  var exposesNoteAPI: Bool
  var s3Profiles: [RielaAppNoteS3ProfileSettings]

  init(
    exposesNoteAPI: Bool = false,
    s3Profiles: [RielaAppNoteS3ProfileSettings] = []
  ) {
    self.exposesNoteAPI = exposesNoteAPI
    self.s3Profiles = s3Profiles
  }
}

struct RielaAppNoteS3ProfileSettings: Codable, Equatable, Sendable {
  var name: String
  var endpoint: String
  var region: String
  var bucket: String
  var accessKeyIdEnv: String
  var secretAccessKeyEnv: String
  var sessionTokenEnv: String?
  var keyPrefix: String

  init(
    name: String,
    endpoint: String,
    region: String,
    bucket: String,
    accessKeyIdEnv: String = "AWS_ACCESS_KEY_ID",
    secretAccessKeyEnv: String = "AWS_SECRET_ACCESS_KEY",
    sessionTokenEnv: String? = nil,
    keyPrefix: String = ""
  ) {
    self.name = name
    self.endpoint = endpoint
    self.region = region
    self.bucket = bucket
    self.accessKeyIdEnv = accessKeyIdEnv
    self.secretAccessKeyEnv = secretAccessKeyEnv
    self.sessionTokenEnv = sessionTokenEnv
    self.keyPrefix = keyPrefix
  }
}

enum RielaAppNoteRegistrationError: LocalizedError, Equatable {
  case endpointUnavailable

  var errorDescription: String? {
    switch self {
    case .endpointUnavailable:
      return "Note API registration is unavailable because this profile is not currently being served."
    }
  }
}

struct RielaAppNoteSettingsStore: Sendable {
  var settingsURL: URL

  init(noteRoot: URL) {
    settingsURL = noteRoot.appendingPathComponent("app-settings.json")
  }

  func load() -> RielaAppNoteSettings {
    guard let data = try? Data(contentsOf: settingsURL),
          let settings = try? JSONDecoder().decode(RielaAppNoteSettings.self, from: data) else {
      return RielaAppNoteSettings()
    }
    return settings
  }

  func save(_ settings: RielaAppNoteSettings) throws {
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(settings).write(to: settingsURL, options: .atomic)
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
