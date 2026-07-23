import Crypto
import Foundation

public enum WorkflowHistoryValidationError: Error, Equatable, CustomStringConvertible, Sendable {
  case unsupportedSchemaVersion(Int)
  case unsafeIdentifier(String)
  case invalidRelativePath(String)
  case invalidDigest(String)
  case noncanonicalOrder(String)
  case duplicateValue(String)
  case integrityMismatch
  case invalidContract(String)

  public var description: String {
    switch self {
    case let .unsupportedSchemaVersion(version): "unsupported workflow history schema version \(version)"
    case let .unsafeIdentifier(value): "unsafe workflow history identifier '\(value)'"
    case let .invalidRelativePath(path): "invalid workflow history relative path '\(path)'"
    case let .invalidDigest(digest): "invalid SHA-256 digest '\(digest)'"
    case let .noncanonicalOrder(field): "workflow history field '\(field)' is not canonically ordered"
    case let .duplicateValue(value): "duplicate workflow history value '\(value)'"
    case .integrityMismatch: "workflow history canonical byte integrity mismatch"
    case let .invalidContract(message): message
    }
  }
}

public enum WorkflowHistoryCanonicalCoding {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(timestampFormatter.string(from: date))
    }
    return try encoder.encode(value)
  }

  public static func decode<T: Codable>(_ type: T.Type, from bytes: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard let date = timestampFormatter.date(from: value), timestampFormatter.string(from: date) == value else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "timestamp must be canonical RFC 3339 UTC with milliseconds")
      }
      return date
    }
    let decoded = try decoder.decode(type, from: bytes)
    guard try encode(decoded) == bytes else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    return decoded
  }

  public static func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  public static func validateSafeComponent(_ value: String) throws {
    let scalars = value.unicodeScalars
    guard (1...128).contains(scalars.count), value != ".", value != "..",
          scalars.allSatisfy({ isASCIIAlphaNumeric($0) || $0 == "-" || $0 == "_" }) else {
      throw WorkflowHistoryValidationError.unsafeIdentifier(value)
    }
  }

  public static func validateDigest(_ value: String) throws {
    guard value.count == 64, value.unicodeScalars.allSatisfy({ scalar in
      (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
    }) else {
      throw WorkflowHistoryValidationError.invalidDigest(value)
    }
  }

  public static func validateRelativePath(_ value: String) throws {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.hasSuffix("/"), !value.contains("\\"),
          value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
      throw WorkflowHistoryValidationError.invalidRelativePath(value)
    }
  }

  public static func validate(_ manifest: WorkflowBundleSnapshotManifest) throws {
    try validateSchema(manifest.schemaVersion)
    try validateSafeComponent(manifest.snapshotId)
    try validate(manifest.target)
    try validateDigest(manifest.bundleDigest)
    guard manifest.complete, manifest.integrityAlgorithm == "sha256" else {
      throw WorkflowHistoryValidationError.invalidContract("snapshot is incomplete or uses an unsupported integrity algorithm")
    }
    try validateFiles(manifest.files)
  }

  public static func validate(_ proposal: WorkflowChangeProposal) throws {
    try validateSchema(proposal.schemaVersion)
    try validateSafeComponent(proposal.proposalId)
    try validateSafeComponent(proposal.sourceSessionId)
    if let sourceStepId = proposal.sourceStepId {
      try validateSafeComponent(sourceStepId)
    }
    try validate(proposal.target)
    try validateDigest(proposal.beforeBundleDigest)
    try validateDigest(proposal.expectedAfterBundleDigest)
    try validateDigest(proposal.proposalDigest)
    let paths = proposal.operations.map(\.relativePath)
    try validateCanonicalPaths(paths, field: "operations")
    for operation in proposal.operations {
      try validateRelativePath(operation.relativePath)
      try validateOperation(operation)
    }
    try validateVerificationEvidence(proposal.validation)
    try validateCanonicalStrings(proposal.rejectedAlternatives, field: "rejectedAlternatives")
    guard try proposalDigest(proposal) == proposal.proposalDigest else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
  }

  public static func validate(_ changeSet: WorkflowChangeSet) throws {
    try validateSchema(changeSet.schemaVersion)
    try validateSafeComponent(changeSet.changeSetId)
    try validate(changeSet.proposal)
    try validateDigest(changeSet.finalizedDigest)
    let review = changeSet.review
    try validate(review)
    guard review.decision == .accepted,
          review.reviewedProposalId == changeSet.proposal.proposalId,
          review.reviewedProposalDigest == changeSet.proposal.proposalDigest,
          review.reviewedBeforeBundleDigest == changeSet.proposal.beforeBundleDigest else {
      throw WorkflowHistoryValidationError.invalidContract("change-set review does not bind the accepted proposal")
    }
    guard try finalizedDigest(changeSet) == changeSet.finalizedDigest else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
  }

  public static func validate(_ identity: WorkflowBundleIdentity) throws {
    try validateSafeComponent(identity.workflowId)
    try validateCanonicalAbsolutePath(identity.workflowDirectory, field: "workflowDirectory")
    try validateCanonicalAbsolutePath(identity.ownershipRoot, field: "ownershipRoot")
    guard path(identity.workflowDirectory, isContainedIn: identity.ownershipRoot) else {
      throw WorkflowHistoryValidationError.invalidContract("workflow directory is outside the ownership root")
    }
    if let packageDirectory = identity.packageDirectory {
      try validateCanonicalAbsolutePath(packageDirectory, field: "packageDirectory")
      guard path(identity.workflowDirectory, isContainedIn: packageDirectory),
            identity.ownershipRoot == packageDirectory,
            identity.sourceKind == .installedPackage,
            !identity.sourceMutable else {
        throw WorkflowHistoryValidationError.invalidContract("package workflow identity has inconsistent ownership or mutability")
      }
    } else if identity.sourceKind == .installedPackage {
      throw WorkflowHistoryValidationError.invalidContract("authored workflow identity has inconsistent source kind")
    }
  }

  public static func validate(_ review: WorkflowChangeSetReviewEvidence) throws {
    try validateSafeComponent(review.gateId)
    try validateSafeComponent(review.gateResultId)
    try validateSafeComponent(review.reviewedProposalId)
    try validateDigest(review.reviewedProposalDigest)
    try validateDigest(review.reviewedBeforeBundleDigest)
    try validateSafeComponent(review.reviewerStepId)
    try validateSafeComponent(review.reviewerStepExecutionId)
    try validateCanonicalStrings(review.evidenceReferences, field: "evidenceReferences")
  }

  public static func validate(_ record: WorkflowRestoreRecord) throws {
    try validateSchema(record.schemaVersion)
    try validateSafeComponent(record.restoreId)
    try validate(record.target)
    try validateSafeComponent(record.sourceSnapshotId)
    try validateSafeComponent(record.preRestoreSnapshotId)
    try validateDigest(record.requestedBundleDigest)
    try validateDigest(record.beforeBundleDigest)
    if let resultBundleDigest = record.resultBundleDigest { try validateDigest(resultBundleDigest) }
    try validateSafeComponent(record.transactionId)
    try validateCanonicalPaths(record.observedDirtyConflicts, field: "observedDirtyConflicts")
    try validateCanonicalPaths(record.restoredFiles, field: "restoredFiles")
    try validateCanonicalPaths(record.skippedFiles, field: "skippedFiles")
    try validateVerificationEvidence(record.validation)
    try validateCanonicalStrings(record.diagnostics, field: "diagnostics")
    guard !record.approved || record.outcome != .proposed,
          record.outcome != .restored || record.resultBundleDigest != nil else {
      throw WorkflowHistoryValidationError.invalidContract("restore outcome is inconsistent with approval or result digest")
    }
  }

  public static func validate(_ evidence: LoopWorkflowMutationEvidence) throws {
    try validateSchema(evidence.schemaVersion)
    try validate(evidence.target)
    if let value = evidence.changeSetId { try validateSafeComponent(value) }
    if let value = evidence.snapshotId { try validateSafeComponent(value) }
    if let value = evidence.restoreId { try validateSafeComponent(value) }
    if let value = evidence.transactionId { try validateSafeComponent(value) }
    if let value = evidence.beforeBundleDigest { try validateDigest(value) }
    if let value = evidence.afterBundleDigest { try validateDigest(value) }
    if let review = evidence.review { try validate(review) }
    try validateVerificationEvidence(evidence.validation)
    try validateCanonicalStrings(evidence.diagnostics, field: "diagnostics")
    guard !evidence.applied || evidence.outcome == .applied,
          !evidence.restored || evidence.outcome == .restored else {
      throw WorkflowHistoryValidationError.invalidContract("mutation evidence flags do not match its outcome")
    }
  }

  public static func proposalDigest(_ proposal: WorkflowChangeProposal) throws -> String {
    let input = WorkflowProposalDigestInput(
      schemaVersion: proposal.schemaVersion,
      proposalId: proposal.proposalId,
      sourceSessionId: proposal.sourceSessionId,
      sourceStepId: proposal.sourceStepId,
      target: proposal.target,
      beforeBundleDigest: proposal.beforeBundleDigest,
      operations: proposal.operations,
      expectedAfterBundleDigest: proposal.expectedAfterBundleDigest,
      rationale: proposal.rationale,
      validation: proposal.validation,
      rejectedAlternatives: proposal.rejectedAlternatives,
      createdAt: proposal.createdAt
    )
    return sha256(try encode(input))
  }

  public static func finalizedDigest(_ changeSet: WorkflowChangeSet) throws -> String {
    let input = WorkflowFinalizedDigestInput(
      schemaVersion: changeSet.schemaVersion,
      changeSetId: changeSet.changeSetId,
      proposal: changeSet.proposal,
      review: changeSet.review,
      finalizedAt: changeSet.finalizedAt
    )
    return sha256(try encode(input))
  }

  public static func bundleDigest(target: WorkflowBundleIdentity, files: [WorkflowBundleSnapshotFile]) throws -> String {
    try validate(target)
    try validateFiles(files)
    let input = WorkflowBundleDigestInput(
      schemaVersion: 1,
      workflowId: target.workflowId,
      sourceScope: target.sourceScope,
      sourceKind: target.sourceKind,
      workflowDirectory: target.workflowDirectory,
      ownershipRoot: target.ownershipRoot,
      packageDirectory: target.packageDirectory,
      packageName: target.packageName,
      packageVersion: target.packageVersion,
      workflowContractVersion: target.workflowContractVersion,
      files: files
    )
    return sha256(try encode(input))
  }

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter
  }()

  private static func validateSchema(_ version: Int) throws {
    guard version == 1 else { throw WorkflowHistoryValidationError.unsupportedSchemaVersion(version) }
  }

  private static func validateFiles(_ files: [WorkflowBundleSnapshotFile]) throws {
    try validateCanonicalPaths(files.map(\.relativePath), field: "files")
    for file in files {
      try validateRelativePath(file.relativePath)
      try validateDigest(file.contentDigest)
      guard file.byteCount >= 0 else {
        throw WorkflowHistoryValidationError.invalidContract("snapshot byte count must be non-negative")
      }
    }
  }

  private static func validateCanonicalPaths(_ paths: [String], field: String) throws {
    guard paths == paths.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) else {
      throw WorkflowHistoryValidationError.noncanonicalOrder(field)
    }
    guard Set(paths).count == paths.count else {
      throw WorkflowHistoryValidationError.duplicateValue(field)
    }
  }

  private static func validateCanonicalStrings(_ values: [String], field: String) throws {
    guard values == values.sorted() else {
      throw WorkflowHistoryValidationError.noncanonicalOrder(field)
    }
    guard Set(values).count == values.count else {
      throw WorkflowHistoryValidationError.duplicateValue(field)
    }
  }

  private static func validateVerificationEvidence(_ values: [LoopVerificationEvidence]) throws {
    let ids = values.map(\.id)
    try validateCanonicalStrings(ids, field: "validation")
    for value in values {
      try validateSafeComponent(value.id)
      try validateCanonicalStrings(value.evidenceRefs, field: "validation.evidenceRefs")
    }
  }

  private static func validateCanonicalAbsolutePath(_ value: String, field: String) throws {
    guard value.hasPrefix("/"), value != "/", !value.hasSuffix("/"),
          URL(fileURLWithPath: value).standardizedFileURL.path == value else {
      throw WorkflowHistoryValidationError.invalidContract("\(field) must be a normalized absolute path without a trailing separator")
    }
  }

  private static func path(_ child: String, isContainedIn root: String) -> Bool {
    child == root || child.hasPrefix(root + "/")
  }

  private static func validateOperation(_ operation: WorkflowFileOperation) throws {
    for state in [operation.before, operation.after].compactMap({ $0 }) {
      try validateDigest(state.contentDigest)
      guard state.byteCount >= 0 else {
        throw WorkflowHistoryValidationError.invalidContract("operation byte count must be non-negative")
      }
    }
    let valid: Bool = switch operation.kind {
    case .create: operation.before == nil && operation.after != nil
    case .update: operation.before != nil && operation.after != nil
    case .delete: operation.before != nil && operation.after == nil
    case .executableBit:
      operation.before?.contentDigest == operation.after?.contentDigest
        && operation.before?.executable != operation.after?.executable
    }
    guard valid else {
      throw WorkflowHistoryValidationError.invalidContract("operation '\(operation.relativePath)' has invalid before/after states")
    }
  }

  private static func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
    (48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
  }
}

private struct WorkflowBundleDigestInput: Encodable {
  var schemaVersion: Int
  var workflowId: String
  var sourceScope: WorkflowHistorySourceScope
  var sourceKind: WorkflowHistorySourceKind
  var workflowDirectory: String
  var ownershipRoot: String
  var packageDirectory: String?
  var packageName: String?
  var packageVersion: String?
  var workflowContractVersion: String?
  var files: [WorkflowBundleSnapshotFile]
}

private struct WorkflowProposalDigestInput: Encodable {
  var schemaVersion: Int
  var proposalId: String
  var sourceSessionId: String
  var sourceStepId: String?
  var target: WorkflowBundleIdentity
  var beforeBundleDigest: String
  var operations: [WorkflowFileOperation]
  var expectedAfterBundleDigest: String
  var rationale: String
  var validation: [LoopVerificationEvidence]
  var rejectedAlternatives: [String]
  var createdAt: Date
}

private struct WorkflowFinalizedDigestInput: Encodable {
  var schemaVersion: Int
  var changeSetId: String
  var proposal: WorkflowChangeProposal
  var review: WorkflowChangeSetReviewEvidence
  var finalizedAt: Date
}
