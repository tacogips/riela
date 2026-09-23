import Crypto
import Foundation

/// Cooperative observation at node boundaries, not a write lock. Evidence
/// preserves observed bytes; semantic loss inside one node still needs review.
actor WorkflowFanoutChangeEvidence {
  let root: URL
  let directory: URL
  private var records: [String: [JSONObject]] = [:]

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
    let files = try snapshot(paths: paths)
    let name = UUID().uuidString + ".json"
    let url = directory.appendingPathComponent(name)
    let record: JSONObject = ["branchId": .string(branchId), "stepId": .string(stepId),
                              "files": .object(files), "artifactPath": .string(url.path)]
    let data = try JSONEncoder().encode(record)
    try data.write(to: url, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    records[branchId, default: []].append(record)
    return url.path
  }

  func reduce() throws -> JSONObject {
    var observations: [JSONValue] = [], artifacts: [JSONValue] = []
    for branchId in records.keys.sorted() {
      for record in records[branchId] ?? [] {
        guard case let .object(files)? = record["files"] else { continue }
        artifacts.append(record["artifactPath"] ?? .null)
        let current = try snapshot(paths: Array(files.keys))
        for path in files.keys.sorted() where files[path] != current[path] {
          observations.append(.object([
            "branchId": .string(branchId), "path": .string(path),
            "snapshotPath": record["artifactPath"] ?? .null,
            "stepId": record["stepId"] ?? .null,
            "reason": .string("content-or-mode-drift")
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
      throw AdapterExecutionError(.policyBlocked, "fanout change tracking requires 1...512 exact file paths")
    }
    var result: JSONObject = [:], total = 0
    for path in Set(paths).sorted() {
      let parts = path.split(separator: "/", omittingEmptySubsequences: false)
      guard !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".git"),
            !parts.contains(""), !parts.contains("."), !path.contains("\0") else {
        throw AdapterExecutionError(.policyBlocked, "unsafe fanout change tracking path")
      }
      let url = root.appendingPathComponent(path)
      try rejectFanoutSymlinkComponents(root: root, path: path)
      guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
        throw AdapterExecutionError(.policyBlocked, "fanout change tracking refuses symlink paths")
      }
      let before: [FileAttributeKey: Any]
      do {
        before = try FileManager.default.attributesOfItem(atPath: url.path)
      } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
        result[path] = .object(["kind": .string("missing")]); continue
      }
      guard before[.type] as? FileAttributeType == .typeRegular,
            let size = before[.size] as? NSNumber, size.intValue <= 8_000_000 else {
        throw AdapterExecutionError(.policyBlocked, "fanout change tracking requires regular files up to 8 MB")
      }
      total += size.intValue
      guard total <= 64_000_000 else { throw AdapterExecutionError(.policyBlocked, "fanout snapshot exceeds 64 MB") }
      let bytes = try Data(contentsOf: url)
      let after = try FileManager.default.attributesOfItem(atPath: url.path)
      guard before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
            before[.modificationDate] as? Date == after[.modificationDate] as? Date,
            before[.size] as? NSNumber == after[.size] as? NSNumber,
            url.resolvingSymlinksInPath().path == url.path else {
        throw AdapterExecutionError(.providerError, "file changed during fanout snapshot; retry", isRetryable: true)
      }
      result[path] = .object([
        "kind": .string("file"), "sha256": .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()),
        "mode": .integer((after[.posixPermissions] as? NSNumber)?.int64Value ?? 0),
        "contentBase64": .string(bytes.base64EncodedString())
      ])
    }
    return result
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
    if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
       attributes[.type] as? FileAttributeType == .typeSymbolicLink {
      throw AdapterExecutionError(.policyBlocked, "fanout change tracking refuses symlink ancestry")
    }
  }
}
