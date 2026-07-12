import Foundation
import RielaCore

enum WorkflowSharedNodeDependencyInventory {
  static let virtualPrefix = ".riela-shared-nodes"

  static func files(
    for target: WorkflowBundleIdentity,
    primaryFiles: [WorkflowOwnedFile]
  ) throws -> [WorkflowOwnedFile] {
    guard target.sourceKind == .authoredWorkflow else { return [] }
    let workflowDirectory = URL(fileURLWithPath: target.workflowDirectory, isDirectory: true).standardizedFileURL
    let dependencyRoot = target.sourceScope == .direct
      ? URL(fileURLWithPath: target.ownershipRoot, isDirectory: true).standardizedFileURL
      : workflowDirectory.deletingLastPathComponent().standardizedFileURL
    let workflowPath = String(
      workflowDirectory.appendingPathComponent("workflow.json").path.dropFirst(target.ownershipRoot.count + 1)
    )
    guard let workflowFile = primaryFiles.first(where: { $0.metadata.relativePath == workflowPath }) else {
      throw CLIUsageError("workflow inventory is missing its declaration while resolving shared nodes")
    }
    let declaration = try jsonObject(workflowFile.bytes, label: "workflow.json")
    let references = nodeReferences(in: declaration)
    guard !references.isEmpty else { return [] }
    var collector = Collector(root: dependencyRoot)
    for reference in references {
      try collector.collect(reference, stack: [])
    }
    return collector.files.values.sorted {
      $0.metadata.relativePath.utf8.lexicographicallyPrecedes($1.metadata.relativePath.utf8)
    }
  }

  static func isDependencyPath(_ path: String) -> Bool {
    path.hasPrefix(virtualPrefix + "/")
  }

  static func dependencyLocation(for virtualPath: String) throws -> (workflowId: String, relativePath: String) {
    try WorkflowHistoryCanonicalCoding.validateRelativePath(virtualPath)
    let components = virtualPath.split(separator: "/").map(String.init)
    guard components.count >= 3, components[0] == virtualPrefix else {
      throw CLIUsageError("invalid shared-node dependency inventory path")
    }
    return (components[1], components.dropFirst(2).joined(separator: "/"))
  }

  private struct Reference: Hashable {
    var workflowId: String
    var nodeId: String
  }

  private struct Collector {
    var root: URL
    var files: [String: WorkflowOwnedFile] = [:]

    mutating func collect(_ reference: Reference, stack: [Reference]) throws {
      try WorkflowHistoryCanonicalCoding.validateSafeComponent(reference.workflowId)
      try WorkflowHistoryCanonicalCoding.validateSafeComponent(reference.nodeId)
      guard !stack.contains(reference) else {
        throw CLIUsageError("cyclic shared-node dependency graph")
      }
      let directory = root.appendingPathComponent(reference.workflowId, isDirectory: true).standardizedFileURL
      let workflowRead = try read("workflow.json", workflowId: reference.workflowId, directory: directory)
      let declaration = try jsonObject(workflowRead.bytes, label: "shared workflow \(reference.workflowId)")
      guard let nodes = declaration["nodes"] as? [[String: Any]],
            let node = nodes.first(where: { $0["id"] as? String == reference.nodeId }) else {
        throw CLIUsageError("shared node '\(reference.nodeId)' is missing from workflow '\(reference.workflowId)'")
      }
      if let nested = WorkflowSharedNodeDependencyInventory.reference(from: node["nodeRef"]) {
        try collect(nested, stack: stack + [reference])
      }
      if let nodeFile = node["nodeFile"] as? String {
        let payload = try read(nodeFile, workflowId: reference.workflowId, directory: directory)
        if let payloadObject = try? JSONSerialization.jsonObject(with: payload.bytes) {
          for path in fileReferences(in: payloadObject) {
            _ = try read(path, workflowId: reference.workflowId, directory: directory)
          }
        }
      }
    }

    @discardableResult
    private mutating func read(
      _ relativePath: String,
      workflowId: String,
      directory: URL
    ) throws -> WorkflowDescriptorRelativeRead {
      try WorkflowHistoryCanonicalCoding.validateRelativePath(relativePath)
      let url = directory.appendingPathComponent(relativePath).standardizedFileURL
      guard url.path.hasPrefix(directory.path + "/") else {
        throw CLIUsageError("shared-node dependency escapes its workflow directory")
      }
      let read = try WorkflowDescriptorRelativeReader.read(url, within: root)
      let virtualPath = "\(WorkflowSharedNodeDependencyInventory.virtualPrefix)/\(workflowId)/\(relativePath)"
      let metadata = WorkflowBundleSnapshotFile(
        relativePath: virtualPath,
        contentDigest: WorkflowHistoryCanonicalCoding.sha256(read.bytes),
        byteCount: read.bytes.count,
        artifactKind: .sharedNode,
        executable: read.executable
      )
      let file = WorkflowOwnedFile(metadata: metadata, url: url, bytes: read.bytes, readRoot: root)
      if let existing = files[virtualPath], existing.metadata != metadata {
        throw CLIUsageError("shared-node dependency changed during inventory: \(virtualPath)")
      }
      files[virtualPath] = file
      return read
    }
  }

  private static func jsonObject(_ bytes: Data, label: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw CLIUsageError("\(label) must be a JSON object")
    }
    return object
  }

  private static func reference(from value: Any?) -> Reference? {
    guard let object = value as? [String: Any],
          let workflowId = object["workflowId"] as? String,
          let nodeId = object["nodeId"] as? String else { return nil }
    return Reference(workflowId: workflowId, nodeId: nodeId)
  }

  private static func nodeReferences(in value: Any) -> [Reference] {
    var references: [Reference] = []
    walk(value) { key, child in
      if key == "nodeRef", let reference = reference(from: child) { references.append(reference) }
    }
    return references
  }

  private static func fileReferences(in value: Any) -> [String] {
    let keys: Set<String> = [
      "promptTemplateFile", "systemPromptTemplateFile", "sessionStartPromptTemplateFile",
      "scriptPath", "containerfilePath", "sourcePath"
    ]
    var paths = Set<String>()
    walk(value) { key, child in
      if keys.contains(key), let path = child as? String { paths.insert(path) }
    }
    return paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }

  private static func walk(_ value: Any, visit: (String, Any) -> Void) {
    if let object = value as? [String: Any] {
      for (key, child) in object {
        visit(key, child)
        walk(child, visit: visit)
      }
    } else if let array = value as? [Any] {
      for child in array { walk(child, visit: visit) }
    }
  }
}
