#if os(macOS)
import Foundation
import RielaCore
import RielaNote
import RielaServer

struct RielaAppWebNoteS3ProfilePayload: Codable, Equatable {
  var name: String
  var endpoint: String
  var region: String
  var bucket: String
  var accessKeyIdEnv: String?
  var secretAccessKeyEnv: String?
  var sessionTokenEnv: String?
  var keyPrefix: String?
}

enum RielaAppWebNoteS3ProfileValidationError: LocalizedError, Equatable {
  case missingRequiredFields
  case invalidEndpoint
  case missingCredentialEnvironment

  var errorDescription: String? {
    switch self {
    case .missingRequiredFields:
      return "name, endpoint, region, and bucket are required."
    case .invalidEndpoint:
      return "endpoint must be a valid URL."
    case .missingCredentialEnvironment:
      return "access key and secret key environment variable names are required."
    }
  }
}

extension RielaAppWebNoteS3ProfilePayload {
  init(settings: RielaAppNoteS3ProfileSettings) {
    name = settings.name
    endpoint = settings.endpoint
    region = settings.region
    bucket = settings.bucket
    accessKeyIdEnv = settings.accessKeyIdEnv
    secretAccessKeyEnv = settings.secretAccessKeyEnv
    sessionTokenEnv = settings.sessionTokenEnv
    keyPrefix = settings.keyPrefix
  }

  func validatedSettings() throws -> RielaAppNoteS3ProfileSettings {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    let region = region.trimmingCharacters(in: .whitespacesAndNewlines)
    let bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !endpoint.isEmpty, !region.isEmpty, !bucket.isEmpty else {
      throw RielaAppWebNoteS3ProfileValidationError.missingRequiredFields
    }
    guard URL(string: endpoint) != nil else {
      throw RielaAppWebNoteS3ProfileValidationError.invalidEndpoint
    }
    let accessKeyEnv = (accessKeyIdEnv ?? "AWS_ACCESS_KEY_ID")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let secretKeyEnv = (secretAccessKeyEnv ?? "AWS_SECRET_ACCESS_KEY")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !accessKeyEnv.isEmpty, !secretKeyEnv.isEmpty else {
      throw RielaAppWebNoteS3ProfileValidationError.missingCredentialEnvironment
    }
    let sessionEnv = sessionTokenEnv?.trimmingCharacters(in: .whitespacesAndNewlines)
    return RielaAppNoteS3ProfileSettings(
      name: name,
      endpoint: endpoint,
      region: region,
      bucket: bucket,
      accessKeyIdEnv: accessKeyEnv,
      secretAccessKeyEnv: secretKeyEnv,
      sessionTokenEnv: (sessionEnv?.isEmpty ?? true) ? nil : sessionEnv,
      keyPrefix: keyPrefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    )
  }

  var jsonValue: JSONValue {
    .object([
      "name": .string(name),
      "endpoint": .string(endpoint),
      "region": .string(region),
      "bucket": .string(bucket),
      "accessKeyIdEnv": .string(accessKeyIdEnv ?? "AWS_ACCESS_KEY_ID"),
      "secretAccessKeyEnv": .string(secretAccessKeyEnv ?? "AWS_SECRET_ACCESS_KEY"),
      "sessionTokenEnv": sessionTokenEnv.map(JSONValue.string) ?? .null,
      "keyPrefix": .string(keyPrefix ?? "")
    ])
  }
}

extension RielaApp {
  func webNoteService() throws -> NoteService {
    let root = noteRootURL(profileName: daemonProfileName)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: root.path),
      changeObserver: NoteChangeFeedObserver(feed: noteChangeFeed)
    )
  }

  func webNoteSettingsJSON() -> JSONObject {
    let settings = RielaAppNoteSettingsStore(noteRoot: noteRootURL(profileName: daemonProfileName)).load()
    return [
      "profile": .string(daemonProfileName.rawValue),
      "revision": .number(Double(webRevision)),
      "noteRoot": .string(noteRootURL(profileName: daemonProfileName).path),
      "exposesNoteAPI": .bool(settings.exposesNoteAPI),
      "s3ProfileCount": .number(Double(settings.s3Profiles.count)),
      "s3Profiles": .array(settings.s3Profiles.map { profile in
        RielaAppWebNoteS3ProfilePayload(settings: profile).jsonValue
      })
    ]
  }

  func webNoteClientsJSON() -> RielaHTTPResponse {
    do {
      let clients = try webNoteService().listAPIClients(includeRevoked: false)
      return webNoteSettingsResponse([
        "profile": .string(daemonProfileName.rawValue),
        "revision": .number(Double(webRevision)),
        "items": .array(clients.map { client in
          .object([
            "clientId": .string(client.clientId),
            "displayName": .string(client.displayName),
            "createdAt": .string(client.createdAt),
            "lastSeenAt": client.lastSeenAt.map(JSONValue.string) ?? .null
          ])
        })
      ])
    } catch {
      return webNoteSettingsError(
        status: 503,
        code: "note_service_unavailable",
        message: "The active profile's Notes service is unavailable."
      )
    }
  }

  func webRegisterNoteClient(expectedProfile: String?) async -> RielaHTTPResponse {
    if let conflict = webNoteSettingsProfileConflict(expectedProfile: expectedProfile) {
      return conflict
    }
    guard let baseURL = noteAPIRegistrationBaseURL(profileName: daemonProfileName)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !baseURL.isEmpty else {
      return webNoteSettingsError(
        status: 409,
        code: "registration_unavailable",
        message: RielaAppNoteRegistrationError.endpointUnavailable.localizedDescription
      )
    }
    do {
      let service = try webNoteService()
      let root = noteRootURL(profileName: daemonProfileName)
      let authenticator = QRClientRegistrationAuthenticator(
        service: service,
        registrationScope: root.standardizedFileURL.path
      )
      let challenge = try await authenticator.createRegistrationChallenge(publicBaseURL: baseURL)
      return webNoteSettingsResponse([
        "profile": .string(daemonProfileName.rawValue),
        "revision": .number(Double(webRevision)),
        "code": .string(challenge.code),
        "registrationURL": .string(challenge.registrationURL),
        "qrText": .string(challenge.qrText),
        "expiresAt": .string(challenge.expiresAt)
      ])
    } catch {
      return webNoteSettingsError(
        status: 500,
        code: "registration_failed",
        message: error.localizedDescription
      )
    }
  }

  func webRevokeNoteClient(clientId: String, expectedProfile: String?) -> RielaHTTPResponse {
    if let conflict = webNoteSettingsProfileConflict(expectedProfile: expectedProfile) {
      return conflict
    }
    do {
      let client = try webNoteService().revokeAPIClient(clientId: clientId)
      return webNoteSettingsResponse([
        "profile": .string(daemonProfileName.rawValue),
        "revision": .number(Double(webRevision)),
        "clientId": .string(client.clientId),
        "displayName": .string(client.displayName),
        "revoked": .bool(true)
      ])
    } catch {
      return webNoteSettingsError(
        status: 400,
        code: "revoke_failed",
        message: error.localizedDescription
      )
    }
  }

  func webAppearanceSettingsJSON() -> JSONObject {
    [
      "profile": .string(daemonProfileName.rawValue),
      "revision": .number(Double(webRevision)),
      "colorScheme": .string(appearanceSettingsStore.load().colorScheme.rawValue),
      "options": .array(RielaAppColorScheme.allCases.map { .string($0.rawValue) })
    ]
  }

  func webUpdateAppearanceSettings(colorScheme rawValue: String) -> RielaHTTPResponse {
    guard let colorScheme = RielaAppColorScheme(rawValue: rawValue) else {
      return webNoteSettingsError(
        status: 400,
        code: "invalid_settings",
        message: "colorScheme must be one of \(RielaAppColorScheme.allCases.map(\.rawValue).joined(separator: ", "))."
      )
    }
    do {
      try appearanceSettingsStore.save(RielaAppAppearanceSettings(colorScheme: colorScheme))
    } catch {
      return webNoteSettingsError(
        status: 500,
        code: "persistence_failed",
        message: error.localizedDescription
      )
    }
    rielaAppApplyColorScheme(colorScheme)
    webRevision += 1
    return webNoteSettingsResponse(webAppearanceSettingsJSON())
  }

  private func webNoteSettingsProfileConflict(expectedProfile: String?) -> RielaHTTPResponse? {
    guard expectedProfile == daemonProfileName.rawValue else {
      return webNoteSettingsError(
        status: 409,
        code: "profile_conflict",
        message: "The active profile changed after this editor was loaded"
      )
    }
    return nil
  }

  private func webNoteSettingsResponse(_ object: JSONObject, status: Int = 200) -> RielaHTTPResponse {
    .json(status: status, .object(object))
  }

  private func webNoteSettingsError(status: Int, code: String, message: String) -> RielaHTTPResponse {
    webNoteSettingsResponse([
      "error": .object([
        "code": .string(code),
        "message": .string(message)
      ]),
      "revision": .number(Double(webRevision))
    ], status: status)
  }
}
#endif
