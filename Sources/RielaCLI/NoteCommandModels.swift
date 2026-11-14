import Foundation
import RielaCore
import RielaGraphQL
import RielaNote

struct NoteCommandOptions {
  var noteRoot: String
  var workingDirectory: String
  var body: String?
  var bodyFile: String?
  var tags: [String] = []
  var removeTags: [String] = []
  var tagClassId: String?
  var classFilter: [String] = []
  var notebookId: String?
  var notebookTitle: String?
  var query: String?
  var readOnly = false
  var readOnlyValueCount = 0
  var provenance = "human"
  var assignedBy: String?
  var author: String?
  var filePath: String?
  var mediaType: String?
  var filename: String?
  var role = NoteFileRole.related.rawValue
  var position = 0
  var limit = 50
  var offset = 0
  var title: String?
  var kindTagName: String?
  var s3ProfileName = "default-s3"
  var s3Endpoint: String?
  var s3Region: String?
  var s3Bucket: String?
  var s3AccessKeyIdEnv = "AWS_ACCESS_KEY_ID"
  var s3SecretAccessKeyEnv = "AWS_SECRET_ACCESS_KEY"
  var s3SessionTokenEnv: String?
  var s3KeyPrefix = ""
  var displayName: String?
  var includeRevoked = false
  var migrateAll = false
  var directRegistration = false
  var appendBody = false
  var firstPositional: String?

  init(_ options: CLICommandOptions) throws {
    workingDirectory = FileManager.default.currentDirectoryPath
    noteRoot = CLIRuntimeEnvironment.mergedProcessEnvironment()["RIELA_NOTE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
      ?? "\(NSHomeDirectory())/.riela/note"
    noteRoot = (noteRoot as NSString).expandingTildeInPath
    try parse(options.arguments)
  }

  mutating func parse(_ tokens: [String]) throws {
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      if !token.hasPrefix("--") {
        try appendPositional(token)
        index += 1
        continue
      }
      if try handleInlineOption(token) {
        index += 1
        continue
      }
      try handleOption(token, tokens: tokens, index: &index)
      index += 1
    }
  }

  private mutating func appendPositional(_ token: String) throws {
    if firstPositional == nil {
      firstPositional = token
    } else if title == nil {
      title = token
    } else {
      throw CLIUsageError("unexpected positional argument '\(token)'")
    }
  }

  private mutating func handleInlineOption(_ token: String) throws -> Bool {
    if let value = inlineOptionValue(token, prefix: "--note-root=") {
      noteRoot = (value as NSString).expandingTildeInPath
      return true
    }
    if let value = inlineOptionValue(token, prefix: "--output=") {
      _ = value
      return true
    }
    return false
  }

  private mutating func handleOption(_ token: String, tokens: [String], index: inout Int) throws {
    if try handleS3Option(token, tokens: tokens, index: &index) {
      return
    }
    if try handleContentOption(token, tokens: tokens, index: &index) {
      return
    }
    if try handleNoteMetadataOption(token, tokens: tokens, index: &index) {
      return
    }
    if try handleAttachmentOption(token, tokens: tokens, index: &index) {
      return
    }
    if try handleControlOption(token, tokens: tokens, index: &index) {
      return
    }
    throw CLIUsageError("unsupported note option '\(token)'")
  }

  private mutating func handleContentOption(_ token: String, tokens: [String], index: inout Int) throws -> Bool {
    switch token {
    case "--note-root":
      noteRoot = (try noteOptionValue(token, tokens: tokens, index: &index) as NSString).expandingTildeInPath
    case "--working-dir", "--working-directory":
      workingDirectory = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--body", "--body-markdown":
      body = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--body-file":
      bodyFile = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--query":
      query = try noteOptionValue(token, tokens: tokens, index: &index)
    default:
      return false
    }
    return true
  }

  private mutating func handleNoteMetadataOption(_ token: String, tokens: [String], index: inout Int) throws -> Bool {
    switch token {
    case "--tag", "--add":
      tags.append(try noteOptionValue(token, tokens: tokens, index: &index))
    case "--remove":
      removeTags.append(try noteOptionValue(token, tokens: tokens, index: &index))
    case "--class", "--class-id":
      tagClassId = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--class-filter":
      classFilter.append(try noteOptionValue(token, tokens: tokens, index: &index))
    case "--notebook", "--notebook-id":
      notebookId = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--notebook-title":
      notebookTitle = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--read-only":
      readOnly = true
      readOnlyValueCount += 1
    case "--on":
      readOnly = true
      readOnlyValueCount += 1
    case "--off":
      readOnly = false
      readOnlyValueCount += 1
    case "--value":
      readOnly = try boolOption(token, noteOptionValue(token, tokens: tokens, index: &index))
      readOnlyValueCount += 1
    case "--provenance":
      provenance = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--assigned-by":
      assignedBy = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--author":
      author = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--title":
      title = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--kind-tag", "--kind-tag-name":
      kindTagName = try noteOptionValue(token, tokens: tokens, index: &index)
    default:
      return false
    }
    return true
  }

  private mutating func handleAttachmentOption(_ token: String, tokens: [String], index: inout Int) throws -> Bool {
    switch token {
    case "--file":
      filePath = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--media-type":
      mediaType = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--filename", "--file-name":
      filename = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--role":
      role = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--position":
      position = try nonNegativeInt(token, noteOptionValue(token, tokens: tokens, index: &index))
    default:
      return false
    }
    return true
  }

  private mutating func handleControlOption(_ token: String, tokens: [String], index: inout Int) throws -> Bool {
    switch token {
    case "--limit":
      limit = try positiveInt(token, noteOptionValue(token, tokens: tokens, index: &index))
    case "--offset":
      offset = try nonNegativeInt(token, noteOptionValue(token, tokens: tokens, index: &index))
    case "--display-name":
      displayName = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--include-revoked":
      includeRevoked = true
    case "--direct":
      directRegistration = true
    case "--append":
      appendBody = true
    case "--all":
      migrateAll = true
    case "--to":
      let target = try noteOptionValue(token, tokens: tokens, index: &index)
      guard target == "s3" else {
        throw CLIUsageError("note storage migrate only supports --to s3")
      }
    case "--output":
      _ = try noteOptionValue(token, tokens: tokens, index: &index)
    default:
      return false
    }
    return true
  }

  private mutating func handleS3Option(_ token: String, tokens: [String], index: inout Int) throws -> Bool {
    switch token {
    case "--profile", "--s3-profile", "--s3-profile-name":
      s3ProfileName = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--s3-endpoint":
      s3Endpoint = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--s3-region":
      s3Region = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--s3-bucket":
      s3Bucket = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--s3-access-key-id-env":
      s3AccessKeyIdEnv = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--s3-secret-access-key-env":
      s3SecretAccessKeyEnv = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--s3-session-token-env":
      s3SessionTokenEnv = try noteOptionValue(token, tokens: tokens, index: &index)
    case "--s3-key-prefix":
      s3KeyPrefix = try noteOptionValue(token, tokens: tokens, index: &index)
    default:
      return false
    }
    return true
  }

  private func noteOptionValue(_ token: String, tokens: [String], index: inout Int) throws -> String {
    try readOptionValue(token, tokens: tokens, index: &index)
  }

  func requiredBody(command: String) throws -> String {
    if let body {
      if body == "-" {
        return try readStandardInputBody(command: command)
      }
      return body
    }
    if let bodyFile {
      if bodyFile == "-" {
        return try readStandardInputBody(command: command)
      }
      let url = absoluteURL(bodyFile, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
      guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
        throw CLIUsageError("\(command) body file is not UTF-8: \(bodyFile)")
      }
      return text
    }
    throw CLIUsageError("\(command) requires --body or --body-file")
  }

  private func readStandardInputBody(command: String) throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
      throw CLIUsageError("\(command) standard input is not UTF-8")
    }
    return text
  }

  func s3StorageProfile() throws -> S3StorageProfile {
    guard let endpointRaw = s3Endpoint, let endpoint = URL(string: endpointRaw) else {
      throw CLIUsageError("note storage migrate requires --s3-endpoint")
    }
    guard let region = s3Region, !region.isEmpty else {
      throw CLIUsageError("note storage migrate requires --s3-region")
    }
    guard let bucket = s3Bucket, !bucket.isEmpty else {
      throw CLIUsageError("note storage migrate requires --s3-bucket")
    }
    return try S3StorageProfile.environmentBacked(
      name: s3ProfileName,
      endpoint: endpoint,
      region: region,
      bucket: bucket,
      accessKeyIdEnv: s3AccessKeyIdEnv,
      secretAccessKeyEnv: s3SecretAccessKeyEnv,
      sessionTokenEnv: s3SessionTokenEnv,
      keyPrefix: s3KeyPrefix,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    )
  }

  func noteListVariables() -> JSONObject {
    [
      "limit": .integer(Int64(limit)),
      "offset": .integer(Int64(offset)),
      "tagFilter": .array(tags.map { .string($0) }),
      "notebookId": notebookId.map(JSONValue.string) ?? .null
    ]
  }

  func migrateFileInput(fileId: String) throws -> GraphQLMigrateNoteFileStorageInput {
    guard let s3Endpoint, let s3Region, let s3Bucket else {
      throw CLIUsageError("note storage migrate requires --s3-endpoint, --s3-region, and --s3-bucket")
    }
    return GraphQLMigrateNoteFileStorageInput(
      fileId: fileId,
      s3ProfileName: s3ProfileName,
      s3Endpoint: s3Endpoint,
      s3Region: s3Region,
      s3Bucket: s3Bucket,
      s3AccessKeyIdEnv: s3AccessKeyIdEnv,
      s3SecretAccessKeyEnv: s3SecretAccessKeyEnv,
      s3SessionTokenEnv: s3SessionTokenEnv,
      s3KeyPrefix: s3KeyPrefix
    )
  }

  func migrateAllInput() throws -> GraphQLMigrateAllNoteFilesInput {
    guard let s3Endpoint, let s3Region, let s3Bucket else {
      throw CLIUsageError("note storage migrate requires --s3-endpoint, --s3-region, and --s3-bucket")
    }
    return GraphQLMigrateAllNoteFilesInput(
      s3ProfileName: s3ProfileName,
      s3Endpoint: s3Endpoint,
      s3Region: s3Region,
      s3Bucket: s3Bucket,
      s3AccessKeyIdEnv: s3AccessKeyIdEnv,
      s3SecretAccessKeyEnv: s3SecretAccessKeyEnv,
      s3SessionTokenEnv: s3SessionTokenEnv,
      s3KeyPrefix: s3KeyPrefix
    )
  }

  var rawS3EnvironmentAllowlist: Set<String> {
    Set([s3AccessKeyIdEnv, s3SecretAccessKeyEnv] + [s3SessionTokenEnv].compactMap { $0 })
  }
}

func appendedNoteBody(existing: String, addition: String) -> String {
  if existing.isEmpty || existing.hasSuffix("\n") {
    return existing + addition
  }
  return existing + "\n" + addition
}

struct NoteClientRegistrationOutput: Codable, Equatable, Sendable {
  var client: NoteAPIClient
  var bearerToken: String
  var registrationMode: NoteClientRegistrationMode
}

enum NoteClientRegistrationMode: String, Codable, Equatable, Sendable {
  case challenge
  case direct
}

func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
