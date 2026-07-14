#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

public struct WorkflowOwnedFile: Equatable, Sendable {
  public var metadata: WorkflowBundleSnapshotFile
  public var url: URL
  public var bytes: Data
  public var readRoot: URL

  public init(metadata: WorkflowBundleSnapshotFile, url: URL, bytes: Data = Data(), readRoot: URL? = nil) {
    self.metadata = metadata
    self.url = url
    self.bytes = bytes
    self.readRoot = readRoot ?? url.deletingLastPathComponent()
  }
}

public struct WorkflowBundleInventory: Equatable, Sendable {
  public var target: WorkflowBundleIdentity
  public var files: [WorkflowOwnedFile]
  public var unownedFiles: [WorkflowOwnedFile]
  public var bundleDigest: String

  public init(
    target: WorkflowBundleIdentity,
    files: [WorkflowOwnedFile],
    unownedFiles: [WorkflowOwnedFile] = [],
    bundleDigest: String
  ) {
    self.target = target
    self.files = files
    self.unownedFiles = unownedFiles
    self.bundleDigest = bundleDigest
  }
}

public enum WorkflowHistoryIdentityResolver {
  public static func identity(for bundle: ResolvedWorkflowBundle) throws -> WorkflowBundleIdentity {
    let workflowDirectory = canonicalDirectory(URL(fileURLWithPath: bundle.workflowDirectory, isDirectory: true))
    let packageDirectory = bundle.packageDirectory.map { canonicalDirectory(URL(fileURLWithPath: $0, isDirectory: true)) }
    let ownershipRoot = packageDirectory ?? workflowDirectory
    let sourceScope: WorkflowHistorySourceScope = switch bundle.sourceScope {
    case .project: .project
    case .user: .user
    case .direct, .auto: .direct
    }
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(bundle.workflow.workflowId)
    return WorkflowBundleIdentity(
      workflowId: bundle.workflow.workflowId,
      sourceScope: sourceScope,
      sourceKind: packageDirectory == nil ? .authoredWorkflow : .installedPackage,
      workflowDirectory: workflowDirectory.path,
      ownershipRoot: ownershipRoot.path,
      packageDirectory: packageDirectory?.path,
      packageName: bundle.packageManifest?.name,
      packageVersion: bundle.packageManifest?.version,
      workflowContractVersion: try authoredContractVersion(at: workflowDirectory),
      sourceMutable: packageDirectory == nil
    )
  }

  public static func inventory(
    for target: WorkflowBundleIdentity,
    rootOverride: URL? = nil,
    beforeFileOpen: @Sendable (String) throws -> Void = { _ in }
  ) throws -> WorkflowBundleInventory {
    let root = rootOverride?.standardizedFileURL ?? URL(fileURLWithPath: target.ownershipRoot, isDirectory: true)
    if rootOverride == nil, canonicalDirectory(root).path != target.ownershipRoot {
      throw CLIUsageError("workflow ownership root identity drifted: \(target.ownershipRoot)")
    }
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: [],
      errorHandler: { url, error in
        enumerationError = CLIUsageError("unable to enumerate workflow ownership entry \(url.path): \(error)")
        return false
      }
    ) else {
      throw CLIUsageError("unable to enumerate workflow ownership root: \(root.path)")
    }
    var discovered: [WorkflowOwnedFile] = []
    var paths = Set<String>()
    for case let candidate as URL in enumerator {
      let values = try candidate.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true {
        throw CLIUsageError("workflow history refuses symbolic link: \(candidate.path)")
      }
      guard values.isRegularFile == true else {
        if isDirectory(candidate) { continue }
        throw CLIUsageError("workflow history refuses special file: \(candidate.path)")
      }
      let lexical = candidate.standardizedFileURL
      guard lexical.path.hasPrefix(root.path + "/") else {
        throw CLIUsageError("workflow artifact escapes ownership root: \(candidate.path)")
      }
      let relativePath = String(lexical.path.dropFirst(root.path.count + 1))
      try WorkflowHistoryCanonicalCoding.validateRelativePath(relativePath)
      guard paths.insert(relativePath).inserted else {
        throw CLIUsageError("duplicate workflow artifact path: \(relativePath)")
      }
      let read = try WorkflowDescriptorRelativeReader.read(lexical, within: root) {
        try beforeFileOpen(relativePath)
      }
      let metadata = WorkflowBundleSnapshotFile(
        relativePath: relativePath,
        contentDigest: WorkflowHistoryCanonicalCoding.sha256(read.bytes),
        byteCount: read.bytes.count,
        artifactKind: artifactKind(relativePath),
        executable: read.executable
      )
      discovered.append(WorkflowOwnedFile(metadata: metadata, url: lexical, bytes: read.bytes, readRoot: root))
    }
    if let enumerationError { throw enumerationError }
    discovered.sort { $0.metadata.relativePath.utf8.lexicographicallyPrecedes($1.metadata.relativePath.utf8) }
    let ownedPaths = try ownedRelativePaths(target: target, root: root, discovered: discovered)
    let localFiles = discovered.filter { ownedPaths.contains($0.metadata.relativePath) }
    let unownedFiles = discovered.filter { !ownedPaths.contains($0.metadata.relativePath) }
    let dependencies = try WorkflowSharedNodeDependencyInventory.files(
      for: target,
      primaryFiles: localFiles
    )
    var dependencyPaths = Set(localFiles.map(\.metadata.relativePath))
    for dependency in dependencies where !dependencyPaths.insert(dependency.metadata.relativePath).inserted {
      throw CLIUsageError("duplicate workflow shared-node dependency path: \(dependency.metadata.relativePath)")
    }
    let files = (localFiles + dependencies).sorted {
      $0.metadata.relativePath.utf8.lexicographicallyPrecedes($1.metadata.relativePath.utf8)
    }
    let digest = try WorkflowHistoryCanonicalCoding.bundleDigest(target: target, files: files.map(\.metadata))
    return WorkflowBundleInventory(target: target, files: files, unownedFiles: unownedFiles, bundleDigest: digest)
  }

  public static func historyRoot(
    for target: WorkflowBundleIdentity,
    workingDirectory: URL,
    configuredRoot: String? = nil
  ) throws -> URL {
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(target.workflowId)
    let scopeRoot: URL = switch target.sourceScope {
    case .user:
      URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true)
    case .project, .direct:
      workingDirectory.standardizedFileURL
    }
    let relativeRoot = configuredRoot ?? ".riela/workflow-history"
    try WorkflowHistoryCanonicalCoding.validateRelativePath(relativeRoot)
    let base = scopeRoot.appendingPathComponent(relativeRoot, isDirectory: true).standardizedFileURL
    guard contained(base, in: scopeRoot) else {
      throw CLIUsageError("configured workflow history root escapes selected scope")
    }
    let root = base.appendingPathComponent(target.workflowId, isDirectory: true).standardizedFileURL
    guard contained(root, in: base) else {
      throw CLIUsageError("workflow history root escapes selected scope")
    }
    try rejectSymbolicLinkComponents(in: root, stoppingAt: scopeRoot)
    let canonicalHistory = canonicalForPotentialPath(root)
    let canonicalOwnership = canonicalForPotentialPath(URL(fileURLWithPath: target.ownershipRoot, isDirectory: true))
    guard !contained(canonicalHistory, in: canonicalOwnership),
          !contained(canonicalOwnership, in: canonicalHistory) else {
      throw CLIUsageError("workflow history root and ownership root must be disjoint")
    }
    return root
  }

  public static func rejectSymbolicLinkComponents(in url: URL, stoppingAt root: URL) throws {
    let lexicalRoot = root.standardizedFileURL
    let lexicalURL = url.standardizedFileURL
    let prefix = lexicalRoot.path == "/" ? "/" : lexicalRoot.path + "/"
    guard lexicalURL.path == lexicalRoot.path || lexicalURL.path.hasPrefix(prefix) else {
      throw CLIUsageError("workflow history path escapes selected root")
    }
    var current = lexicalURL
    while true {
      var status = stat()
      if lstat(current.path, &status) == 0 {
        if (status.st_mode & S_IFMT) == S_IFLNK {
          throw CLIUsageError("workflow history path contains a symbolic-link component: \(current.path)")
        }
        if current.path != lexicalURL.path, (status.st_mode & S_IFMT) != S_IFDIR {
          throw CLIUsageError("workflow history path component is not a directory: \(current.path)")
        }
      } else if errno != ENOENT {
        throw CLIUsageError("unable to validate workflow history path component: \(current.path)")
      }
      if current.path == lexicalRoot.path { break }
      current.deleteLastPathComponent()
    }
  }

  public static func contained(_ child: URL, in root: URL) -> Bool {
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
    return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
  }

  private static func canonicalDirectory(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
  }

  private static func canonicalForPotentialPath(_ url: URL) -> URL {
    var existing = url.standardizedFileURL
    var suffix: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
      suffix.append(existing.lastPathComponent)
      existing.deleteLastPathComponent()
    }
    return suffix.reversed().reduce(existing.resolvingSymlinksInPath().standardizedFileURL) {
      $0.appendingPathComponent($1)
    }.standardizedFileURL
  }

  private static func authoredContractVersion(at workflowDirectory: URL) throws -> String? {
    let url = workflowDirectory.appendingPathComponent("workflow.json")
    let data = try WorkflowDescriptorRelativeReader.read(url, within: workflowDirectory).bytes
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CLIUsageError("workflow declaration must be a JSON object: \(url.path)")
    }
    return object["workflowContractVersion"] as? String
  }

  private static func workflowRelativePath(target: WorkflowBundleIdentity) -> String {
    let workflow = URL(fileURLWithPath: target.workflowDirectory).appendingPathComponent("workflow.json").path
    return String(workflow.dropFirst(target.ownershipRoot.count + 1))
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
  }

  private static func artifactKind(_ path: String) -> WorkflowArtifactKind {
    if path.hasSuffix("workflow.json") { return .workflowDefinition }
    if path.contains("/nodes/") || path.hasPrefix("nodes/") { return .node }
    if path.contains("prompt") { return .prompt }
    if path.hasSuffix("mock-scenario.json") { return .mockScenario }
    if path.hasSuffix("EXPECTED_RESULTS.md") { return .expectedResults }
    if path.hasSuffix("riela-package.json") { return .packageMetadata }
    return .ownedArtifact
  }

  private static func ownedRelativePaths(
    target: WorkflowBundleIdentity,
    root: URL,
    discovered: [WorkflowOwnedFile]
  ) throws -> Set<String> {
    let byPath = Dictionary(uniqueKeysWithValues: discovered.map { ($0.metadata.relativePath, $0) })
    let workflowPath = workflowRelativePath(target: target)
    guard byPath[workflowPath] != nil else {
      throw CLIUsageError("workflow ownership inventory does not contain workflow.json")
    }
    let workflowPrefix = String(
      URL(fileURLWithPath: target.workflowDirectory).path.dropFirst(root.path.count)
    ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    func relativeToOwnershipRoot(_ authoredPath: String, declaringPrefix: String) throws -> String {
      try WorkflowHistoryCanonicalCoding.validateRelativePath(authoredPath)
      return declaringPrefix.isEmpty ? authoredPath : "\(declaringPrefix)/\(authoredPath)"
    }
    var owned: Set<String> = [workflowPath]
    var queue = [(path: workflowPath, declaringPrefix: workflowPrefix)]
    var declarationsByPath = [workflowPath: workflowPrefix]
    let fileReferenceKeys: Set<String> = [
      "nodeFile", "stepFile", "promptTemplateFile", "systemPromptTemplateFile",
      "sessionStartPromptTemplateFile", "scriptPath", "containerfilePath", "sourcePath"
    ]
    let directoryReferenceKeys: Set<String> = ["workflowDirectory", "nestedWorkflowDirectory"]
    while let entry = queue.popLast() {
      let path = entry.path
      guard path.hasSuffix(".json"), let file = byPath[path] else { continue }
      let bytes: Data
      let object: Any
      do {
        bytes = try WorkflowDescriptorRelativeReader.read(file.url, within: root).bytes
        object = try JSONSerialization.jsonObject(with: bytes)
      } catch {
        throw CLIUsageError("unable to read or parse declaration JSON \(path): \(error)")
      }
      var references: [(String, Bool)] = []
      collectReferences(
        object,
        fileKeys: fileReferenceKeys,
        directoryKeys: directoryReferenceKeys,
        into: &references
      )
      for (authoredPath, isDirectory) in references {
        let relative = try relativeToOwnershipRoot(authoredPath, declaringPrefix: entry.declaringPrefix)
        if isDirectory {
          let prefix = relative + "/"
          let matches = byPath.keys.filter { $0.hasPrefix(prefix) }
          guard !matches.isEmpty else { throw CLIUsageError("declared workflow directory is missing: \(authoredPath)") }
          for match in matches {
            if let existing = declarationsByPath[match], existing != relative {
              throw CLIUsageError("workflow artifact is declared from conflicting nested roots: \(match)")
            }
            declarationsByPath[match] = relative
            if owned.insert(match).inserted { queue.append((match, relative)) }
          }
        } else {
          guard byPath[relative] != nil else { throw CLIUsageError("declared workflow artifact is missing: \(authoredPath)") }
          if let existing = declarationsByPath[relative], existing != entry.declaringPrefix {
            throw CLIUsageError("workflow artifact is declared from conflicting nested roots: \(relative)")
          }
          declarationsByPath[relative] = entry.declaringPrefix
          if owned.insert(relative).inserted { queue.append((relative, entry.declaringPrefix)) }
        }
      }
    }
    let conventionalNames = ["EXPECTED_RESULTS.md"]
    for name in conventionalNames {
      let relative = try relativeToOwnershipRoot(name, declaringPrefix: workflowPrefix)
      if byPath[relative] != nil { owned.insert(relative) }
    }
    let scenarioPrefix = workflowPrefix.isEmpty ? "" : "\(workflowPrefix)/"
    for path in byPath.keys where path.hasPrefix(scenarioPrefix) {
      let local = String(path.dropFirst(scenarioPrefix.count))
      if !local.contains("/"), local.hasPrefix("mock-scenario"), local.hasSuffix(".json") {
        owned.insert(path)
      }
    }
    if target.packageDirectory != nil, byPath["riela-package.json"] != nil {
      owned.insert("riela-package.json")
    }
    return owned
  }

  private static func collectReferences(
    _ value: Any,
    fileKeys: Set<String>,
    directoryKeys: Set<String>,
    into references: inout [(String, Bool)]
  ) {
    if let object = value as? [String: Any] {
      for (key, child) in object {
        if let path = child as? String, fileKeys.contains(key) { references.append((path, false)) }
        if let path = child as? String, directoryKeys.contains(key) { references.append((path, true)) }
        collectReferences(child, fileKeys: fileKeys, directoryKeys: directoryKeys, into: &references)
      }
    } else if let array = value as? [Any] {
      for child in array {
        collectReferences(child, fileKeys: fileKeys, directoryKeys: directoryKeys, into: &references)
      }
    }
  }
}
