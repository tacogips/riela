import ArgumentParser
import Foundation
import RielaCore
import RielaGraphQL
import RielaNote

private enum NoteReadOnlyFlag: String, EnumerableFlag {
  case readOnly
  case on
  case off
}

struct NoteCommandOptions: ParsableArguments {
  @Option var noteRoot = defaultNoteRoot()
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory = FileManager.default.currentDirectoryPath
  @Option(name: [.customLong("body"), .customLong("body-markdown")]) var body: String?
  @Option var bodyFile: String?
  @Option(name: [.customLong("tag"), .customLong("add")]) var tags: [String] = []
  @Option(name: .customLong("remove")) var removeTags: [String] = []
  @Option(name: [.customLong("class"), .customLong("class-id")]) var tagClassId: String?
  @Option(name: .customLong("class-filter")) var classFilter: [String] = []
  @Option(name: [.customLong("notebook"), .customLong("notebook-id")]) var notebookId: String?
  @Option var notebookTitle: String?
  @Option var query: String?
  var readOnly = false
  var readOnlyValueCount = 0
  @Flag private var readOnlyFlags: [NoteReadOnlyFlag] = []
  @Option(name: .customLong("value")) private var readOnlyRawValues: [String] = []
  @Option var provenance = "human"
  @Option var assignedBy: String?
  @Option var author: String?
  @Option(name: .customLong("file")) var filePath: String?
  @Option var mediaType: String?
  @Option(name: [.customLong("filename"), .customLong("file-name")]) var filename: String?
  @Option var role = NoteFileRole.related.rawValue
  @Option var position = 0
  @Option var limit = 50
  @Option var offset = 0
  @Option var title: String?
  @Option(name: [.customLong("kind-tag"), .customLong("kind-tag-name")]) var kindTagName: String?
  @Option(name: [.customLong("profile"), .customLong("s3-profile"), .customLong("s3-profile-name")])
  var s3ProfileName = "default-s3"
  @Option var s3Endpoint: String?
  @Option var s3Region: String?
  @Option var s3Bucket: String?
  @Option var s3AccessKeyIdEnv = "AWS_ACCESS_KEY_ID"
  @Option var s3SecretAccessKeyEnv = "AWS_SECRET_ACCESS_KEY"
  @Option var s3SessionTokenEnv: String?
  @Option var s3KeyPrefix = ""
  @Option var displayName: String?
  @Flag var includeRevoked = false
  @Flag(name: .customLong("all")) var migrateAll = false
  @Option var graceHours: Int?
  @Flag(name: .customLong("direct")) var directRegistration = false
  @Flag(name: .customLong("append")) var appendBody = false
  var firstPositional: String?
  @Argument private var positionalArguments: [String] = []
  @Option(name: .customLong("to")) private var storageDestination: String?
  @Option private var output: String?

  init() {}

  init(_ options: CLICommandOptions) throws {
    do {
      self = try Self.parse(options.arguments)
    } catch {
      throw CLIUsageError(Self.message(for: error))
    }
    try applyCompatibility()
  }

  private mutating func applyCompatibility() throws {
    noteRoot = (noteRoot as NSString).expandingTildeInPath
    guard positionalArguments.count <= 2 else {
      throw CLIUsageError("unexpected positional argument '\(positionalArguments[2])'")
    }
    firstPositional = positionalArguments.first
    if positionalArguments.count == 2 {
      guard title == nil else {
        throw CLIUsageError("unexpected positional argument '\(positionalArguments[1])'")
      }
      title = positionalArguments[1]
    }
    if position < 0 {
      throw CLIUsageError("--position must be a non-negative integer")
    }
    if limit <= 0 {
      throw CLIUsageError("--limit requires a positive integer")
    }
    if offset < 0 {
      throw CLIUsageError("--offset must be a non-negative integer")
    }
    if let graceHours, graceHours < 0 {
      throw CLIUsageError("--grace-hours must be a non-negative integer")
    }
    if let storageDestination, storageDestination != "s3" {
      throw CLIUsageError("note storage migrate only supports --to s3")
    }
    try applyReadOnlyCompatibility()
  }

  private mutating func applyReadOnlyCompatibility() throws {
    readOnlyValueCount = readOnlyFlags.count + readOnlyRawValues.count
    if let flag = readOnlyFlags.first, readOnlyValueCount == 1 {
      readOnly = flag != .off
    } else if let rawValue = readOnlyRawValues.first, readOnlyValueCount == 1 {
      readOnly = try boolOption("--value", rawValue)
    }
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

  func reclaimInput() -> GraphQLReclaimNoteFileStorageInput {
    // S3 profile fields are optional: they are only needed to delete orphaned S3
    // objects. A local-only GC omits them.
    let includeS3 = s3Endpoint != nil && s3Region != nil && s3Bucket != nil
    return GraphQLReclaimNoteFileStorageInput(
      graceHours: graceHours,
      s3ProfileName: includeS3 ? s3ProfileName : nil,
      s3Endpoint: includeS3 ? s3Endpoint : nil,
      s3Region: includeS3 ? s3Region : nil,
      s3Bucket: includeS3 ? s3Bucket : nil,
      s3AccessKeyIdEnv: includeS3 ? s3AccessKeyIdEnv : nil,
      s3SecretAccessKeyEnv: includeS3 ? s3SecretAccessKeyEnv : nil,
      s3SessionTokenEnv: includeS3 ? s3SessionTokenEnv : nil,
      s3KeyPrefix: includeS3 ? s3KeyPrefix : nil
    )
  }

  var rawS3EnvironmentAllowlist: Set<String> {
    Set([s3AccessKeyIdEnv, s3SecretAccessKeyEnv] + [s3SessionTokenEnv].compactMap { $0 })
  }
}

private func defaultNoteRoot() -> String {
  let configured = CLIRuntimeEnvironment.mergedProcessEnvironment()["RIELA_NOTE_ROOT"]
    .flatMap { $0.isEmpty ? nil : $0 }
  return configured ?? "\(NSHomeDirectory())/.riela/note"
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
