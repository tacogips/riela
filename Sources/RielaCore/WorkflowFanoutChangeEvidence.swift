import Crypto
import Darwin
import Foundation

/// Cooperative observation at node boundaries, not a write lock. Evidence
/// preserves observed bytes; semantic loss inside one node still needs review.
///
/// Every branch selects two classes of paths:
/// - source paths keep full content snapshots under the source limits;
/// - artifact roots (tool installs, caches, large binaries) are recorded as
///   bounded manifests: kind, mode, size, digest and entry counts, never
///   recursive base64 content.
/// Limit violations and policy rejections surface as structured diagnostics
/// naming branch, node, phase, selection, root, offending path, observed
/// count and limit. Reduce failures become evidence instead of discarding
/// sibling results.
actor WorkflowFanoutChangeEvidence {
  static let sourcePathLimit = 512
  static let sourceEntryLimit = 512
  static let sourceFileByteLimit = 8_000_000
  static let sourceTotalByteLimit = 64_000_000
  static let artifactRootLimit = 64
  static let artifactEntryScanLimit = 200_000

  static var limits: JSONObject {
    [
      "sourcePaths": .integer(Int64(sourcePathLimit)),
      "sourceEntries": .integer(Int64(sourceEntryLimit)),
      "sourceFileBytes": .integer(Int64(sourceFileByteLimit)),
      "sourceTotalBytes": .integer(Int64(sourceTotalByteLimit)),
      "artifactRoots": .integer(Int64(artifactRootLimit)),
      "artifactScanEntries": .integer(Int64(artifactEntryScanLimit))
    ]
  }

  let root: URL
  let directory: URL
  private var records: [String: [JSONObject]] = [:]
  private var captureFailures: [JSONValue] = []
  private var observationHook: (@Sendable (String) throws -> Void)?

  func setObservationHook(_ hook: (@Sendable (String) throws -> Void)?) {
    observationHook = hook
  }

  init(root: URL) throws {
    self.root = root.resolvingSymlinksInPath().standardizedFileURL
    let tmp = self.root.appendingPathComponent("tmp/riela-fanout")
    do {
      try rejectFanoutSymlinkComponents(root: self.root, path: "tmp/riela-fanout")
    } catch let failure as FanoutSnapshotFailure {
      throw failure.adapterError(failure.diagnostic(branchId: nil, stepId: "evidence-directory"))
    }
    guard tmp.resolvingSymlinksInPath().path.hasPrefix(self.root.path + "/") else {
      throw AdapterExecutionError(.policyBlocked, "fanout evidence directory escapes workspace")
    }
    self.directory = tmp.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
  }

  func capture(branchId: String, paths: [String], artifactRoots: [String] = [], stepId: String) throws -> String {
    let roots = Array(Set(paths)).sorted()
    let artifactSelection = Array(Set(artifactRoots)).sorted()
    let files: JSONObject, sourceBytes: Int, artifacts: JSONObject
    do {
      try validateSelection(paths: paths, artifactRoots: artifactRoots)
      (files, sourceBytes) = try snapshot(paths: paths)
      artifacts = try artifactManifests(roots: artifactSelection)
    } catch let failure as FanoutSnapshotFailure {
      let diagnostic = failure.diagnostic(branchId: branchId, stepId: stepId)
      captureFailures.append(.object(diagnostic))
      throw failure.adapterError(diagnostic)
    }
    let name = UUID().uuidString + ".json"
    let url = directory.appendingPathComponent(name)
    let record: JSONObject = ["branchId": .string(branchId), "stepId": .string(stepId),
                              "roots": .array(roots.map(JSONValue.string)),
                              "artifactRoots": .array(artifactSelection.map(JSONValue.string)),
                              "files": .object(files), "artifacts": .object(artifacts),
                              "summary": .object([
                                "sourceEntries": .integer(Int64(files.count)),
                                "sourceBytes": .integer(Int64(sourceBytes)),
                                "artifactRoots": .integer(Int64(artifacts.count)),
                                "limits": .object(Self.limits)
                              ]),
                              "artifactPath": .string(url.path)]
    let data = try JSONEncoder().encode(record)
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      try? handle.close()
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    records[branchId, default: []].append(record)
    return url.path
  }

  /// Compares every recorded capture with the stable final tree. A record whose
  /// roots can no longer be snapshotted within policy is reported under
  /// `reduceFailures` (phase `reduce`) instead of aborting the whole join, so
  /// successful sibling evidence and the original child failure survive.
  func reduce() throws -> JSONObject {
    var observations: [JSONValue] = [], artifacts: [JSONValue] = [], reduceFailures: [JSONValue] = []
    for branchId in records.keys.sorted() {
      for record in records[branchId] ?? [] {
        artifacts.append(record["artifactPath"] ?? .null)
        let stepId: String
        if case let .string(value)? = record["stepId"] { stepId = value } else { stepId = "unknown" }
        do {
          try reduceRecord(record, branchId: branchId, observations: &observations)
        } catch let failure as FanoutSnapshotFailure {
          reduceFailures.append(.object(failure.diagnostic(branchId: branchId, stepId: stepId, phase: "reduce")))
        }
      }
    }
    return ["artifactPaths": .array(artifacts), "observations": .array(observations),
            "hasDrift": .bool(!observations.isEmpty), "requiresSemanticReview": .bool(true),
            "observationBoundary": .string("workflow-node"),
            "complete": .bool(reduceFailures.isEmpty),
            "captureFailures": .array(captureFailures),
            "reduceFailures": .array(reduceFailures),
            "limits": .object(Self.limits)]
  }

  private func reduceRecord(_ record: JSONObject, branchId: String, observations: inout [JSONValue]) throws {
    guard case let .object(files)? = record["files"], case let .array(rootValues)? = record["roots"] else { return }
    let roots = fanoutStrings(rootValues)
    let (current, _) = try snapshot(paths: roots)
    for path in Set(files.keys).union(current.keys).sorted() {
      let old = files[path], new = current[path]
      let oldKind = entryKind(old), newKind = entryKind(new)
      let reason: String
      if oldKind == newKind {
        if old == new { continue }
        reason = oldKind == "directory" && entryChildren(old) != entryChildren(new)
          ? "directory-membership-drift" : "content-or-mode-drift"
      } else {
        reason = kindDriftReason(oldKind: oldKind, newKind: newKind)
      }
      observations.append(observation(branchId: branchId, path: path, selection: "source", reason: reason, record: record))
    }
    guard case let .array(artifactRootValues)? = record["artifactRoots"], !artifactRootValues.isEmpty,
          case let .object(recorded)? = record["artifacts"] else { return }
    let currentArtifacts = try artifactManifests(roots: fanoutStrings(artifactRootValues))
    for path in Set(recorded.keys).union(currentArtifacts.keys).sorted() {
      let old = recorded[path], new = currentArtifacts[path]
      let oldKind = entryKind(old), newKind = entryKind(new)
      let reason: String
      if oldKind == newKind {
        if old == new { continue }
        if oldKind == "directory" {
          reason = entryField(old, "membershipSha256") != entryField(new, "membershipSha256")
            || entryField(old, "entryCount") != entryField(new, "entryCount")
            ? "artifact-membership-drift" : "content-or-mode-drift"
        } else {
          reason = "artifact-content-drift"
        }
      } else {
        reason = kindDriftReason(oldKind: oldKind, newKind: newKind)
      }
      observations.append(observation(branchId: branchId, path: path, selection: "artifact", reason: reason, record: record))
    }
  }

  private func observation(branchId: String, path: String, selection: String, reason: String, record: JSONObject) -> JSONValue {
    .object([
      "branchId": .string(branchId), "path": .string(path), "selection": .string(selection),
      "snapshotPath": record["artifactPath"] ?? .null,
      "stepId": record["stepId"] ?? .null,
      "reason": .string(reason)
    ])
  }

  private func kindDriftReason(oldKind: String, newKind: String) -> String {
    if oldKind == "missing" { return "entry-added" }
    if newKind == "missing" { return "entry-removed" }
    return "entry-kind-drift"
  }

  // MARK: - Selection validation

  private func validateSelection(paths: [String], artifactRoots: [String]) throws {
    guard artifactRoots.count <= Self.artifactRootLimit else {
      throw FanoutSnapshotFailure(.policyBlocked, "fanout change tracking requires at most \(Self.artifactRootLimit) artifact roots",
                                  selection: "artifact", observed: artifactRoots.count, limit: Self.artifactRootLimit)
    }
    let sources = Set(paths)
    let evidencePath = evidenceRelativePath()
    for artifact in Set(artifactRoots).sorted() {
      do {
        try validateFanoutPath(artifact)
      } catch let failure as FanoutSnapshotFailure {
        throw failure.annotated(selection: "artifact", root: artifact)
      }
      if artifact == evidencePath || evidencePath.hasPrefix(artifact + "/") {
        throw FanoutSnapshotFailure(.policyBlocked, "fanout artifact selection contains its evidence directory",
                                    selection: "artifact", root: artifact, path: artifact)
      }
      for source in sources.sorted() {
        if source == artifact {
          throw FanoutSnapshotFailure(.policyBlocked, "fanout artifact root duplicates a source snapshot path",
                                      selection: "artifact", root: artifact, path: source)
        }
        if artifact.hasPrefix(source + "/") {
          throw FanoutSnapshotFailure(.policyBlocked, "fanout artifact root is inside a source snapshot root",
                                      selection: "artifact", root: source, path: artifact)
        }
      }
      for other in Set(artifactRoots).sorted() where other != artifact && artifact.hasPrefix(other + "/") {
        throw FanoutSnapshotFailure(.policyBlocked, "fanout artifact roots overlap",
                                    selection: "artifact", root: other, path: artifact)
      }
    }
  }

  private func evidenceRelativePath() -> String {
    directory.path.replacingOccurrences(of: root.path + "/", with: "")
  }

  // MARK: - Source snapshots

  private func snapshot(paths: [String]) throws -> (JSONObject, Int) {
    guard !paths.isEmpty, paths.count <= Self.sourcePathLimit else {
      throw FanoutSnapshotFailure(.policyBlocked, "fanout change tracking requires 1...\(Self.sourcePathLimit) paths",
                                  selection: "source", observed: paths.count, limit: Self.sourcePathLimit)
    }
    var result: JSONObject = [:], total = 0
    let evidencePath = evidenceRelativePath()
    for path in Set(paths).sorted() {
      do {
        try validateFanoutPath(path)
        if path == evidencePath || evidencePath.hasPrefix(path + "/") {
          throw FanoutSnapshotFailure(.policyBlocked, "fanout selection contains its evidence directory", path: path)
        }
        try snapshotEntry(path, declared: true, result: &result, total: &total)
      } catch let failure as FanoutSnapshotFailure {
        throw failure.annotated(selection: "source", root: path)
      }
    }
    return (result, total)
  }

  private func snapshotEntry(_ path: String, declared: Bool, result: inout JSONObject, total: inout Int) throws {
    if result[path] != nil { return }
    try validateFanoutPath(path)
    guard result.count < Self.sourceEntryLimit else {
      throw FanoutSnapshotFailure(.policyBlocked, "fanout snapshot exceeds \(Self.sourceEntryLimit) entries",
                                  path: path, observed: result.count + 1, limit: Self.sourceEntryLimit)
    }
    try rejectFanoutSymlinkComponents(root: root, path: path)
    let url = root.appendingPathComponent(path)
    guard let initial = try fanoutStatus(url, missingAllowed: declared, path: path) else {
      result[path] = .object(["kind": .string("missing")]); return
    }
    let kind = initial.st_mode & mode_t(S_IFMT)
    guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) else {
      throw FanoutSnapshotFailure(.policyBlocked, "fanout snapshot refuses special entries", path: path)
    }
    guard access(url.path, kind == mode_t(S_IFDIR) ? R_OK | X_OK : R_OK) == 0 else {
      throw FanoutSnapshotFailure(.policyBlocked, "fanout snapshot refuses unreadable entries", path: path)
    }
    if kind == mode_t(S_IFDIR) {
      let children = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
      result[path] = .object(["kind": .string("directory"),
                              "mode": .integer(Int64(initial.st_mode & 0o7777)),
                              "children": .array(children.map(JSONValue.string))])
      try observationHook?("directory:\(path)")
      for child in children {
        try snapshotEntry(path + "/" + child, declared: false, result: &result, total: &total)
      }
      try rejectFanoutSymlinkComponents(root: root, path: path)
      let after = try fanoutStatus(url, missingAllowed: false, path: path)
      guard fanoutSameEntry(initial, after) else { throw fanoutSnapshotMutation(path) }
      let finalChildren = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
      guard children == finalChildren else {
        throw fanoutSnapshotMutation(path)
      }
      try rejectFanoutSymlinkComponents(root: root, path: path)
    } else {
      let size = Int(initial.st_size)
      guard size <= Self.sourceFileByteLimit else {
        throw FanoutSnapshotFailure(.policyBlocked, "fanout change tracking requires files up to 8 MB",
                                    path: path, observed: size, limit: Self.sourceFileByteLimit)
      }
      guard total <= Self.sourceTotalByteLimit - size else {
        throw FanoutSnapshotFailure(.policyBlocked, "fanout snapshot exceeds 64 MB",
                                    path: path, observed: total + size, limit: Self.sourceTotalByteLimit)
      }
      let bytes = try fanoutReadFile(url, expected: initial, maximum: size, path: path)
      try observationHook?("file:\(path)")
      try rejectFanoutSymlinkComponents(root: root, path: path)
      let after = try fanoutStatus(url, missingAllowed: false, path: path)
      guard bytes.count == size, bytes.count <= Self.sourceFileByteLimit,
            fanoutSameEntry(initial, after) else {
        throw fanoutSnapshotMutation(path)
      }
      try rejectFanoutSymlinkComponents(root: root, path: path)
      total += bytes.count
      result[path] = .object([
        "kind": .string("file"), "sha256": .string(fanoutHex(SHA256.hash(data: bytes))),
        "mode": .integer(Int64(initial.st_mode & 0o7777)),
        "contentBase64": .string(bytes.base64EncodedString())
      ])
    }
  }

  // MARK: - Artifact manifests

  private func artifactManifests(roots: [String]) throws -> JSONObject {
    var result: JSONObject = [:]
    for path in Set(roots).sorted() {
      do {
        result[path] = try artifactManifest(path)
      } catch let failure as FanoutSnapshotFailure {
        throw failure.annotated(selection: "artifact", root: path)
      }
    }
    return result
  }

  /// Artifact roots are identified, never copied: a regular file yields its
  /// size and streaming SHA256; a directory yields bounded entry counts, byte
  /// totals and a digest over sorted relative names, kinds and sizes. Symlinks
  /// inside an artifact root are counted without being followed. The root
  /// itself still obeys path, symlink-ancestry and readability policy.
  private func artifactManifest(_ path: String) throws -> JSONValue {
    try validateFanoutPath(path)
    try rejectFanoutSymlinkComponents(root: root, path: path)
    let url = root.appendingPathComponent(path)
    guard let initial = try fanoutStatus(url, missingAllowed: true, path: path) else {
      return .object(["kind": .string("missing")])
    }
    let kind = initial.st_mode & mode_t(S_IFMT)
    if kind == mode_t(S_IFDIR) {
      guard access(url.path, R_OK | X_OK) == 0 else {
        throw FanoutSnapshotFailure(.policyBlocked, "fanout artifact root refuses unreadable entries", path: path)
      }
      try observationHook?("artifact-directory:\(path)")
      let manifest = try artifactDirectoryManifest(path, mode: initial.st_mode)
      try rejectFanoutSymlinkComponents(root: root, path: path)
      guard fanoutSameEntry(initial, try fanoutStatus(url, missingAllowed: false, path: path)) else {
        throw fanoutSnapshotMutation(path)
      }
      return manifest
    }
    if kind == mode_t(S_IFREG) {
      guard access(url.path, R_OK) == 0 else {
        throw FanoutSnapshotFailure(.policyBlocked, "fanout artifact root refuses unreadable entries", path: path)
      }
      let digest = try fanoutDigestFile(url, expected: initial, path: path)
      try observationHook?("artifact-file:\(path)")
      try rejectFanoutSymlinkComponents(root: root, path: path)
      guard fanoutSameEntry(initial, try fanoutStatus(url, missingAllowed: false, path: path)) else {
        throw fanoutSnapshotMutation(path)
      }
      return .object(["kind": .string("file"), "mode": .integer(Int64(initial.st_mode & 0o7777)),
                      "size": .integer(Int64(initial.st_size)), "sha256": .string(digest)])
    }
    throw FanoutSnapshotFailure(.policyBlocked, "fanout artifact root refuses special entries", path: path)
  }

  private func artifactDirectoryManifest(_ path: String, mode: mode_t) throws -> JSONValue {
    var hasher = SHA256()
    var files = 0, directories = 0, symlinks = 0, other = 0, entryCount = 0
    var regularFileBytes: Int64 = 0
    var truncated = false
    var pending = [path]
    scan: while let current = pending.popLast() {
      let children: [String]
      do {
        children = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(current).path).sorted()
      } catch {
        throw FanoutSnapshotFailure(.policyBlocked, "fanout artifact root contains unreadable entries", path: current)
      }
      var subdirectories: [String] = []
      for child in children {
        guard entryCount < Self.artifactEntryScanLimit else { truncated = true; break scan }
        let childPath = current + "/" + child
        var status = stat()
        guard lstat(root.appendingPathComponent(childPath).path, &status) == 0 else {
          if errno == ENOENT { throw fanoutSnapshotMutation(childPath) }
          throw FanoutSnapshotFailure(.policyBlocked, "fanout artifact root contains unreadable entries", path: childPath)
        }
        entryCount += 1
        let marker: String
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
          directories += 1; marker = "d"; subdirectories.append(childPath)
        case mode_t(S_IFREG):
          files += 1; regularFileBytes += Int64(status.st_size); marker = "f"
        case mode_t(S_IFLNK):
          symlinks += 1; marker = "l"
        default:
          other += 1; marker = "s"
        }
        let relative = childPath.dropFirst(path.count + 1)
        hasher.update(data: Data("\(marker) \(Int64(status.st_size)) \(relative)\n".utf8))
      }
      pending.append(contentsOf: subdirectories.reversed())
    }
    return .object([
      "kind": .string("directory"), "mode": .integer(Int64(mode & 0o7777)),
      "entryCount": .integer(Int64(entryCount)), "regularFileBytes": .integer(regularFileBytes),
      "files": .integer(Int64(files)), "directories": .integer(Int64(directories)),
      "symlinks": .integer(Int64(symlinks)), "other": .integer(Int64(other)),
      "membershipSha256": .string(fanoutHex(hasher.finalize())),
      "scanTruncated": .bool(truncated), "scanLimit": .integer(Int64(Self.artifactEntryScanLimit))
    ])
  }
}

struct WorkflowFanoutChangeContext: Sendable {
  var evidence: WorkflowFanoutChangeEvidence
  var branchId: String
  var paths: [String]
  var artifactRoots: [String] = []
}

/// Structured snapshot rejection. Converted to `AdapterExecutionError` at the
/// actor boundary with every known field appended to the message, so a branch
/// failure reason and the join evidence both identify what was rejected
/// without reproducing any file content.
struct FanoutSnapshotFailure: Error, Sendable {
  var code: AdapterExecutionErrorCode
  var reason: String
  var selection: String?
  var root: String?
  var path: String?
  var observed: Int?
  var limit: Int?
  var isRetryable: Bool?

  init(_ code: AdapterExecutionErrorCode, _ reason: String, selection: String? = nil, root: String? = nil,
       path: String? = nil, observed: Int? = nil, limit: Int? = nil, isRetryable: Bool? = nil) {
    self.code = code
    self.reason = reason
    self.selection = selection
    self.root = root
    self.path = path
    self.observed = observed
    self.limit = limit
    self.isRetryable = isRetryable
  }

  func annotated(selection: String, root: String) -> Self {
    var copy = self
    copy.selection = copy.selection ?? selection
    copy.root = copy.root ?? root
    return copy
  }

  func diagnostic(branchId: String?, stepId: String, phase explicitPhase: String? = nil) -> JSONObject {
    let (derivedPhase, node) = fanoutCapturePhase(stepId)
    var diagnostic: JSONObject = [
      "reason": .string(reason), "code": .string(code.rawValue),
      "stepId": .string(stepId), "phase": .string(explicitPhase ?? derivedPhase)
    ]
    if let branchId { diagnostic["branchId"] = .string(branchId) }
    if let node { diagnostic["node"] = .string(node) }
    if let selection { diagnostic["selection"] = .string(selection) }
    if let root { diagnostic["root"] = .string(root) }
    if let path { diagnostic["path"] = .string(path) }
    if let observed { diagnostic["observed"] = .integer(Int64(observed)) }
    if let limit { diagnostic["limit"] = .integer(Int64(limit)) }
    if let isRetryable { diagnostic["retryable"] = .bool(isRetryable) }
    return diagnostic
  }

  func adapterError(_ diagnostic: JSONObject) -> AdapterExecutionError {
    var fields: [String] = []
    for key in ["branchId", "node", "phase", "selection", "root", "path", "observed", "limit"] {
      switch diagnostic[key] {
      case let .string(value)?: fields.append("\(key == "branchId" ? "branch" : key)=\(value)")
      case let .integer(value)?: fields.append("\(key)=\(value)")
      default: continue
      }
    }
    let message = fields.isEmpty ? reason : "\(reason) [\(fields.joined(separator: " "))]"
    return AdapterExecutionError(code, message, isRetryable: isRetryable)
  }
}

private func fanoutCapturePhase(_ stepId: String) -> (String, String?) {
  if stepId.hasPrefix("before:") { return ("before-node", String(stepId.dropFirst("before:".count))) }
  if stepId.hasPrefix("after:") { return ("after-node", String(stepId.dropFirst("after:".count))) }
  return (stepId, nil)
}

private func fanoutStrings(_ values: [JSONValue]) -> [String] {
  values.compactMap { value -> String? in
    guard case let .string(path) = value else { return nil }
    return path
  }
}

private func fanoutHex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
  digest.map { String(format: "%02x", $0) }.joined()
}

private func rejectFanoutSymlinkComponents(root: URL, path: String) throws {
  var current = root
  var relative: [String] = []
  for component in path.split(separator: "/") {
    current.appendPathComponent(String(component))
    relative.append(String(component))
    if let status = try fanoutStatus(current, missingAllowed: true, path: relative.joined(separator: "/")),
       status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
      throw FanoutSnapshotFailure(.policyBlocked, "fanout change tracking refuses symlink ancestry",
                                  path: relative.joined(separator: "/"))
    }
  }
}

private func validateFanoutPath(_ path: String) throws {
  let parts = path.split(separator: "/", omittingEmptySubsequences: false)
  guard !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".git"),
        !parts.contains(""), !parts.contains("."), !path.contains("\0") else {
    throw FanoutSnapshotFailure(.policyBlocked, "unsafe fanout change tracking path", path: path)
  }
}

private func fanoutStatus(_ url: URL, missingAllowed: Bool, path: String) throws -> stat? {
  var status = stat()
  if lstat(url.path, &status) == 0 { return status }
  if errno == ENOENT && missingAllowed { return nil }
  if errno == ENOENT { throw fanoutSnapshotMutation(path) }
  if errno == EACCES || errno == EPERM {
    throw FanoutSnapshotFailure(.policyBlocked, "fanout snapshot refuses unreadable entries", path: path)
  }
  throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

private func fanoutSameEntry(_ before: stat, _ after: stat?) -> Bool {
  guard let after else { return false }
  return before.st_ino == after.st_ino && before.st_dev == after.st_dev &&
    before.st_mode == after.st_mode && before.st_size == after.st_size &&
    before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
    before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
}

private func fanoutOpenRegularFile(_ url: URL, expected: stat, path: String) throws -> (Int32, FileHandle) {
  let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
  guard descriptor >= 0 else {
    if errno == ELOOP {
      throw FanoutSnapshotFailure(.policyBlocked, "fanout snapshot refuses symlink entries", path: path)
    }
    throw fanoutSnapshotMutation(path)
  }
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  var opened = stat()
  guard fstat(descriptor, &opened) == 0, fanoutSameEntry(expected, opened),
        opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
    try? handle.close()
    throw fanoutSnapshotMutation(path)
  }
  return (descriptor, handle)
}

private func fanoutReadFile(_ url: URL, expected: stat, maximum: Int, path: String) throws -> Data {
  let (descriptor, handle) = try fanoutOpenRegularFile(url, expected: expected, path: path)
  defer { try? handle.close() }
  var bytes = Data()
  while bytes.count <= maximum {
    let chunk = try handle.read(upToCount: maximum + 1 - bytes.count) ?? Data()
    if chunk.isEmpty { break }
    bytes.append(chunk)
  }
  var afterRead = stat()
  guard fstat(descriptor, &afterRead) == 0, fanoutSameEntry(expected, afterRead) else {
    throw fanoutSnapshotMutation(path)
  }
  return bytes
}

private func fanoutDigestFile(_ url: URL, expected: stat, path: String) throws -> String {
  let (descriptor, handle) = try fanoutOpenRegularFile(url, expected: expected, path: path)
  defer { try? handle.close() }
  var hasher = SHA256()
  var total: Int64 = 0
  while true {
    let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
    if chunk.isEmpty { break }
    hasher.update(data: chunk)
    total += Int64(chunk.count)
  }
  var afterRead = stat()
  guard fstat(descriptor, &afterRead) == 0, fanoutSameEntry(expected, afterRead), total == Int64(expected.st_size) else {
    throw fanoutSnapshotMutation(path)
  }
  return fanoutHex(hasher.finalize())
}

private func fanoutSnapshotMutation(_ path: String) -> FanoutSnapshotFailure {
  FanoutSnapshotFailure(.providerError, "entry changed during fanout snapshot; retry", path: path, isRetryable: true)
}

private func entryKind(_ value: JSONValue?) -> String {
  guard case let .object(entry)? = value, case let .string(kind)? = entry["kind"] else { return "missing" }
  return kind
}

private func entryChildren(_ value: JSONValue?) -> JSONValue? {
  entryField(value, "children")
}

private func entryField(_ value: JSONValue?, _ field: String) -> JSONValue? {
  guard case let .object(entry)? = value else { return nil }
  return entry[field]
}
