import Foundation
import RielaCore

public struct WorkflowPackageSignature: Codable, Equatable, Sendable {
  public var keyId: String
  public var algorithm: String
  public var signature: String

  public init(keyId: String, algorithm: String = "ed25519", signature: String) {
    self.keyId = keyId
    self.algorithm = algorithm
    self.signature = signature
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case keyId
    case algorithm
    case signature
  }

  public init(from decoder: Decoder) throws {
    try rejectUnsupportedKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue), label: "package manifest signature")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.keyId = try container.decode(String.self, forKey: .keyId)
    self.algorithm = try container.decodeIfPresent(String.self, forKey: .algorithm) ?? "ed25519"
    self.signature = try container.decode(String.self, forKey: .signature)
  }
}

public struct WorkflowPackageIntegrity: Codable, Equatable, Sendable {
  public var digestAlgorithm: String
  public var digest: String
  public var signatures: [WorkflowPackageSignature]

  public init(digestAlgorithm: String = "sha256", digest: String, signatures: [WorkflowPackageSignature] = []) {
    self.digestAlgorithm = digestAlgorithm
    self.digest = digest
    self.signatures = signatures
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case digestAlgorithm
    case digest
    case signatures
  }

  public init(from decoder: Decoder) throws {
    try rejectUnsupportedKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue), label: "package manifest integrity")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.digestAlgorithm = try container.decodeIfPresent(String.self, forKey: .digestAlgorithm) ?? "sha256"
    self.digest = try container.decode(String.self, forKey: .digest)
    self.signatures = try container.decodeIfPresent([WorkflowPackageSignature].self, forKey: .signatures) ?? []
  }
}
