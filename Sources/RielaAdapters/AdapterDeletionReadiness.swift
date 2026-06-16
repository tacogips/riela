import Foundation
import RielaCore

public enum AdapterParityDomainStatus: String, Codable, Equatable, Sendable {
  case implemented
  case deletionBlocked = "deletion-blocked"
}

public struct AdapterParityDomain: Codable, Equatable, Sendable {
  public var backend: NodeExecutionBackend
  public var status: AdapterParityDomainStatus
  public var sourceTargets: [String]
  public var requiredEvidence: [String]
  public var notes: String

  public init(
    backend: NodeExecutionBackend,
    status: AdapterParityDomainStatus,
    sourceTargets: [String],
    requiredEvidence: [String],
    notes: String
  ) {
    self.backend = backend
    self.status = status
    self.sourceTargets = sourceTargets
    self.requiredEvidence = requiredEvidence
    self.notes = notes
  }
}

public enum AdapterDeletionReadiness {
  public static let domains: [AdapterParityDomain] = [
    AdapterParityDomain(
      backend: .codexAgent,
      status: .implemented,
      sourceTargets: ["Sources/CodexAgent", "Sources/RielaAdapters"],
      requiredEvidence: [
        "swift test --filter AgentAdapterTests",
        "swift test --filter RielaAdaptersTests"
      ],
      notes: "codex-agent command construction, auth preflight, output normalization, deadline handling, and redaction are owned by Swift adapter tests."
    ),
    AdapterParityDomain(
      backend: .claudeCodeAgent,
      status: .implemented,
      sourceTargets: ["Sources/ClaudeCodeAgent", "Sources/RielaAdapters"],
      requiredEvidence: [
        "swift test --filter AgentAdapterTests",
        "swift test --filter RielaAdaptersTests"
      ],
      notes: "claude-code-agent command construction, readiness, output normalization, and redaction are owned by Swift adapter tests."
    ),
    AdapterParityDomain(
      backend: .cursorCliAgent,
      status: .implemented,
      sourceTargets: ["Sources/CursorCLIAgent", "Sources/RielaAdapters"],
      requiredEvidence: [
        "swift test --filter AgentAdapterTests",
        "swift test --filter RielaAdaptersTests"
      ],
      notes: "cursor-cli-agent command construction, model checks, mode/stream metadata, and redaction are owned by Swift adapter tests."
    ),
    AdapterParityDomain(
      backend: .officialCursorSDK,
      status: .deletionBlocked,
      sourceTargets: ["Sources/RielaAdapters"],
      requiredEvidence: [
        "swift test --filter OfficialSDKAdapterTests/testDispatchingNodeAdapterRegistersOfficialSDKBackendsAndDefersCursorSDK"
      ],
      notes: "official/cursor-sdk is intentionally not aliased to cursor-cli-agent; TypeScript deletion stays blocked until a reviewed Swift adapter or explicit removal decision exists."
    ),
  ]

  public static func domain(for backend: NodeExecutionBackend) -> AdapterParityDomain? {
    domains.first { $0.backend == backend }
  }
}
