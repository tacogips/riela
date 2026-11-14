import Foundation

public enum KaibaBindingScope: String, Codable, Sendable {
  case project
  case user
  case profile
  case external
}

public enum KaibaBindingOrigin: String, Codable, Sendable {
  case definition
  case instancePatch = "instance_patch"
}

public struct KaibaBindingReference: Codable, Equatable, Sendable {
  public var scope: KaibaBindingScope
  public var profile: String?
  public var workflowId: String
  public var workflowInstanceIdentity: String?
  public var nodeId: String
  public var bindingOrigin: KaibaBindingOrigin
  public var sourcePath: String
  public var kaibaInstanceId: String
}

public struct KaibaBindingScanRoots: Sendable {
  public var projectRootURL: URL
  public var homeURL: URL
  public var appRootURL: URL

  public init(projectRootURL: URL, homeURL: URL, appRootURL: URL? = nil) {
    self.projectRootURL = projectRootURL
    self.homeURL = homeURL
    self.appRootURL = appRootURL ?? homeURL
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("rielaapp", isDirectory: true)
  }
}

public enum KaibaBindingScannerError: Error, Equatable, Sendable {
  case failed
}

/// Scans only registered Riela workflow roots. It never follows symlinks or
/// treats arbitrary JSON values as bindings; only kaiba/* node add-on config
/// can contribute an instance ID.
public struct KaibaBindingScanner: Sendable {
  private let afterInitialSourceSnapshot: (@Sendable () -> Void)?
  private let beforeFinalSourceSnapshot: (@Sendable () -> Void)?

  public init() {
    afterInitialSourceSnapshot = nil
    beforeFinalSourceSnapshot = nil
  }

  init(
    afterInitialSourceSnapshot: @escaping @Sendable () -> Void,
    beforeFinalSourceSnapshot: (@Sendable () -> Void)? = nil
  ) {
    self.afterInitialSourceSnapshot = afterInitialSourceSnapshot
    self.beforeFinalSourceSnapshot = beforeFinalSourceSnapshot
  }

  public func references(
    to instanceID: String,
    roots: KaibaBindingScanRoots
  ) throws -> [KaibaBindingReference] {
    let initialRoots = try scanRoots(from: roots)
    let initialSnapshot = try sourceSnapshot(for: initialRoots)
    afterInitialSourceSnapshot?()
    let references = try references(in: initialSnapshot, to: instanceID)
    beforeFinalSourceSnapshot?()
    let finalRoots = try scanRoots(from: roots)
    let finalSnapshot = try sourceSnapshot(for: finalRoots)
    guard initialSnapshot == finalSnapshot else {
      throw KaibaBindingScannerError.failed
    }
    return references.sorted(by: Self.less)
  }

  private func scanRoots(from roots: KaibaBindingScanRoots) throws -> [ScanRoot] {
    var result: [ScanRoot] = [
      .init(scope: .project, profile: nil, url: roots.projectRootURL.appendingPathComponent(".riela/instances.json"), allowedRootURL: roots.projectRootURL, kind: .instancesFile),
      .init(scope: .project, profile: nil, url: roots.projectRootURL.appendingPathComponent(".riela/workflows"), allowedRootURL: roots.projectRootURL, kind: .workflowTree),
      .init(scope: .project, profile: nil, url: roots.projectRootURL.appendingPathComponent(".riela/packages"), allowedRootURL: roots.projectRootURL, kind: .workflowTree),
      .init(scope: .user, profile: nil, url: roots.homeURL.appendingPathComponent(".riela/instances.json"), allowedRootURL: roots.homeURL, kind: .instancesFile),
      .init(scope: .user, profile: nil, url: roots.homeURL.appendingPathComponent(".riela/workflows"), allowedRootURL: roots.homeURL, kind: .workflowTree),
      .init(scope: .user, profile: nil, url: roots.homeURL.appendingPathComponent(".riela/packages"), allowedRootURL: roots.homeURL, kind: .workflowTree)
    ]
    let profilesURL = roots.appRootURL.appendingPathComponent("profiles", isDirectory: true)
    guard FileManager.default.fileExists(atPath: profilesURL.path) else { return deduplicated(result) }
    guard try isDirectoryNotSymlink(profilesURL) else { throw KaibaBindingScannerError.failed }
    let profiles: [URL]
    do {
      profiles = try FileManager.default.contentsOfDirectory(
        at: profilesURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw KaibaBindingScannerError.failed
    }
    for discoveredProfileURL in profiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let profileURL = profilesURL.appendingPathComponent(discoveredProfileURL.lastPathComponent, isDirectory: true)
      guard try isDirectoryNotSymlink(profileURL) else { throw KaibaBindingScannerError.failed }
      let profile = profileURL.lastPathComponent
      result += [
        .init(scope: .profile, profile: profile, url: profileURL.appendingPathComponent("daemon-workflows.json"), allowedRootURL: roots.appRootURL, kind: .profileState),
        .init(scope: .profile, profile: profile, url: profileURL.appendingPathComponent("workflows"), allowedRootURL: roots.appRootURL, kind: .workflowTree),
        .init(scope: .profile, profile: profile, url: profileURL.appendingPathComponent("packages"), allowedRootURL: roots.appRootURL, kind: .workflowTree)
      ]
      for external in try registeredRoots(
        in: profileURL.appendingPathComponent("daemon-workflows.json"),
        allowedRootURL: roots.appRootURL
      ) {
        switch external.kind {
        case .project:
          result += [
            .init(scope: .external, profile: profile, url: external.url.appendingPathComponent(".riela/instances.json"), allowedRootURL: external.url, kind: .instancesFile),
            .init(scope: .external, profile: profile, url: external.url.appendingPathComponent(".riela/workflows"), allowedRootURL: external.url, kind: .workflowTree),
            .init(scope: .external, profile: profile, url: external.url.appendingPathComponent(".riela/packages"), allowedRootURL: external.url, kind: .workflowTree)
          ]
        case .workflow:
          result.append(.init(scope: .external, profile: profile, url: external.url, allowedRootURL: external.url, kind: .workflowTree))
        }
      }
    }
    return deduplicated(result)
  }

  private func registeredRoots(in stateURL: URL, allowedRootURL: URL) throws -> [RegisteredRoot] {
    guard FileManager.default.fileExists(atPath: stateURL.path) else { return [] }
    guard try isRegularFileWithoutSymlink(at: stateURL, containedBy: allowedRootURL) else {
      throw KaibaBindingScannerError.failed
    }
    let object = try jsonObject(at: stateURL)
    var roots: [RegisteredRoot] = []
    for (key, kind) in [("workflowDirectories", RegisteredRoot.Kind.workflow), ("projectDirectories", .project)] {
      guard let values = object[key] else { continue }
      guard let strings = values as? [String] else { throw KaibaBindingScannerError.failed }
      for value in strings where !value.isEmpty {
        let url = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        guard url.path.hasPrefix("/") else { throw KaibaBindingScannerError.failed }
        roots.append(.init(url: url, kind: kind))
      }
    }
    return roots
  }

  private func references(
    in snapshot: BindingScanSnapshot,
    to instanceID: String
  ) throws -> [KaibaBindingReference] {
    try snapshot.sources.flatMap { source in
      let discovered: [KaibaBindingReference]
      switch source.kind {
      case .workflowTree:
        discovered = try source.documents.flatMap { try workflowReferences(in: $0, root: source) }
      case .instancesFile:
        discovered = try instancePatchReferences(in: source)
      case .profileState:
        discovered = try profilePatchReferences(in: source)
      }
      return discovered.filter { $0.kaibaInstanceId == instanceID }
    }
  }

  private func workflowDocumentURLs(in root: ScanRoot) throws -> [URL] {
    guard isContained(root.url, by: root.allowedRootURL) else {
      throw KaibaBindingScannerError.failed
    }
    guard FileManager.default.fileExists(atPath: root.url.path) else { return [] }
    guard try isDirectoryNotSymlink(root.url) else { throw KaibaBindingScannerError.failed }
    let canonicalRoot = root.url.resolvingSymlinksInPath().standardizedFileURL
    var didEncounterError = false
    guard let enumerator = FileManager.default.enumerator(
      at: root.url,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles],
      errorHandler: { _, _ in
        didEncounterError = true
        return false
      }
    ) else {
      throw KaibaBindingScannerError.failed
    }
    var documents: [URL] = []
    for case let candidate as URL in enumerator {
      let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      guard let values else { throw KaibaBindingScannerError.failed }
      if values.isSymbolicLink == true {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard values.isRegularFile == true, candidate.lastPathComponent == "workflow.json" else { continue }
      let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
      guard canonical.path.hasPrefix(canonicalRoot.path + "/") else { throw KaibaBindingScannerError.failed }
      documents.append(canonical)
    }
    guard !didEncounterError else { throw KaibaBindingScannerError.failed }
    return documents.sorted(by: { $0.path < $1.path })
  }

  private func workflowReferences(
    in source: ScannedSourceDocument,
    root: ScannedSourceRoot
  ) throws -> [KaibaBindingReference] {
    let document = try jsonObject(from: source.contents)
    guard let workflowId = document["workflowId"] as? String, !workflowId.isEmpty,
          let nodes = (document["nodes"] ?? document["nodeRegistry"]) as? [[String: Any]] else {
      throw KaibaBindingScannerError.failed
    }
    return try nodes.compactMap { node in
      guard let nodeID = node["id"] as? String, !nodeID.isEmpty else { throw KaibaBindingScannerError.failed }
      guard let addon = node["addon"] as? [String: Any],
            let name = addon["name"] as? String,
            name.hasPrefix("kaiba/") else { return nil }
      guard let config = addon["config"] as? [String: Any] else { return nil }
      guard let rawID = config["kaibaInstanceId"] else { return nil }
      guard let instanceID = rawID as? String, !instanceID.isEmpty else { throw KaibaBindingScannerError.failed }
      return KaibaBindingReference(
        scope: root.scope,
        profile: root.profile,
        workflowId: workflowId,
        workflowInstanceIdentity: nil,
        nodeId: nodeID,
        bindingOrigin: .definition,
        sourcePath: source.path,
        kaibaInstanceId: instanceID
      )
    }
  }

  private func instancePatchReferences(in source: ScannedSourceRoot) throws -> [KaibaBindingReference] {
    guard source.isPresent else { return [] }
    guard let documentSource = source.documents.first else { throw KaibaBindingScannerError.failed }
    let document = try jsonObject(from: documentSource.contents)
    guard let instances = document["instances"] as? [[String: Any]] else {
      throw KaibaBindingScannerError.failed
    }
    return try instances.flatMap { instance in
      guard let workflowID = instance["workflowId"] as? String, !workflowID.isEmpty,
            let identity = instance["identity"] as? String, !identity.isEmpty else {
        throw KaibaBindingScannerError.failed
      }
      let configuration = instance["configuration"] as? [String: Any] ?? [:]
      return try patchReferences(
        configuration: configuration,
        workflowID: workflowID,
        workflowInstanceIdentity: identity,
        source: source
      )
    }
  }

  private func profilePatchReferences(in source: ScannedSourceRoot) throws -> [KaibaBindingReference] {
    guard source.isPresent else { return [] }
    guard let documentSource = source.documents.first else { throw KaibaBindingScannerError.failed }
    let document = try jsonObject(from: documentSource.contents)
    guard let rawPreferences = document["preferences"] else { return [] }
    guard let preferences = rawPreferences as? [String: [String: Any]] else { throw KaibaBindingScannerError.failed }
    return try preferences.keys.sorted().flatMap { preferenceIdentity in
      guard let preference = preferences[preferenceIdentity] else {
        throw KaibaBindingScannerError.failed
      }
      let identity = (preference["identity"] as? String) ?? preferenceIdentity
      guard !identity.isEmpty else { throw KaibaBindingScannerError.failed }
      let sourceIdentity = preference["sourceIdentity"] as? String
      let workflowID = workflowID(from: sourceIdentity ?? identity)
      guard !workflowID.isEmpty else { throw KaibaBindingScannerError.failed }
      let configuration = preference["configuration"] as? [String: Any] ?? [:]
      return try patchReferences(
        configuration: configuration,
        workflowID: workflowID,
        workflowInstanceIdentity: identity,
        source: source
      )
    }
  }

  private func patchReferences(
    configuration: [String: Any],
    workflowID: String,
    workflowInstanceIdentity: String,
    source: ScannedSourceRoot
  ) throws -> [KaibaBindingReference] {
    guard let patches = configuration["nodePatches"] else { return [] }
    guard let nodePatches = patches as? [String: [String: Any]] else {
      throw KaibaBindingScannerError.failed
    }
    return try nodePatches.keys.sorted().compactMap { nodeID in
      guard !nodeID.isEmpty, let patch = nodePatches[nodeID] else {
        throw KaibaBindingScannerError.failed
      }
      guard let addon = patch["addon"] as? [String: Any],
            let name = addon["name"] as? String,
            name.hasPrefix("kaiba/") else {
        return nil
      }
      guard let config = addon["config"] as? [String: Any] else { return nil }
      guard let instanceID = config["kaibaInstanceId"] else { return nil }
      guard let kaibaInstanceID = instanceID as? String, !kaibaInstanceID.isEmpty else {
        throw KaibaBindingScannerError.failed
      }
      return KaibaBindingReference(
        scope: source.scope,
        profile: source.profile,
        workflowId: workflowID,
        workflowInstanceIdentity: workflowInstanceIdentity,
        nodeId: nodeID,
        bindingOrigin: .instancePatch,
        sourcePath: source.path,
        kaibaInstanceId: kaibaInstanceID
      )
    }
  }

  private func workflowID(from sourceIdentity: String) -> String {
    for prefix in ["user-workflow:", "app-workflow:", "project-workflow:"] where sourceIdentity.hasPrefix(prefix) {
      return String(sourceIdentity.dropFirst(prefix.count))
    }
    return sourceIdentity
  }

  private func jsonObject(at url: URL) throws -> [String: Any] {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw KaibaBindingScannerError.failed
      }
      let data = try Data(contentsOf: url)
      let object = try jsonObject(from: data)
      guard try Data(contentsOf: url) == data else {
        throw KaibaBindingScannerError.failed
      }
      return object
    } catch let error as KaibaBindingScannerError {
      throw error
    } catch {
      throw KaibaBindingScannerError.failed
    }
  }

  private func jsonObject(from data: Data) throws -> [String: Any] {
    do {
      var duplicateKeyValidator = StrictJSONDuplicateKeyValidator(data: data)
      try duplicateKeyValidator.validate()
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw KaibaBindingScannerError.failed
      }
      return object
    } catch let error as KaibaBindingScannerError {
      throw error
    } catch {
      throw KaibaBindingScannerError.failed
    }
  }

  private func sourceSnapshot(for roots: [ScanRoot]) throws -> BindingScanSnapshot {
    try BindingScanSnapshot(sources: roots.map { root in
      guard isContained(root.url, by: root.allowedRootURL) else {
        throw KaibaBindingScannerError.failed
      }
      let rootPath = canonicalURL(root.url).path
      let documents: [ScannedSourceDocument]
      let isPresent: Bool
      switch root.kind {
      case .workflowTree:
        let urls = try workflowDocumentURLs(in: root)
        documents = try urls.map { url in
          try sourceDocument(at: url, in: root)
        }
        isPresent = FileManager.default.fileExists(atPath: root.url.path)
      case .instancesFile, .profileState:
        isPresent = try isRegularFileWithoutSymlink(at: root.url, containedBy: root.allowedRootURL)
        documents = isPresent ? [try sourceDocument(at: root.url, in: root)] : []
      }
      return ScannedSourceRoot(
        scope: root.scope,
        profile: root.profile,
        kind: root.kind,
        path: rootPath,
        isPresent: isPresent,
        documents: documents
      )
    })
  }

  private func isDirectoryNotSymlink(_ url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  private func sourceDocument(at url: URL, in root: ScanRoot) throws -> ScannedSourceDocument {
    guard try isRegularFileWithoutSymlink(at: url, containedBy: root.allowedRootURL) else {
      throw KaibaBindingScannerError.failed
    }
    let contents: Data
    do {
      contents = try Data(contentsOf: url)
    } catch {
      throw KaibaBindingScannerError.failed
    }
    guard try isRegularFileWithoutSymlink(at: url, containedBy: root.allowedRootURL) else {
      throw KaibaBindingScannerError.failed
    }
    return ScannedSourceDocument(url: url, contents: contents)
  }

  private func isRegularFileWithoutSymlink(at url: URL, containedBy allowedRootURL: URL) throws -> Bool {
    guard isContained(url, by: allowedRootURL) else {
      throw KaibaBindingScannerError.failed
    }
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
      throw KaibaBindingScannerError.failed
    }
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw KaibaBindingScannerError.failed
      }
      return true
    } catch let error as KaibaBindingScannerError {
      throw error
    } catch {
      throw KaibaBindingScannerError.failed
    }
  }

  private func isContained(_ url: URL, by allowedRootURL: URL) -> Bool {
    let path = normalizedPath(url.standardizedFileURL.path)
    let allowedPath = normalizedPath(allowedRootURL.standardizedFileURL.path)
    guard path == allowedPath || path.hasPrefix(allowedPath + "/") else { return false }

    var ancestor = URL(fileURLWithPath: allowedPath, isDirectory: true)
    guard !isSymbolicLink(ancestor) else { return false }
    let relativePath = String(path.dropFirst(allowedPath.count))
    for component in relativePath.split(separator: "/") {
      ancestor.appendPathComponent(String(component))
      guard !isSymbolicLink(ancestor) else { return false }
    }
    return true
  }

  private func normalizedPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return trimmed.isEmpty ? "/" : "/" + trimmed
  }

  private func canonicalURL(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private func deduplicated(_ roots: [ScanRoot]) -> [ScanRoot] {
    var seen = Set<String>()
    return roots.filter {
      seen.insert($0.url.resolvingSymlinksInPath().standardizedFileURL.path).inserted
    }
  }

  private static func less(_ lhs: KaibaBindingReference, _ rhs: KaibaBindingReference) -> Bool {
    let scopeOrder: [KaibaBindingScope] = [.project, .user, .profile, .external]
    let leftScope = scopeOrder.firstIndex(of: lhs.scope) ?? scopeOrder.count
    let rightScope = scopeOrder.firstIndex(of: rhs.scope) ?? scopeOrder.count
    let left = [String(leftScope), lhs.profile ?? "", lhs.workflowId, lhs.workflowInstanceIdentity ?? "", lhs.nodeId, lhs.bindingOrigin.rawValue, lhs.sourcePath]
    let right = [String(rightScope), rhs.profile ?? "", rhs.workflowId, rhs.workflowInstanceIdentity ?? "", rhs.nodeId, rhs.bindingOrigin.rawValue, rhs.sourcePath]
    return left.lexicographicallyPrecedes(right)
  }
}

private struct ScanRoot: Sendable {
  enum Kind: String, Equatable, Sendable {
    case workflowTree
    case instancesFile
    case profileState
  }

  var scope: KaibaBindingScope
  var profile: String?
  var url: URL
  var allowedRootURL: URL
  var kind: Kind
}

private struct BindingScanSnapshot: Equatable {
  var sources: [ScannedSourceRoot]
}

private struct ScannedSourceRoot: Equatable {
  var scope: KaibaBindingScope
  var profile: String?
  var kind: ScanRoot.Kind
  var path: String
  var isPresent: Bool
  var documents: [ScannedSourceDocument]
}

private struct ScannedSourceDocument: Equatable {
  var path: String
  var contents: Data

  init(url: URL, contents: Data) {
    path = url.resolvingSymlinksInPath().standardizedFileURL.path
    self.contents = contents
  }
}

private struct RegisteredRoot: Sendable {
  enum Kind: Sendable {
    case project
    case workflow
  }

  var url: URL
  var kind: Kind
}
