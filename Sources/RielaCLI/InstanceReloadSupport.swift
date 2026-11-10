import Foundation
import RielaAppSupport
import RielaCore
import RielaEvents
import RielaWorkflowRegistry

public enum InstanceReloadSupport {
  private struct EventConfig: Decodable {
    var sources: [EventSourceContract]
    var bindings: [EventBindingContract]
  }

  public static func validateCandidate(
    workflowDirectory: String, eventRoot: String?, expectedWorkflowId: String,
    nodePatches: [String: WorkflowInstanceNodePatch], workingDirectory: String
  ) throws -> (bundle: ResolvedWorkflowBundle, triggerDefaultsFingerprint: String, eventRootDigest: String) {
    let options = WorkflowResolutionOptions(workflowName: expectedWorkflowId, workflowDefinitionDir: workflowDirectory, workingDirectory: workingDirectory)
    var bundle: ResolvedWorkflowBundle
    do {
      bundle = try FileSystemWorkflowBundleResolver().resolve(options)
    } catch {
      let path = URL(fileURLWithPath: workflowDirectory).appendingPathComponent("workflow.json")
      if case WorkflowResolutionError.notFound = error,
         let data = try? Data(contentsOf: path),
         let definition = validateAuthoredWorkflowData(data).workflow,
         definition.workflowId != expectedWorkflowId {
        throw RielaAppInstanceReloadError(code: .workflowIdMismatch, message: "Workflow identifier does not match")
      }
      throw RielaAppInstanceReloadError(code: .invalidWorkflowDefinition, message: "Invalid workflow definition")
    }
    guard bundle.workflow.workflowId == expectedWorkflowId else {
      throw RielaAppInstanceReloadError(code: .workflowIdMismatch, message: "Workflow identifier does not match")
    }
    do {
      bundle.nodePayloads = try WorkflowInstanceResolver.resolve(
        workflowId: expectedWorkflowId, base: nil, runNodePatch: nodePatches, nodePayloads: bundle.nodePayloads
      ).nodePayloads
    } catch {
      throw RielaAppInstanceReloadError(code: .invalidWorkflowDefinition, message: "Invalid node patches")
    }
    do {
      if let eventRoot {
        let root = URL(fileURLWithPath: eventRoot, isDirectory: true)
        let configURL = root.appendingPathComponent("events.json")
        let config: EventConfig
        if FileManager.default.fileExists(atPath: configURL.path) {
          config = try JSONDecoder().decode(EventConfig.self, from: Data(contentsOf: configURL))
        } else {
          config = try EventConfig(sources: decodeDirectory(root.appendingPathComponent("sources")),
                                   bindings: decodeDirectory(root.appendingPathComponent("bindings")))
        }
        let diagnostics = EventContractValidator.validate(sources: config.sources, bindings: config.bindings)
          + fileChangeSourceDiagnostics(eventRoot: root)
        guard diagnostics.isEmpty else { throw RielaAppInstanceReloadError(code: .invalidEventBindings) }
      }
      return (bundle, RielaAppInstanceReloadFingerprint.triggerDefaultsFingerprint(bundle.workflow.triggerDefaults),
              try RielaAppInstanceReloadFingerprint.eventRootDigest(eventRoot: eventRoot))
    } catch {
      throw RielaAppInstanceReloadError(code: .invalidEventBindings, message: "Invalid event bindings")
    }
  }

  private static func decodeDirectory<T: Decodable>(_ directory: URL) throws -> [T] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { try JSONDecoder().decode(T.self, from: Data(contentsOf: $0)) }
  }

  public static func importDefinition(
    storeRoot: String, workflowDirectory: String, workflowId: String, reason: String, workingDirectory: String
  ) throws -> RielaAppInstanceReloadResponse.Definition {
    let service = WorkflowDefinitionService(storeRoot: storeRoot, fileResolver: FileSystemWorkflowBundleResolver())
    let options = WorkflowResolutionOptions(workflowName: workflowId, workflowDefinitionDir: workflowDirectory, workingDirectory: workingDirectory)
    do {
      _ = try FileSystemWorkflowBundleResolver().resolve(options)
    } catch {
      throw RielaAppInstanceReloadError(code: .invalidWorkflowDefinition, message: "Invalid workflow definition")
    }
    return try importDefinition(service: service, workflowId: workflowId) { force in
      try service.importDefinition(resolution: options, force: force, reason: reason, evidence: [], actor: .init(kind: .api, id: "instance-reload"))
    }
  }

  static func importDefinition(service: WorkflowDefinitionService, workflowId: String,
                               operation: (Bool) throws -> WorkflowDefinitionImportResult) throws -> RielaAppInstanceReloadResponse.Definition {
    do {
      var result = try operation(false)
      if result.outcome == .differs {
        result = try operation(true)
      }
      let version = try result.version ?? service.show(workflowName: workflowId, versionId: nil).version
      return .init(outcome: result.outcome.rawValue, versionId: version.versionId, digest: version.documentDigest)
    } catch let error as WorkflowDefinitionServiceError {
      let code: RielaAppInstanceReloadCode = error.code == .definitionConflict || error.code == .definitionNotRegistered ? .definitionConflict : .invalidWorkflowDefinition
      throw RielaAppInstanceReloadError(code: code, message: "Definition import failed")
    } catch let error as WorkflowDefinitionStoreError {
      let code: RielaAppInstanceReloadCode = error.code == .staleHead || error.code == .headMissing ? .definitionConflict : .definitionStoreFailure
      throw RielaAppInstanceReloadError(code: code, message: "Definition import failed")
    } catch is WorkflowResolutionError {
      throw RielaAppInstanceReloadError(code: .invalidWorkflowDefinition, message: "Invalid workflow definition")
    } catch {
      throw RielaAppInstanceReloadError(code: .definitionStoreFailure, message: "Definition import failed")
    }
  }

  public static func installedTriggerDefaultsFingerprint(
    storeRoot: String, workflowDirectory: String, workflowId: String, workingDirectory: String
  ) -> String? {
    let resolver = DefinitionStoreWorkflowBundleResolver(inner: FileSystemWorkflowBundleResolver(), sessionStore: storeRoot,
      actor: .init(kind: .cli, id: "events-serve"), mode: .lookupOnly)
    let options = WorkflowResolutionOptions(workflowName: workflowId, workflowDefinitionDir: workflowDirectory, workingDirectory: workingDirectory)
    guard let bundle = try? resolver.resolve(options) else { return nil }
    return RielaAppInstanceReloadFingerprint.triggerDefaultsFingerprint(bundle.workflow.triggerDefaults)
  }

  public static func startRecord(candidateDirectory: String, eventRoot: String?, storeRoot: String,
                                 workflowId: String, workingDirectory: String) -> RielaAppInstanceStartRecord? {
    guard let fingerprint = installedTriggerDefaultsFingerprint(storeRoot: storeRoot, workflowDirectory: candidateDirectory,
                                                                  workflowId: workflowId, workingDirectory: workingDirectory),
          let digest = try? RielaAppInstanceReloadFingerprint.eventRootDigest(eventRoot: eventRoot) else { return nil }
    return .init(workflowDirectory: candidateDirectory, eventRoot: eventRoot, eventRootDigest: digest, triggerDefaultsFingerprint: fingerprint)
  }
}
