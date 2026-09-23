import Foundation
import RielaCore

/// Operator-owned configuration models kept separate from command execution.
struct SpecialistConfiguredRouting {
  let specialists: [SpecialistConfiguredSpecialist]
  let provider: any SpecialistDecisionProvider
  let revision: String
  let deadlineSeconds: TimeInterval
}

struct SpecialistConfiguredRoutingFile: Codable {
  struct Classifier: Codable {
    let node: AgentNodePayload?
    let endpoint: String?
    let secretEnvironment: String?
    let providerIdentity: String?
    let deadlineSeconds: TimeInterval?
    let fixtureDecisions: [SpecialistDecision]?
  }
  let specialists: [SpecialistConfiguredSpecialist]
  let classifier: Classifier
}

struct SpecialistTransportConfiguration: Codable {
  struct Matrix: Codable {
    let homeserver: String; let accessTokenEnvironment: String?; let fixtureAccessToken: String?; let roomId: String
    let accountId: String?; let localUserId: String?
  }
  struct Wrike: Codable { let folderId: String; let statusByLifecycle: [String: String] }
  let matrix: Matrix?
  let wrike: Wrike?
}

struct SpecialistCLIArguments {
  let stateRoot: String; let body: String; let sourceEventId: String?; let workflowId: String?; let variables: String?
  let specialistConfigPath: String?; let transportConfigPath: String?; let originId: String?; let mockScenarioPath: String?
  let serveOnce: Bool; let route: SpecialistRequestRoute; let workingDirectory: String
  let reconcileEventId: String?; let reconcileRemoteReceiptId: String?; let reconcileExpectedGeneration: Int?
  let reconcileTaskId: String?; let reconcileRequestId: String?; let reconcileExpectedVersion: Int?
  let reconcileOutcome: SpecialistDispatchReconciliationOutcome?; let reconcileEvidence: String?
  let catalogQuery: String?; let catalogLimit: Int; let catalogCursor: String?

  init(_ options: CLICommandOptions) throws {
    func value(_ name: String) -> String? { guard let index = options.arguments.firstIndex(of: name), options.arguments.indices.contains(index + 1) else { return nil }; return options.arguments[index + 1] }
    guard let stateRoot = value("--state-root") else { throw CLIUsageError("--state-root is required") }
    self.stateRoot = stateRoot; body = value("--body") ?? "submitted specialist task"; sourceEventId = value("--source-event-id")
    workflowId = value("--workflow"); originId = value("--origin-id"); mockScenarioPath = value("--mock-scenario"); serveOnce = options.arguments.contains("--once")
    variables = value("--variables"); specialistConfigPath = value("--specialist-config"); transportConfigPath = value("--transport-config")
    reconcileEventId = value("--event-id"); reconcileRemoteReceiptId = value("--remote-receipt-id")
    reconcileExpectedGeneration = value("--expected-generation").flatMap(Int.init)
    reconcileTaskId = value("--task-id"); reconcileRequestId = value("--request-id")
    reconcileExpectedVersion = value("--expected-version").flatMap(Int.init)
    reconcileOutcome = value("--outcome").flatMap(SpecialistDispatchReconciliationOutcome.init(rawValue:))
    reconcileEvidence = value("--evidence")
    catalogQuery = value("--query"); catalogCursor = value("--cursor")
    if let limitValue = value("--limit"), let parsedLimit = Int(limitValue), (1...200).contains(parsedLimit) {
      catalogLimit = parsedLimit
    } else if value("--limit") != nil {
      throw CLIUsageError("--limit must be an integer from 1 through 200")
    } else {
      catalogLimit = 100
    }
    let routeValue = value("--route") ?? SpecialistRequestRoute.work.rawValue
    guard let parsedRoute = SpecialistRequestRoute(rawValue: routeValue) else { throw CLIUsageError("--route must be work, status, cancel, or clarification") }
    route = parsedRoute; workingDirectory = value("--working-dir") ?? FileManager.default.currentDirectoryPath
  }
}
