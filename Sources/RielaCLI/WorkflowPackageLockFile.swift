import Crypto
import Foundation
import RielaAddons

public struct WorkflowPackageLockFile: Codable, Equatable, Sendable {
  public var lockfileVersion: Int
  public var generatedBy: String
  public var packages: [String: WorkflowPackageLockEntry]

  public init(
    lockfileVersion: Int = 1,
    generatedBy: String = "riela",
    packages: [String: WorkflowPackageLockEntry] = [:]
  ) {
    self.lockfileVersion = lockfileVersion
    self.generatedBy = generatedBy
    self.packages = packages
  }
}

public struct WorkflowPackageLockEntry: Codable, Equatable, Sendable {
  public var name: String
  public var version: String?
  public var kind: WorkflowPackageKind
  public var registry: String?
  public var checksumAlgorithm: String?
  public var checksum: String?
  public var integrity: WorkflowPackageIntegrity?
  public var source: WorkflowPackageLockSource
  public var dependencies: [String]
  public var addons: [WorkflowPackageAddonSummary]

  public init(
    name: String,
    version: String?,
    kind: WorkflowPackageKind,
    registry: String?,
    checksumAlgorithm: String?,
    checksum: String?,
    integrity: WorkflowPackageIntegrity?,
    source: WorkflowPackageLockSource,
    dependencies: [String],
    addons: [WorkflowPackageAddonSummary]
  ) {
    self.name = name
    self.version = version
    self.kind = kind
    self.registry = registry
    self.checksumAlgorithm = checksumAlgorithm
    self.checksum = checksum
    self.integrity = integrity
    self.source = source
    self.dependencies = dependencies
    self.addons = addons
  }
}

public struct WorkflowPackageLockSource: Codable, Equatable, Sendable {
  public var kind: String
  public var reference: String?
  public var archiveDigestAlgorithm: String?
  public var archiveDigest: String?

  public init(
    kind: String,
    reference: String? = nil,
    archiveDigestAlgorithm: String? = nil,
    archiveDigest: String? = nil
  ) {
    self.kind = kind
    self.reference = reference
    self.archiveDigestAlgorithm = archiveDigestAlgorithm
    self.archiveDigest = archiveDigest
  }
}

func workflowPackageLockURL(parsed: ParsedParityOptions, workingDirectory: URL) -> URL {
  switch parsed.scope {
  case .user:
    return URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true)
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("riela-lock.json")
  case .auto, .project, .direct:
    return workingDirectory.appendingPathComponent("riela-lock.json")
  }
}

func writeWorkflowPackageLock(
  entries: [WorkflowPackageLockEntry],
  parsed: ParsedParityOptions,
  workingDirectory: URL
) throws {
  guard !entries.isEmpty else {
    return
  }
  let lockURL = workflowPackageLockURL(parsed: parsed, workingDirectory: workingDirectory)
  var lock = try readWorkflowPackageLock(at: lockURL)
  for entry in entries {
    lock.packages[entry.name] = entry
  }
  lock.packages = Dictionary(uniqueKeysWithValues: lock.packages.sorted { $0.key < $1.key })
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(lock)
  try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: lockURL, options: [.atomic])
}

func removeWorkflowPackageLockEntry(
  packageName: String,
  parsed: ParsedParityOptions,
  workingDirectory: URL
) throws {
  let lockURL = workflowPackageLockURL(parsed: parsed, workingDirectory: workingDirectory)
  guard FileManager.default.fileExists(atPath: lockURL.path) else {
    return
  }
  var lock = try readWorkflowPackageLock(at: lockURL)
  guard lock.packages.removeValue(forKey: packageName) != nil else {
    return
  }
  lock.packages = Dictionary(uniqueKeysWithValues: lock.packages.sorted { $0.key < $1.key })
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(lock)
  try data.write(to: lockURL, options: [.atomic])
}

func readWorkflowPackageLock(at url: URL) throws -> WorkflowPackageLockFile {
  guard FileManager.default.fileExists(atPath: url.path) else {
    return WorkflowPackageLockFile()
  }
  return try JSONDecoder().decode(WorkflowPackageLockFile.self, from: Data(contentsOf: url))
}

func workflowPackageLockEntry(
  manifest: WorkflowPackageManifest,
  sourceReference: String?,
  sourceKind: String,
  archiveURL: URL?
) throws -> WorkflowPackageLockEntry {
  let archiveDigest = try archiveURL.map { try sha256Digest(for: $0) }
  return WorkflowPackageLockEntry(
    name: manifest.name,
    version: manifest.version,
    kind: manifest.kind,
    registry: manifest.registry,
    checksumAlgorithm: manifest.checksumAlgorithm,
    checksum: manifest.checksum,
    integrity: manifest.integrity,
    source: WorkflowPackageLockSource(
      kind: sourceKind,
      reference: sourceReference,
      archiveDigestAlgorithm: archiveDigest == nil ? nil : "sha256",
      archiveDigest: archiveDigest
    ),
    dependencies: manifest.dependencies.map(\.packageId).sorted(),
    addons: manifest.nodeAddons.map { addon in
      WorkflowPackageAddonSummary(
        name: addon.name,
        version: addon.version,
        sourcePath: addon.sourcePath,
        executionKind: addon.execution?.kind,
        contentDigest: addon.contentDigest
      )
    }.sorted { $0.name == $1.name ? $0.version < $1.version : $0.name < $1.name }
  )
}

func sha256Digest(for url: URL) throws -> String {
  let digest = SHA256.hash(data: try Data(contentsOf: url))
  return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
}
