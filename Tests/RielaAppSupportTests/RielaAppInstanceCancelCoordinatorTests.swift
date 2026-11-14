import XCTest
import RielaServer
@testable import RielaAppSupport

private struct CallSnapshot {
  var appCalls: Int
  var frames: [WorkflowServeSessionControlFrame]
  var storeCalls: Int
}

private struct SoleScenario {
  var app: RielaAppLiveSessionInventory
  var child: RielaAppLiveSessionInventory
  var running: Bool
  var throwsControl: Bool
  var expected: RielaAppInstanceCancelCode
}

private actor CancelPorts: RielaAppInstanceCancelPorts {
  var currentProfile = "default"
  var exists = true
  var appOutcome: WorkflowServeSessionCancelOutcome = .notFound
  var childOutcome: WorkflowServeSessionCancelOutcome = .notFound
  var app = RielaAppLiveSessionInventory(sessionIds: [], pendingRunCount: 0)
  var child = RielaAppLiveSessionInventory(sessionIds: [], pendingRunCount: 0)
  var running = false
  var throwsControl = false
  var state: RielaAppStoredSessionState = .absent
  var appCalls = 0
  var frames: [WorkflowServeSessionControlFrame] = []
  var storeCalls = 0
  func configure(profile: String = "default", exists: Bool = true, appOutcome: WorkflowServeSessionCancelOutcome = .notFound,
                 childOutcome: WorkflowServeSessionCancelOutcome = .notFound, app: RielaAppLiveSessionInventory = .init(sessionIds: [], pendingRunCount: 0),
                 child: RielaAppLiveSessionInventory = .init(sessionIds: [], pendingRunCount: 0), running: Bool = false,
                 throwsControl: Bool = false, state: RielaAppStoredSessionState = .absent) {
    currentProfile = profile; self.exists = exists; self.appOutcome = appOutcome; self.childOutcome = childOutcome
    self.app = app; self.child = child; self.running = running; self.throwsControl = throwsControl; self.state = state
  }
  func profile() async -> String { currentProfile }
  func instanceExists(identity: String) async -> Bool { exists }
  func cancelAppLaunch(identity: String, sessionId: String, reason: String, actor: String) async -> WorkflowServeSessionCancelOutcome {
    appCalls += 1; return appOutcome
  }
  func appInventory(identity: String) async -> RielaAppLiveSessionInventory { app }
  func childRunning(identity: String) async -> Bool { running }
  func childSessionControl(identity: String, frame: WorkflowServeSessionControlFrame) async throws -> WorkflowServeSessionControlAcknowledgement {
    frames.append(frame)
    if throwsControl { throw WorkflowServeSessionControlError.unsupported }
    if frame.type == "session-list" { return .listAck(requestId: frame.requestId, sessionIds: child.sessionIds, pendingRunCount: child.pendingRunCount) }
    return .cancelAck(requestId: frame.requestId, sessionId: frame.sessionId ?? "", outcome: childOutcome)
  }
  func storedSessionState(identity: String, sessionId: String) async -> RielaAppStoredSessionState { storeCalls += 1; return state }
  func counts() -> CallSnapshot { .init(appCalls: appCalls, frames: frames, storeCalls: storeCalls) }
}

final class RielaAppInstanceCancelCoordinatorTests: XCTestCase {
  private let request = RielaAppInstanceCancelRequest(expectedProfile: "default", reason: "duplicate")
  private func code(_ result: Result<RielaAppInstanceCancelResponse, RielaAppInstanceCancelError>) -> RielaAppInstanceCancelCode? {
    if case .failure(let error) = result { return error.code }; return nil
  }
  private func response(_ result: Result<RielaAppInstanceCancelResponse, RielaAppInstanceCancelError>) -> RielaAppInstanceCancelResponse? {
    try? result.get()
  }
  func testExplicitDecisionOrderAndOwners() async {
    let ports = CancelPorts()
    let coordinator = RielaAppInstanceCancelCoordinator(ports: ports, makeRequestId: { "request" })
    await ports.configure(profile: "other")
    var result = await coordinator.cancel(identity: "i", sessionId: "A", request: request)
    XCTAssertEqual(code(result), .configurationConflict)
    await ports.configure(exists: false)
    result = await coordinator.cancel(identity: "i", sessionId: "A", request: request)
    XCTAssertEqual(code(result), .instanceNotFound)
    await ports.configure(appOutcome: .cancelRequested)
    result = await coordinator.cancel(identity: "i", sessionId: "A", request: request)
    XCTAssertEqual(response(result)?.owner, "app")
    await ports.configure(childOutcome: .alreadyRequested, running: true)
    result = await coordinator.cancel(identity: "i", sessionId: "A", request: request)
    XCTAssertEqual(response(result)?.owner, "eventServe")
    XCTAssertEqual(response(result)?.outcome, "alreadyRequested")
    let calls = await ports.counts()
    XCTAssertEqual(calls.frames.last?.actor, "rielaapp-api:default")
    XCTAssertEqual(calls.frames.last?.reason, "duplicate")
    XCTAssertEqual(calls.frames.last?.requestId, "request")
    await ports.configure(childOutcome: .cancelRequested, running: true)
    result = await coordinator.cancel(identity: "i", sessionId: "A", request: request)
    XCTAssertEqual(response(result)?.outcome, "cancelRequested")
  }
  func testExplicitStoredStateAndChannelPrecedence() async {
    let ports = CancelPorts()
    let coordinator = RielaAppInstanceCancelCoordinator(ports: ports)
    for (state, expected) in [(RielaAppStoredSessionState.absent, RielaAppInstanceCancelCode.sessionNotFound), (.terminal, .notRunning), (.nonTerminal, .cancelUnavailable)] {
      await ports.configure(running: true, throwsControl: true, state: state)
      let result = await coordinator.cancel(identity: "i", sessionId: "A", request: request)
      XCTAssertEqual(code(result), expected)
    }
    await ports.configure(state: .nonTerminal)
    let result = await coordinator.cancel(identity: "i", sessionId: "A", request: request)
    XCTAssertEqual(code(result), .sessionNotOwned)
  }
  func testSoleLiveInventoryAndHistoryBoundary() async {
    let ports = CancelPorts()
    let coordinator = RielaAppInstanceCancelCoordinator(ports: ports)
    await ports.configure(childOutcome: .cancelRequested, child: .init(sessionIds: ["A"], pendingRunCount: 0), running: true, state: .terminal)
    let result = await coordinator.cancelSole(identity: "i", request: request)
    XCTAssertEqual(response(result)?.sessionId, "A")
    XCTAssertEqual(response(result)?.owner, "eventServe")
    let calls = await ports.counts()
    XCTAssertEqual(calls.storeCalls, 0)
    XCTAssertEqual(calls.frames.map(\.type), ["session-list", "session-cancel"])
  }
  func testSoleRefusesAmbiguousZeroPendingAndUnavailableWithoutCancel() async {
    let scenarios: [SoleScenario] = [
      .init(app: .init(sessionIds: ["B"], pendingRunCount: 0), child: .init(sessionIds: ["A"], pendingRunCount: 0), running: true, throwsControl: false, expected: .ambiguousRunningSessions),
      .init(app: .init(sessionIds: ["A"], pendingRunCount: 1), child: .init(sessionIds: [], pendingRunCount: 0), running: false, throwsControl: false, expected: .ambiguousRunningSessions),
      .init(app: .init(sessionIds: [], pendingRunCount: 0), child: .init(sessionIds: [], pendingRunCount: 0), running: false, throwsControl: false, expected: .noRunningExecution),
      .init(app: .init(sessionIds: [], pendingRunCount: 1), child: .init(sessionIds: [], pendingRunCount: 0), running: false, throwsControl: false, expected: .sessionNotOwned),
      .init(app: .init(sessionIds: ["A"], pendingRunCount: 0), child: .init(sessionIds: [], pendingRunCount: 0), running: true, throwsControl: true, expected: .cancelUnavailable)
    ]
    for scenario in scenarios {
      let app = scenario.app
      let ports = CancelPorts()
      await ports.configure(app: app, child: scenario.child, running: scenario.running, throwsControl: scenario.throwsControl, state: .nonTerminal)
      let result = await RielaAppInstanceCancelCoordinator(ports: ports).cancelSole(identity: "i", request: request)
      XCTAssertEqual(code(result), scenario.expected)
      if case .failure(let error) = result, app.sessionIds == ["B"] { XCTAssertEqual(error.sessionIds, ["A", "B"]); XCTAssertEqual(error.pendingRunCount, 0) }
      let calls = await ports.counts()
      XCTAssertEqual(calls.appCalls, 0); XCTAssertFalse(calls.frames.contains { $0.type == "session-cancel" }); XCTAssertEqual(calls.storeCalls, 0)
    }
  }
  func testSoleOwnerNotFoundAndAppSuccess() async {
    let ports = CancelPorts()
    let coordinator = RielaAppInstanceCancelCoordinator(ports: ports)
    await ports.configure(app: .init(sessionIds: ["A"], pendingRunCount: 0))
    var result = await coordinator.cancelSole(identity: "i", request: request)
    XCTAssertEqual(code(result), .notRunning)
    await ports.configure(appOutcome: .alreadyRequested, app: .init(sessionIds: ["A"], pendingRunCount: 0))
    result = await coordinator.cancelSole(identity: "i", request: request)
    XCTAssertEqual(response(result)?.owner, "app")
  }
}
