#if os(macOS)
import Foundation
import RielaAddons

public enum RielaAppManagedWorkflowInstallError: Error, LocalizedError, Equatable {
  case invalidWorkflowDirectory(String)
  case invalidPackageDirectory(String)
  case invalidPackageManifest(String, issues: [String])
  case unsupportedPackageSource(String)
  case unsafeDestination(String)

  public var errorDescription: String? {
    switch self {
    case let .invalidWorkflowDirectory(path):
      "Selected folder is not a Riela workflow: \(path)"
    case let .invalidPackageDirectory(path):
      "Selected source is not a Riela package: \(path)"
    case let .invalidPackageManifest(path, issues):
      "Selected Riela package is invalid: \(path). \(issues.joined(separator: "; "))"
    case let .unsupportedPackageSource(path):
      "Selected source is not a workflow folder, package folder, .rielapkg, or .zip package: \(path)"
    case let .unsafeDestination(path):
      "Refusing to modify workflow outside the RielaApp profile directory: \(path)"
    }
  }
}

public struct RielaAppManagedInstallResult: Equatable, Sendable {
  public var installedURL: URL
  public var replacedExisting: Bool

  public init(installedURL: URL, replacedExisting: Bool) {
    self.installedURL = installedURL
    self.replacedExisting = replacedExisting
  }
}

public struct RielaAppManagedWorkflowInstaller: Sendable {
  private struct MinimalWorkflow: Decodable {
    var workflowId: String
  }

  public var workflowRoot: URL

  public init(workflowRoot: URL) {
    self.workflowRoot = workflowRoot.standardizedFileURL
  }

  public func installWorkflowDirectory(_ source: URL) throws -> URL {
    try installWorkflowDirectoryResult(source).installedURL
  }

  public func installWorkflowDirectoryResult(_ source: URL) throws -> RielaAppManagedInstallResult {
    let source = source.standardizedFileURL
    let workflow = try decodeWorkflow(at: source)
    let destination = workflowRoot
      .appendingPathComponent(Self.sanitizedDirectoryName(workflow.workflowId), isDirectory: true)
      .standardizedFileURL
    guard containsInstalledWorkflowDirectory(destination) else {
      throw RielaAppManagedWorkflowInstallError.unsafeDestination(destination.path)
    }
    try validateSourceDestinationContainment(source: source, destination: destination)
    try FileManager.default.createDirectory(at: workflowRoot, withIntermediateDirectories: true)
    if source.path == destination.path {
      return RielaAppManagedInstallResult(installedURL: destination, replacedExisting: false)
    }
    let replacedExisting = FileManager.default.fileExists(atPath: destination.path)
    if replacedExisting {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
    return RielaAppManagedInstallResult(installedURL: destination, replacedExisting: replacedExisting)
  }

  public func removeInstalledWorkflowDirectory(_ workflowDirectory: URL) throws {
    let workflowDirectory = workflowDirectory.standardizedFileURL
    guard containsInstalledWorkflowDirectory(workflowDirectory) else {
      throw RielaAppManagedWorkflowInstallError.unsafeDestination(workflowDirectory.path)
    }
    if FileManager.default.fileExists(atPath: workflowDirectory.path) {
      try FileManager.default.removeItem(at: workflowDirectory)
    }
  }

  public func containsInstalledWorkflowDirectory(_ workflowDirectory: URL) -> Bool {
    let path = workflowDirectory.standardizedFileURL.path
    let rootPath = workflowRoot.standardizedFileURL.path
    return path != rootPath && RielaAppDaemonWorkflowState.path(path, isContainedIn: rootPath)
  }

  private func decodeWorkflow(at directory: URL) throws -> MinimalWorkflow {
    let workflowURL = directory.appendingPathComponent("workflow.json")
    guard
      let data = try? Data(contentsOf: workflowURL),
      let workflow = try? JSONDecoder().decode(MinimalWorkflow.self, from: data)
    else {
      throw RielaAppManagedWorkflowInstallError.invalidWorkflowDirectory(directory.path)
    }
    return workflow
  }

  static func sanitizedDirectoryName(_ rawValue: String) -> String {
    let mapped = rawValue.map { character in
      character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        ? character
        : "-"
    }
    let sanitized = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    return sanitized.isEmpty ? "workflow" : sanitized
  }
}

public struct RielaAppManagedPackageInstaller: Sendable {
  public static let supportedPackageArchiveExtensions = [
    WorkflowPackageArchiveManager.packageExtension,
    WorkflowPackageArchiveManager.zipExtension
  ]

  public var packageRoot: URL

  public init(packageRoot: URL) {
    self.packageRoot = packageRoot.standardizedFileURL
  }

  public func installPackageSource(_ source: URL) throws -> URL {
    try installPackageSourceResult(source).installedURL
  }

  public func installPackageSourceResult(_ source: URL) throws -> RielaAppManagedInstallResult {
    let source = source.standardizedFileURL
    let materialized = try materializedPackageSource(source)
    defer {
      if let temporaryRoot = materialized.temporaryRoot {
        try? FileManager.default.removeItem(at: temporaryRoot)
      }
    }
    let manifest = try validatedPackageManifest(at: materialized.packageRoot)
    let destination = packageRoot
      .appendingPathComponent(RielaAppManagedWorkflowInstaller.sanitizedDirectoryName(manifest.name), isDirectory: true)
      .standardizedFileURL
    guard containsInstalledPackageDirectory(destination) else {
      throw RielaAppManagedWorkflowInstallError.unsafeDestination(destination.path)
    }
    try validateSourceDestinationContainment(source: materialized.packageRoot, destination: destination)
    try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
    if materialized.packageRoot.path == destination.path {
      return RielaAppManagedInstallResult(installedURL: destination, replacedExisting: false)
    }
    let replacedExisting = FileManager.default.fileExists(atPath: destination.path)
    if replacedExisting {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: materialized.packageRoot, to: destination)
    return RielaAppManagedInstallResult(installedURL: destination, replacedExisting: replacedExisting)
  }

  public func removeInstalledPackageDirectory(_ packageDirectory: URL) throws {
    let packageDirectory = packageDirectory.standardizedFileURL
    guard containsInstalledPackageDirectory(packageDirectory) else {
      throw RielaAppManagedWorkflowInstallError.unsafeDestination(packageDirectory.path)
    }
    if FileManager.default.fileExists(atPath: packageDirectory.path) {
      try FileManager.default.removeItem(at: packageDirectory)
    }
  }

  public func containsInstalledPackageDirectory(_ packageDirectory: URL) -> Bool {
    let path = packageDirectory.standardizedFileURL.path
    let rootPath = packageRoot.standardizedFileURL.path
    return path != rootPath && RielaAppDaemonWorkflowState.path(path, isContainedIn: rootPath)
  }

  private func materializedPackageSource(_ source: URL) throws -> (packageRoot: URL, temporaryRoot: URL?) {
    if WorkflowPackageArchiveManager.isPackageArchive(source) {
      let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("RielaApp/rielapkg", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let packageDirectory = try WorkflowPackageArchiveManager().extractArchive(source, to: temporaryRoot)
      return (packageDirectory, temporaryRoot)
    }
    guard FileManager.default.fileExists(
      atPath: source.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName).path
    ) else {
      throw RielaAppManagedWorkflowInstallError.unsupportedPackageSource(source.path)
    }
    try WorkflowPackageArchiveManager().validateExtractedPackageTree(source)
    return (source, nil)
  }

  private func validatedPackageManifest(at packageDirectory: URL) throws -> WorkflowPackageManifest {
    let manifestURL = packageDirectory.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName)
    let manifest: WorkflowPackageManifest
    do {
      let data = try Data(contentsOf: manifestURL)
      manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: data)
    } catch {
      throw RielaAppManagedWorkflowInstallError.invalidPackageDirectory(packageDirectory.path)
    }
    let issues = WorkflowPackageManifestValidator.validatePackageSource(
      manifest,
      packageRoot: packageDirectory,
      verifiesChecksum: true
    )
    guard issues.isEmpty else {
      throw RielaAppManagedWorkflowInstallError.invalidPackageManifest(
        packageDirectory.path,
        issues: issues.map { "\($0.path): \($0.message)" }
      )
    }
    return manifest
  }
}

public enum RielaAppImportSourceKind: Equatable, Sendable {
  case workflowDirectory
  case packageSource
  case unsupported
}

public enum RielaAppImportSourceClassifier {
  public static func kind(for source: URL) -> RielaAppImportSourceKind {
    let source = source.standardizedFileURL
    if isPackageSource(source) {
      return .packageSource
    }
    if isDirectory(source), FileManager.default.fileExists(atPath: source.appendingPathComponent("workflow.json").path) {
      return .workflowDirectory
    }
    return .unsupported
  }

  private static func isPackageSource(_ source: URL) -> Bool {
    if isDirectory(source) {
      return FileManager.default.fileExists(
        atPath: source.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName).path
      )
    }
    return RielaAppManagedPackageInstaller.supportedPackageArchiveExtensions.contains(source.pathExtension.lowercased())
  }

  private static func isDirectory(_ source: URL) -> Bool {
    (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}

private func validateSourceDestinationContainment(source: URL, destination: URL) throws {
  let source = source.standardizedFileURL
  let destination = destination.standardizedFileURL
  let sourceIsNestedInDestination = RielaAppDaemonWorkflowState.path(source.path, isContainedIn: destination.path)
  guard source.path == destination.path || !sourceIsNestedInDestination else {
    throw RielaAppManagedWorkflowInstallError.unsafeDestination(source.path)
  }
  let destinationIsNestedInSource = RielaAppDaemonWorkflowState.path(destination.path, isContainedIn: source.path)
  guard source.path == destination.path || !destinationIsNestedInSource else {
    throw RielaAppManagedWorkflowInstallError.unsafeDestination(destination.path)
  }
}
#endif
