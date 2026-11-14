import Foundation
import RielaAddons
import RielaCore

public struct WorkflowDefinitionChangeAttribution: Codable, Equatable, Sendable {
  public var operation: WorkflowDefinitionOperation
  public var actor: WorkflowDefinitionActor
  public var reason: String
  public var evidence: [WorkflowDefinitionEvidenceRef]
  public var expectedHeadVersionId: String?
  public var rollbackProposalId: String?

  public init(operation: WorkflowDefinitionOperation, actor: WorkflowDefinitionActor, reason: String,
              evidence: [WorkflowDefinitionEvidenceRef] = [], expectedHeadVersionId: String? = nil,
              rollbackProposalId: String? = nil) {
    self.operation = operation
    self.actor = actor
    self.reason = reason
    self.evidence = evidence
    self.expectedHeadVersionId = expectedHeadVersionId
    self.rollbackProposalId = rollbackProposalId
  }
}

public struct WorkflowDefinitionSyncIntent: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var transactionId: String
  public var workflowName: String
  public var storeRoot: String
  public var sourceDirectory: String
  public var sourceScope: String
  public var documentDigest: String
  public var documentJSON: String
  public var expectedAfterBundleDigest: String?
  public var bundleSnapshotBefore: String?
  public var bundleSnapshotAfter: String?
  public var attribution: WorkflowDefinitionChangeAttribution

  public init(schemaVersion: Int = 1, transactionId: String, workflowName: String, storeRoot: String,
              sourceDirectory: String, sourceScope: String, documentDigest: String, documentJSON: String,
              expectedAfterBundleDigest: String? = nil, bundleSnapshotBefore: String? = nil,
              bundleSnapshotAfter: String? = nil, attribution: WorkflowDefinitionChangeAttribution) {
    self.schemaVersion = schemaVersion
    self.transactionId = transactionId
    self.workflowName = workflowName
    self.storeRoot = storeRoot
    self.sourceDirectory = sourceDirectory
    self.sourceScope = sourceScope
    self.documentDigest = documentDigest
    self.documentJSON = documentJSON
    self.expectedAfterBundleDigest = expectedAfterBundleDigest
    self.bundleSnapshotBefore = bundleSnapshotBefore
    self.bundleSnapshotAfter = bundleSnapshotAfter
    self.attribution = attribution
  }
}

public enum WorkflowDefinitionBaselineOutcome: Equatable, Sendable {
  case captured(versionId: String)
  case headExists(versionId: String)
}

public enum WorkflowDefinitionSyncOutcome: Equatable, Sendable {
  case versionWritten(WorkflowDefinitionVersion, WorkflowDefinitionAuditRecord, overwrittenAuditIds: [String])
  case auditOnly(WorkflowDefinitionAuditRecord)
  case collapsed
  case alreadyComplete
  case noHead
}

public protocol WorkflowDefinitionChangeRecording: Sendable {
  func storeRoot(workflowName: String, sourceScope: WorkflowScope) throws -> String
  func captureBaselineIfAbsent(workflowName: String, liveDirectory: URL, sourceScope: WorkflowScope,
                               transactionId: String, actor: WorkflowDefinitionActor, operation: WorkflowDefinitionOperation,
                               bundleSnapshotBefore: String?) throws -> WorkflowDefinitionBaselineOutcome?
  func prepareIntent(workflowName: String, stagingDirectory: URL, liveDirectory: URL, sourceScope: WorkflowScope,
                     transactionId: String, expectedAfterBundleDigest: String?, bundleSnapshotBefore: String?,
                     bundleSnapshotAfter: String?, attribution: WorkflowDefinitionChangeAttribution) throws -> WorkflowDefinitionSyncIntent
  func sync(_ intent: WorkflowDefinitionSyncIntent) throws -> WorkflowDefinitionSyncOutcome
  func recordDelete(workflowName: String, sourceScope: WorkflowScope, transactionId: String,
                    bundleSnapshotBefore: String?, attribution: WorkflowDefinitionChangeAttribution) throws -> WorkflowDefinitionSyncOutcome
}

public struct WorkflowDefinitionChangeRecorder: WorkflowDefinitionChangeRecording {
  private let sessionStoreRoot: String?
  private let workingDirectory: String
  private let environment: [String: String]
  private let fileResolver: any WorkflowBundleResolving

  public init(sessionStoreRoot: String? = nil, workingDirectory: String = FileManager.default.currentDirectoryPath,
              environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
              fileResolver: any WorkflowBundleResolving) {
    self.sessionStoreRoot = sessionStoreRoot
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.fileResolver = fileResolver
  }

  public func storeRoot(workflowName: String, sourceScope: WorkflowScope) throws -> String {
    let scope: WorkflowScope = sourceScope == .user ? .user : .project
    return try WorkflowDefinitionStoreRoots.rootWithHead(workflowName: workflowName, sessionStore: sessionStoreRoot,
      scope: scope, workingDirectory: workingDirectory, environment: environment)
      ?? WorkflowDefinitionStoreRoots.seedRoot(sessionStore: sessionStoreRoot, sourceScope: sourceScope,
        workingDirectory: workingDirectory, environment: environment)
  }

  private func service(_ root: String) -> WorkflowDefinitionService {
    WorkflowDefinitionService(storeRoot: root, fileResolver: fileResolver)
  }

  public func captureBaselineIfAbsent(workflowName: String, liveDirectory: URL, sourceScope: WorkflowScope,
                                      transactionId: String, actor: WorkflowDefinitionActor, operation: WorkflowDefinitionOperation,
                                      bundleSnapshotBefore: String?) throws -> WorkflowDefinitionBaselineOutcome? {
    try service(storeRoot(workflowName: workflowName, sourceScope: sourceScope)).captureBaselineIfAbsent(
      workflowName: workflowName, liveDirectory: liveDirectory, sourceScope: sourceScope, transactionId: transactionId,
      actor: actor, operation: operation, bundleSnapshotBefore: bundleSnapshotBefore)
  }

  public func prepareIntent(workflowName: String, stagingDirectory: URL, liveDirectory: URL, sourceScope: WorkflowScope,
                            transactionId: String, expectedAfterBundleDigest: String?, bundleSnapshotBefore: String?,
                            bundleSnapshotAfter: String?, attribution: WorkflowDefinitionChangeAttribution) throws -> WorkflowDefinitionSyncIntent {
    let root = try storeRoot(workflowName: workflowName, sourceScope: sourceScope)
    let document = try service(root).committedDocument(workflowName: workflowName,
      stagingDirectory: stagingDirectory, liveDirectory: liveDirectory)
    guard let documentJSON = String(data: document.data, encoding: .utf8) else {
      throw WorkflowDefinitionServiceError(code: .invalidDefinition, message: "canonical definition is not UTF-8")
    }
    return WorkflowDefinitionSyncIntent(transactionId: transactionId, workflowName: workflowName, storeRoot: root,
      sourceDirectory: liveDirectory.standardizedFileURL.path, sourceScope: sourceScope.rawValue,
      documentDigest: document.digest, documentJSON: documentJSON,
      expectedAfterBundleDigest: expectedAfterBundleDigest, bundleSnapshotBefore: bundleSnapshotBefore,
      bundleSnapshotAfter: bundleSnapshotAfter, attribution: attribution)
  }

  public func sync(_ intent: WorkflowDefinitionSyncIntent) throws -> WorkflowDefinitionSyncOutcome {
    try service(intent.storeRoot).sync(intent)
  }

  public func recordDelete(workflowName: String, sourceScope: WorkflowScope, transactionId: String,
                           bundleSnapshotBefore: String?, attribution: WorkflowDefinitionChangeAttribution) throws -> WorkflowDefinitionSyncOutcome {
    try service(storeRoot(workflowName: workflowName, sourceScope: sourceScope)).recordDelete(
      workflowName: workflowName, transactionId: transactionId, bundleSnapshotBefore: bundleSnapshotBefore,
      attribution: attribution)
  }
}
