import Foundation

public enum WorkflowPackageArchiveError: Error, LocalizedError, Equatable, Sendable {
  case unsupportedArchive(String)
  case archiveNotFound(String)
  case archiveAlreadyExists(String)
  case archiveToolFailed(String)
  case missingPackageManifest(String)
  case unsafeArchiveEntry(String)

  public var errorDescription: String? {
    switch self {
    case let .unsupportedArchive(path):
      "Unsupported package archive: \(path)"
    case let .archiveNotFound(path):
      "Package archive does not exist: \(path)"
    case let .archiveAlreadyExists(path):
      "Package archive already exists: \(path)"
    case let .archiveToolFailed(message):
      message
    case let .missingPackageManifest(path):
      "Package archive does not contain riela-package.json: \(path)"
    case let .unsafeArchiveEntry(path):
      "Package archive contains an unsafe entry: \(path)"
    }
  }
}

public struct WorkflowPackageArchiveManager: Sendable {
  public static let packageExtension = "rielapkg"
  public static let zipExtension = "zip"
  public static let manifestFileName = "riela-package.json"

  public init() {}

  public static func isPackageArchive(_ url: URL) -> Bool {
    let pathExtension = url.pathExtension.lowercased()
    return pathExtension == packageExtension || pathExtension == zipExtension
  }

  public func createArchive(from packageRoot: URL, to archiveURL: URL, overwrite: Bool = false) throws {
    let packageRoot = packageRoot.standardizedFileURL
    let archiveURL = archiveURL.standardizedFileURL
    guard Self.isPackageArchive(archiveURL) else {
      throw WorkflowPackageArchiveError.unsupportedArchive(archiveURL.path)
    }
    guard FileManager.default.fileExists(
      atPath: packageRoot.appendingPathComponent(Self.manifestFileName).path
    ) else {
      throw WorkflowPackageArchiveError.missingPackageManifest(packageRoot.path)
    }
    try validateExtractedPackageTree(packageRoot)
    if FileManager.default.fileExists(atPath: archiveURL.path) {
      guard overwrite else {
        throw WorkflowPackageArchiveError.archiveAlreadyExists(archiveURL.path)
      }
      try FileManager.default.removeItem(at: archiveURL)
    }
    try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try runArchiveCreate(packageRoot: packageRoot, archiveURL: archiveURL)
  }

  @discardableResult
  public func extractArchive(_ archiveURL: URL, to extractionRoot: URL) throws -> URL {
    let archiveURL = archiveURL.standardizedFileURL
    let extractionRoot = extractionRoot.standardizedFileURL
    guard Self.isPackageArchive(archiveURL) else {
      throw WorkflowPackageArchiveError.unsupportedArchive(archiveURL.path)
    }
    guard FileManager.default.fileExists(atPath: archiveURL.path) else {
      throw WorkflowPackageArchiveError.archiveNotFound(archiveURL.path)
    }
    if FileManager.default.fileExists(atPath: extractionRoot.path) {
      try FileManager.default.removeItem(at: extractionRoot)
    }
    try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
    do {
      try validateArchiveEntries(archiveURL, extractionRoot: extractionRoot)
      try runArchiveExtract(archiveURL: archiveURL, extractionRoot: extractionRoot)
      let packageRoot = try packageRoot(inExtractedDirectory: extractionRoot)
      try validateExtractedPackageTree(packageRoot)
      return packageRoot
    } catch {
      try? FileManager.default.removeItem(at: extractionRoot)
      throw error
    }
  }

  public func packageRoot(inExtractedDirectory extractionRoot: URL) throws -> URL {
    let extractionRoot = extractionRoot.standardizedFileURL
    let directManifest = extractionRoot.appendingPathComponent(Self.manifestFileName)
    if FileManager.default.fileExists(atPath: directManifest.path) {
      return extractionRoot
    }
    let children = try meaningfulChildren(in: extractionRoot)
    guard children.count == 1,
      let packageDirectory = children.first,
      (try? packageDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
      FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent(Self.manifestFileName).path)
    else {
      throw WorkflowPackageArchiveError.missingPackageManifest(extractionRoot.path)
    }
    return packageDirectory.standardizedFileURL
  }

  public func validateExtractedPackageTree(_ packageRoot: URL) throws {
    let packageRoot = packageRoot.standardizedFileURL
    guard FileManager.default.fileExists(
      atPath: packageRoot.appendingPathComponent(Self.manifestFileName).path
    ) else {
      throw WorkflowPackageArchiveError.missingPackageManifest(packageRoot.path)
    }
    guard let enumerator = FileManager.default.enumerator(
      at: packageRoot,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
      options: []
    ) else {
      return
    }
    for case let entry as URL in enumerator {
      let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        throw WorkflowPackageArchiveError.unsafeArchiveEntry(entry.path)
      }
      if values.isRegularFile != true && values.isDirectory != true {
        throw WorkflowPackageArchiveError.unsafeArchiveEntry(entry.path)
      }
    }
  }

  private func meaningfulChildren(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    ).filter { child in
      child.lastPathComponent != "__MACOSX" && child.lastPathComponent != ".DS_Store"
    }
  }

  private func runArchiveCreate(packageRoot: URL, archiveURL: URL) throws {
    #if os(macOS)
    try runArchiveTool(name: "ditto", preferredPaths: ["/usr/bin/ditto"], arguments: [
      "-c",
      "-k",
      "--sequesterRsrc",
      packageRoot.path,
      archiveURL.path
    ])
    #else
    try runArchiveTool(
      name: "zip",
      preferredPaths: ["/usr/bin/zip", "/bin/zip"],
      arguments: ["-qry", archiveURL.path, "."],
      currentDirectory: packageRoot
    )
    #endif
  }

  private func runArchiveExtract(archiveURL: URL, extractionRoot: URL) throws {
    #if os(macOS)
    try runArchiveTool(name: "ditto", preferredPaths: ["/usr/bin/ditto"], arguments: [
      "-x",
      "-k",
      archiveURL.path,
      extractionRoot.path
    ])
    #else
    try runArchiveTool(
      name: "unzip",
      preferredPaths: ["/usr/bin/unzip", "/bin/unzip"],
      arguments: ["-q", archiveURL.path, "-d", extractionRoot.path]
    )
    #endif
  }

  private func validateArchiveEntries(_ archiveURL: URL, extractionRoot: URL) throws {
    let listing = try runArchiveTool(
      name: "zipinfo",
      preferredPaths: ["/usr/bin/zipinfo", "/bin/zipinfo"],
      arguments: ["-1", archiveURL.path]
    )
    let root = extractionRoot.standardizedFileURL
    for entry in listing.split(separator: "\n") {
      let rawPath = String(entry)
      guard let normalized = WorkflowPackageManifestValidator.normalizePackageRelativePath(rawPath) else {
        throw WorkflowPackageArchiveError.unsafeArchiveEntry(rawPath)
      }
      let destination = root.appendingPathComponent(normalized).standardizedFileURL
      guard path(destination.path, isContainedIn: root.path) else {
        throw WorkflowPackageArchiveError.unsafeArchiveEntry(rawPath)
      }
    }
    try validateArchiveEntryTypes(archiveURL)
  }

  private func validateArchiveEntryTypes(_ archiveURL: URL) throws {
    let listing = try runArchiveTool(
      name: "zipinfo",
      preferredPaths: ["/usr/bin/zipinfo", "/bin/zipinfo"],
      arguments: ["-l", archiveURL.path]
    )
    for line in listing.split(separator: "\n").map(String.init) {
      guard let mode = zipInfoMode(in: line) else {
        continue
      }
      guard mode.hasPrefix("-") || mode.hasPrefix("d") else {
        throw WorkflowPackageArchiveError.unsafeArchiveEntry(line)
      }
    }
  }

  @discardableResult
  private func runArchiveTool(
    name: String,
    preferredPaths: [String],
    arguments: [String],
    currentDirectory: URL? = nil
  ) throws -> String {
    let process = Process()
    process.executableURL = try executableURL(named: name, preferredPaths: preferredPaths)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      let detail = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
      throw WorkflowPackageArchiveError.archiveToolFailed(
        detail.isEmpty ? "\(name) failed with exit code \(process.terminationStatus)" : detail
      )
    }
    return stdout
  }

  private func executableURL(named name: String, preferredPaths: [String]) throws -> URL {
    let pathCandidates = preferredPaths + (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":")
      .map { "\(String($0))/\(name)" }
    if let path = pathCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      return URL(fileURLWithPath: path)
    }
    throw WorkflowPackageArchiveError.archiveToolFailed("Required archive tool '\(name)' was not found in PATH")
  }

  private func zipInfoMode(in line: String) -> String? {
    guard line.count >= 10 else {
      return nil
    }
    let mode = String(line.prefix(10))
    let allowedModeCharacters = Set("-dlbcpsrwxStT")
    guard mode.allSatisfy({ allowedModeCharacters.contains($0) }) else {
      return nil
    }
    return mode
  }

  private func path(_ path: String, isContainedIn rootPath: String) -> Bool {
    path == rootPath || path.hasPrefix(rootPath + "/")
  }
}
