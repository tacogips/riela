import Crypto
import Darwin
import Foundation

/// Cooperative observation at node boundaries, not a write lock. Evidence
/// preserves observed bytes; semantic loss inside one node still needs review.
actor WorkflowFanoutChangeEvidence {
  let root: URL
  let directory: URL
  private var records: [String: [JSONObject]] = [:]
  private var observationHook: (@Sendable (String) throws -> Void)?

  func setObservationHook(_ hook: (@Sendable (String) throws -> Void)?) {
    observationHook = hook
  }

  init(root: URL) throws {
    self.root = root.resolvingSymlinksInPath().standardizedFileURL
    let tmp = self.root.appendingPathComponent("tmp/riela-fanout")
    try rejectFanoutSymlinkComponents(root: self.root, path: "tmp/riela-fanout")
    guard tmp.resolvingSymlinksInPath().path.hasPrefix(self.root.path + "/") else {
      throw AdapterExecutionError(.policyBlocked, "fanout evidence directory escapes workspace")
    }
    self.directory = tmp.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
  }

  func capture(branchId: String, paths: [String], stepId: String) throws -> String {
    let roots = Array(Set(paths)).sorted()
    let files = try snapshot(paths: paths)
    let name = UUID().uuidString + ".json"
    let url = directory.appendingPathComponent(name)
    let record: JSONObject = ["branchId": .string(branchId), "stepId": .string(stepId),
                              "roots": .array(roots.map(JSONValue.string)),
                              "files": .object(files), "artifactPath": .string(url.path)]
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

  func reduce() throws -> JSONObject {
    var observations: [JSONValue] = [], artifacts: [JSONValue] = []
    for branchId in records.keys.sorted() {
      for record in records[branchId] ?? [] {
        guard case let .object(files)? = record["files"] else { continue }
        artifacts.append(record["artifactPath"] ?? .null)
        guard case let .array(rootValues)? = record["roots"] else { continue }
        let roots = rootValues.compactMap { value -> String? in
          guard case let .string(path) = value else { return nil }
          return path
        }
        let current = try snapshot(paths: roots)
        for path in Set(files.keys).union(current.keys).sorted() {
          let old = files[path], new = current[path]
          let oldKind = entryKind(old), newKind = entryKind(new)
          let reason: String
          if oldKind == newKind {
            if old == new { continue }
            reason = oldKind == "directory" && entryChildren(old) != entryChildren(new)
              ? "directory-membership-drift" : "content-or-mode-drift"
          } else if oldKind == "missing" {
            reason = "entry-added"
          } else if newKind == "missing" {
            reason = "entry-removed"
          } else {
            reason = "entry-kind-drift"
          }
          observations.append(.object([
            "branchId": .string(branchId), "path": .string(path),
            "snapshotPath": record["artifactPath"] ?? .null,
            "stepId": record["stepId"] ?? .null,
            "reason": .string(reason)
          ]))
        }
      }
    }
    return ["artifactPaths": .array(artifacts), "observations": .array(observations),
            "hasDrift": .bool(!observations.isEmpty), "requiresSemanticReview": .bool(true),
            "observationBoundary": .string("workflow-node")]
  }

  private func snapshot(paths: [String]) throws -> JSONObject {
    guard !paths.isEmpty, paths.count <= 512 else {
      throw AdapterExecutionError(.policyBlocked, "fanout change tracking requires 1...512 paths")
    }
    var result: JSONObject = [:], total = 0
    for path in Set(paths).sorted() {
      try validateFanoutPath(path)
      let evidencePath = directory.path.replacingOccurrences(of: root.path + "/", with: "")
      if path == evidencePath || evidencePath.hasPrefix(path + "/") {
        throw AdapterExecutionError(.policyBlocked, "fanout selection contains its evidence directory")
      }
      try snapshotEntry(path, declared: true, result: &result, total: &total)
    }
    return result
  }

  private func snapshotEntry(_ path: String, declared: Bool, result: inout JSONObject, total: inout Int) throws {
    if result[path] != nil { return }
    try validateFanoutPath(path)
    guard result.count < 512 else { throw AdapterExecutionError(.policyBlocked, "fanout snapshot exceeds 512 entries") }
    try rejectFanoutSymlinkComponents(root: root, path: path)
    let url = root.appendingPathComponent(path)
    guard let initial = try fanoutStatus(url, missingAllowed: declared) else {
      result[path] = .object(["kind": .string("missing")]); return
    }
    let kind = initial.st_mode & mode_t(S_IFMT)
    guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) else {
      throw AdapterExecutionError(.policyBlocked, "fanout snapshot refuses special entries")
    }
    guard access(url.path, kind == mode_t(S_IFDIR) ? R_OK | X_OK : R_OK) == 0 else {
      throw AdapterExecutionError(.policyBlocked, "fanout snapshot refuses unreadable entries")
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
      let after = try fanoutStatus(url, missingAllowed: false)
      guard fanoutSameEntry(initial, after) else { throw fanoutSnapshotMutation() }
      let finalChildren = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
      guard children == finalChildren else {
        throw fanoutSnapshotMutation()
      }
      try rejectFanoutSymlinkComponents(root: root, path: path)
    } else {
      let size = Int(initial.st_size)
      guard size <= 8_000_000 else {
        throw AdapterExecutionError(.policyBlocked, "fanout change tracking requires files up to 8 MB")
      }
      guard total <= 64_000_000 - size else {
        throw AdapterExecutionError(.policyBlocked, "fanout snapshot exceeds 64 MB")
      }
      let bytes = try fanoutReadFile(url, expected: initial, maximum: size)
      try observationHook?("file:\(path)")
      try rejectFanoutSymlinkComponents(root: root, path: path)
      let after = try fanoutStatus(url, missingAllowed: false)
      guard bytes.count == size, bytes.count <= 8_000_000,
            fanoutSameEntry(initial, after) else {
        throw fanoutSnapshotMutation()
      }
      try rejectFanoutSymlinkComponents(root: root, path: path)
      total += bytes.count
      result[path] = .object([
        "kind": .string("file"), "sha256": .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()),
        "mode": .integer(Int64(initial.st_mode & 0o7777)),
        "contentBase64": .string(bytes.base64EncodedString())
      ])
    }
  }
}

struct WorkflowFanoutChangeContext: Sendable {
  var evidence: WorkflowFanoutChangeEvidence
  var branchId: String
  var paths: [String]
}

private func rejectFanoutSymlinkComponents(root: URL, path: String) throws {
  var current = root
  for component in path.split(separator: "/") {
    current.appendPathComponent(String(component))
    if let status = try fanoutStatus(current, missingAllowed: true),
       status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
      throw AdapterExecutionError(.policyBlocked, "fanout change tracking refuses symlink ancestry")
    }
  }
}

private func validateFanoutPath(_ path: String) throws {
  let parts = path.split(separator: "/", omittingEmptySubsequences: false)
  guard !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".git"),
        !parts.contains(""), !parts.contains("."), !path.contains("\0") else {
    throw AdapterExecutionError(.policyBlocked, "unsafe fanout change tracking path")
  }
}

private func fanoutStatus(_ url: URL, missingAllowed: Bool) throws -> stat? {
  var status = stat()
  if lstat(url.path, &status) == 0 { return status }
  if errno == ENOENT && missingAllowed { return nil }
  if errno == ENOENT { throw fanoutSnapshotMutation() }
  if errno == EACCES || errno == EPERM {
    throw AdapterExecutionError(.policyBlocked, "fanout snapshot refuses unreadable entries")
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

private func fanoutReadFile(_ url: URL, expected: stat, maximum: Int) throws -> Data {
  let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
  guard descriptor >= 0 else {
    if errno == ELOOP { throw AdapterExecutionError(.policyBlocked, "fanout snapshot refuses symlink entries") }
    throw fanoutSnapshotMutation()
  }
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  defer { try? handle.close() }
  var opened = stat()
  guard fstat(descriptor, &opened) == 0, fanoutSameEntry(expected, opened),
        opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
    throw fanoutSnapshotMutation()
  }
  var bytes = Data()
  while bytes.count <= maximum {
    let chunk = try handle.read(upToCount: maximum + 1 - bytes.count) ?? Data()
    if chunk.isEmpty { break }
    bytes.append(chunk)
  }
  var afterRead = stat()
  guard fstat(descriptor, &afterRead) == 0, fanoutSameEntry(expected, afterRead) else {
    throw fanoutSnapshotMutation()
  }
  return bytes
}

private func fanoutSnapshotMutation() -> AdapterExecutionError {
  AdapterExecutionError(.providerError, "entry changed during fanout snapshot; retry", isRetryable: true)
}

private func entryKind(_ value: JSONValue?) -> String {
  guard case let .object(entry)? = value, case let .string(kind)? = entry["kind"] else { return "missing" }
  return kind
}

private func entryChildren(_ value: JSONValue?) -> JSONValue? {
  guard case let .object(entry)? = value else { return nil }
  return entry["children"]
}
