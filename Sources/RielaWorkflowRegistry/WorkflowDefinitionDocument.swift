import Foundation
import RielaAddons
import RielaCore

public struct WorkflowDefinitionDocument: Codable, Equatable, Sendable {
  public struct Runtime: Codable, Equatable, Sendable {
    public var workflow: WorkflowDefinition
    public var nodePayloads: [String: AgentNodePayload]
    public var packageManifest: WorkflowPackageManifest?

    public init(workflow: WorkflowDefinition, nodePayloads: [String: AgentNodePayload], packageManifest: WorkflowPackageManifest?) {
      self.workflow = workflow
      self.nodePayloads = nodePayloads
      self.packageManifest = packageManifest
    }
  }

  public var formatVersion: Int
  public var runtime: Runtime
  public var authoredFiles: [String: String]

  public init(formatVersion: Int = 1, runtime: Runtime, authoredFiles: [String: String]) {
    self.formatVersion = formatVersion
    self.runtime = runtime
    self.authoredFiles = authoredFiles
  }

  public static func make(from bundle: ResolvedWorkflowBundle, authoredOverlay: WorkflowAuthoredFileOverlay? = nil) throws -> Self {
    try make(from: bundle, authoredOverlay: authoredOverlay, omitUnreadable: false)
  }

  private static func make(
    from bundle: ResolvedWorkflowBundle,
    authoredOverlay: WorkflowAuthoredFileOverlay?,
    omitUnreadable: Bool
  ) throws -> Self {
    let root = URL(fileURLWithPath: bundle.workflowDirectory, isDirectory: true)
    var files: [String: String] = [:]
    func read(_ path: String, field: String) throws -> String? {
      let url = field == "promptFile"
        ? try resolvePromptTemplatePath(path, fieldName: field, workflowDirectory: root)
        : try containedAuthoredURL(path, root: root)
      guard FileManager.default.fileExists(atPath: url.path) || authoredOverlay != nil else { return nil }
      if let authoredOverlay {
        guard let text = authoredOverlay.text(at: url, workflowDirectory: root) else {
          throw WorkflowAuthoredFileOverlayError.invalidPath("missing overlay file \(path)")
        }
        return text
      }
      return try String(contentsOf: url, encoding: .utf8)
    }
    guard let workflowText = try read("workflow.json", field: "workflow.json") else {
      throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.appendingPathComponent("workflow.json").path])
    }
    files["workflow.json"] = workflowText
    let isDerivedWorkflow: Bool
    do {
      isDerivedWorkflow = try WorkflowInheritanceDeclaration.parse(data: Data(workflowText.utf8)) != nil
    } catch {
      if omitUnreadable {
        isDerivedWorkflow = false
      } else {
        throw error
      }
    }
    if !isDerivedWorkflow {
      for node in bundle.workflow.nodeRegistry where node.nodeRef == nil {
        guard let nodeFile = node.nodeFile else { continue }
        let nodeText: String?
        do { nodeText = try read(nodeFile, field: "nodeFile") } catch {
          if omitUnreadable { continue }
          throw error
        }
        guard let nodeText else { continue }
        files[nodeFile] = nodeText
        let payload: AgentNodePayload
        do { payload = try JSONDecoder().decode(AgentNodePayload.self, from: Data(nodeText.utf8)) } catch {
          if omitUnreadable { continue }
          throw error
        }
        for path in promptFilePaths(payload) {
          do {
            if let text = try read(path, field: "promptFile") { files[path] = text }
          } catch {
            if !omitUnreadable { throw error }
          }
        }
      }
    }
    if let authoredOverlay {
      let expected = Set(authoredOverlay.files.keys)
      let normalizedFiles = try Set(files.keys.map(WorkflowAuthoredFileOverlay.normalize))
      guard normalizedFiles.count == files.count, normalizedFiles == expected else {
        throw WorkflowAuthoredFileOverlayError.invalidPath("authored overlay file set does not match workflow references")
      }
    }
    return Self(runtime: Runtime(
      workflow: bundle.workflow,
      nodePayloads: bundle.nodePayloads,
      packageManifest: bundle.packageManifest
    ), authoredFiles: files)
  }

  static func containedAuthoredURL(_ path: String, root: URL) throws -> URL {
    let normalized = try WorkflowAuthoredFileOverlay.normalize(path)
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    let candidate = base.appendingPathComponent(normalized).standardizedFileURL
    let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
    let isContained = base.path == "/"
      ? resolved.path.hasPrefix("/") && resolved.path != base.path
      : resolved.path.hasPrefix(base.path + "/")
    guard isContained else { throw WorkflowAuthoredFileOverlayError.invalidPath(path) }
    return resolved
  }

  public func canonicalData() throws -> Data { try JSONCanonical.encode(self) }
  public func digest() throws -> String { JSONCanonical.sha256Hex(try canonicalData()) }
  public static func decode(_ data: Data) throws -> Self { try JSONCanonical.decoder().decode(Self.self, from: data) }

  public func resolvedBundle(head: WorkflowDefinitionHead?, version: WorkflowDefinitionVersion, storeRoot: String) -> ResolvedWorkflowBundle {
    let scope = WorkflowScope(rawValue: version.sourceScope) ?? .direct
    let source = WorkflowDefinitionSource(
      kind: .store,
      workflowName: version.workflowName,
      versionId: version.versionId,
      storeRoot: URL(fileURLWithPath: storeRoot).standardizedFileURL.path,
      digest: version.documentDigest,
      sourcePath: version.sourceDirectory,
      sourceScope: version.sourceScope
    )
    return ResolvedWorkflowBundle(
      workflow: runtime.workflow,
      nodePayloads: runtime.nodePayloads,
      sourceScope: scope,
      workflowDirectory: version.sourceDirectory,
      packageManifest: runtime.packageManifest,
      provenance: WorkflowProvenance(rawValue: version.provenance) ?? .immutable,
      definitionSource: source
    )
  }

  public static func fileDefinitionSource(for bundle: ResolvedWorkflowBundle, workflowName: String) -> WorkflowDefinitionSource {
    let digest: String
    if let document = try? make(from: bundle, authoredOverlay: nil, omitUnreadable: true), let value = try? document.digest() {
      digest = value
    } else if let runtimeData = try? JSONCanonical.encode(Runtime(
      workflow: bundle.workflow,
      nodePayloads: bundle.nodePayloads,
      packageManifest: bundle.packageManifest
    )) {
      digest = JSONCanonical.sha256Hex(runtimeData)
    } else {
      digest = JSONCanonical.sha256Hex(Data())
    }
    return WorkflowDefinitionSource(
      kind: .file,
      workflowName: workflowName,
      digest: digest,
      sourcePath: bundle.workflowDirectory,
      sourceScope: bundle.sourceScope.rawValue
    )
  }

  public func authoredView() throws -> JSONValue {
    var values: [String: JSONValue] = [:]
    for (path, text) in authoredFiles {
      values[path] = path.hasSuffix(".json") ? try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) : .string(text)
    }
    return .object(values)
  }

  public static func authoredFiles(fromView view: JSONValue, previous: [String: String]) throws -> [String: String] {
    guard case let .object(values) = view else { throw WorkflowDefinitionServiceError(code: .invalidPatch, message: "authored view must be an object") }
    var files: [String: String] = [:]
    for (path, value) in values {
      if let oldText = previous[path], path.hasSuffix(".json"),
         let oldValue = try? JSONDecoder().decode(JSONValue.self, from: Data(oldText.utf8)), oldValue == value {
        files[path] = oldText
      } else if path.hasSuffix(".json") {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        let formatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        files[path] = (String(data: formatted, encoding: .utf8) ?? "") + "\n"
      } else if case let .string(text) = value {
        files[path] = text
      } else {
        throw WorkflowDefinitionServiceError(code: .invalidPatch, message: "authored file \(path) must be a string")
      }
    }
    return files
  }

  private static func promptFilePaths(_ payload: AgentNodePayload) -> [String] {
    var paths = [payload.promptTemplateFile, payload.systemPromptTemplateFile, payload.sessionStartPromptTemplateFile].compactMap { $0 }
    for variant in payload.promptVariants?.values ?? [String: NodePromptVariant]().values {
      paths += [variant.promptTemplateFile, variant.systemPromptTemplateFile, variant.sessionStartPromptTemplateFile].compactMap { $0 }
    }
    return paths
  }
}
