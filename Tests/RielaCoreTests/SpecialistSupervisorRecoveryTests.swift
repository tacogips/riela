import XCTest
@testable import RielaCore

final class SpecialistSupervisorRecoveryTests: XCTestCase {
  func testNestedSessionIdentityUsesLengthDelimitedSHA256AndRejectsLegacyDelimiterAliases() throws {
    let runner = DeterministicWorkflowRunner()
    let left = try runner.nestedSessionID(
      parentSessionId: "parent-a", sourceExecutionId: "execution-b", branchId: "branch-c"
    )
    let right = try runner.nestedSessionID(
      parentSessionId: "parent-ab", sourceExecutionId: "execution", branchId: "branch-c"
    )

    XCTAssertNotEqual(left, right, "component boundaries must participate in the durable identity")
    XCTAssertTrue(left.hasPrefix("nested-v1-"))
    XCTAssertEqual(left.count, "nested-v1-".count + 64)
    XCTAssertTrue(left.dropFirst("nested-v1-".count).allSatisfy { $0.isHexDigit })

    // These distinct tuples produced exactly the same delimiter-concatenated
    // legacy material. Rejecting delimiter-bearing components prevents that
    // ambiguity before a durable identity is allocated.
    let legacyLeft = ["parent\u{1F}execution", "branch", "fanout"]
    let legacyRight = ["parent", "execution", "branch\u{1F}fanout"]
    XCTAssertEqual(legacyLeft.joined(separator: "\u{1F}"), legacyRight.joined(separator: "\u{1F}"))
    XCTAssertThrowsError(try runner.nestedSessionID(
      parentSessionId: legacyLeft[0], sourceExecutionId: legacyLeft[1], branchId: legacyLeft[2]
    ))
    XCTAssertThrowsError(try runner.nestedSessionID(
      parentSessionId: legacyRight[0], sourceExecutionId: legacyRight[1], branchId: legacyRight[2]
    ))
  }

  func testNestedReservationRecoversLegacyIdentityWithoutReplacement() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let legacyChild = WorkflowSession(
      workflowId: "production-parent",
      sessionId: "nested-deadbeef",
      status: .created,
      entryStepId: "dispatch",
      currentStepId: "dispatch",
      createdAt: Date(),
      updatedAt: Date(),
      parentSessionId: "parent",
      rootSessionId: "parent"
    )
    let reservation = WorkflowNestedInvocationReservation(
      parentSessionId: "parent",
      parentStepId: "dispatch",
      resumeStepId: "resume",
      sourceStepExecutionId: "execution",
      branchId: "cross-workflow",
      childSnapshot: WorkflowRuntimePersistenceSnapshot(session: legacyChild)
    )
    _ = try persistence.reserveNestedInvocation(reservation)

    let runner = DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      nestedInvocationPersistenceStore: persistence
    )
    let recovered = try await runner.reserveNestedSession(
      workflow: productionNestedCaller(),
      nodePayloads: productionNestedPayloads(),
      entryStepId: "dispatch",
      parentSessionId: "parent",
      rootSessionId: "parent",
      parentStepId: "dispatch",
      resumeStepId: "resume",
      sourceExecutionId: "execution",
      branchId: "cross-workflow"
    )
    XCTAssertEqual(recovered, legacyChild.sessionId)
  }

  func testProductionRunnerCancellationDoesNotPublishAParentArrivalOrRelaunchChild() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtimeStore = InMemoryWorkflowRuntimeStore()
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let adapter = CancellingNestedAdapter()
    let runner = DeterministicWorkflowRunner(
      store: runtimeStore,
      adapter: adapter,
      calleeResolver: ProductionNestedCalleeResolver(),
      nestedInvocationPersistenceStore: persistence
    )
    _ = try await runtimeStore.createSession(WorkflowSessionCreateInput(
      sessionId: "cancel-parent", workflowId: "production-parent", entryStepId: "dispatch"
    ))
    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads(), resumeSessionId: "cancel-parent"
      ))
      XCTFail("Child cancellation must stop parent publication")
    } catch {
      XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)")
    }
    let childExecutions = await adapter.calleeExecutions()
    XCTAssertEqual(childExecutions, 1)
    let parentMessages = try SQLiteWorkflowMessageLog(
      databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    ).listMessages(workflowExecutionId: "cancel-parent", toStepId: "resume")
    XCTAssertTrue(parentMessages.isEmpty)
    let loadedParent = try await runtimeStore.loadSession(id: "cancel-parent")
    let parent = try XCTUnwrap(loadedParent)
    let sourceExecutionId = try XCTUnwrap(parent.executions.first?.executionId)
    let record = try XCTUnwrap(try persistence.nestedInvocationRecord(
      parentSessionId: parent.sessionId, sourceStepExecutionId: sourceExecutionId, branchId: "cross-workflow"
    ))
    XCTAssertEqual(record.phase, .childTerminal)
    XCTAssertEqual(record.childTerminalSnapshot?.session.status, .failed)
    XCTAssertEqual(record.childTerminalSnapshot?.session.failureKind, .cancelled)

    // A cancellation is confirmed by the descendant's canonical terminal
    // snapshot. Reopening the failed root must not launch that descendant a
    // second time or invent a successful parent arrival.
    let reopened = DeterministicWorkflowRunner(
      store: runtimeStore,
      adapter: adapter,
      calleeResolver: ProductionNestedCalleeResolver(),
      nestedInvocationPersistenceStore: SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    )
    let resumed = try await reopened.run(DeterministicWorkflowRunRequest(
      workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads(), resumeSessionId: "cancel-parent"
    ))
    XCTAssertEqual(resumed.status, .failed)
    let resumedChildExecutions = await adapter.calleeExecutions()
    XCTAssertEqual(resumedChildExecutions, 1)
    XCTAssertTrue(try SQLiteWorkflowMessageLog(
      databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    ).listMessages(workflowExecutionId: "cancel-parent", toStepId: "resume").isEmpty)
  }

  func testFailedChildReopenRetainsTerminalFailureWithoutRelaunch() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtimeStore = InMemoryWorkflowRuntimeStore()
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let adapter = FailingNestedAdapter()
    let runner = DeterministicWorkflowRunner(
      store: runtimeStore,
      adapter: adapter,
      calleeResolver: ProductionNestedCalleeResolver(),
      nestedInvocationPersistenceStore: persistence
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads()
      ))
      XCTFail("A failed child must fail its parent")
    } catch {
      XCTAssertFalse(error is NestedRecoveryInterruption)
    }
    let latestParent = await runtimeStore.latestSession(workflowId: "production-parent")
    let parent = try XCTUnwrap(latestParent)
    let sourceExecutionId = try XCTUnwrap(parent.executions.first?.executionId)
    let record = try XCTUnwrap(try persistence.nestedInvocationRecord(
      parentSessionId: parent.sessionId, sourceStepExecutionId: sourceExecutionId, branchId: "cross-workflow"
    ))
    XCTAssertEqual(record.phase, .childTerminal)
    XCTAssertEqual(record.childTerminalSnapshot?.session.status, .failed)
    let initialChildExecutions = await adapter.calleeExecutions()
    XCTAssertEqual(initialChildExecutions, 1)

    let reopened = DeterministicWorkflowRunner(
      store: runtimeStore,
      adapter: adapter,
      calleeResolver: ProductionNestedCalleeResolver(),
      nestedInvocationPersistenceStore: SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    )
    let resumed = try await reopened.run(DeterministicWorkflowRunRequest(
      workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads(), resumeSessionId: parent.sessionId
    ))
    XCTAssertEqual(resumed.status, .failed)
    let reopenedChildExecutions = await adapter.calleeExecutions()
    XCTAssertEqual(reopenedChildExecutions, 1)
    XCTAssertTrue(try SQLiteWorkflowMessageLog(
      databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    ).listMessages(workflowExecutionId: parent.sessionId, toStepId: "resume").isEmpty)
  }

  func testUnresolvedRunningChildFencesRepeatedReopenAsRecoveryRequired() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtimeStore = InMemoryWorkflowRuntimeStore()
    let parent = try await runtimeStore.createSession(WorkflowSessionCreateInput(
      sessionId: "uncertain-parent", workflowId: "production-parent", entryStepId: "dispatch"
    ))
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try persistence.save(WorkflowRuntimePersistenceSnapshot(session: parent))
    let directive = WorkflowCrossWorkflowDispatchDirective(
      workflowId: "production-child", calleeEntryStepId: "child", resumeStepId: "resume",
      transitionLabel: "completed", handoffPayload: [:], sourceStepExecutionId: "uncertain-dispatch"
    )
    var request = DeterministicWorkflowRunRequest(
      workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads()
    )
    request.rootSessionId = parent.sessionId
    let interrupted = DeterministicWorkflowRunner(
      store: runtimeStore,
      adapter: ProductionNestedAdapter(),
      calleeResolver: ProductionNestedCalleeResolver(),
      nestedInvocationPersistenceStore: persistence,
      nestedInvocationRecoveryCheckpointer: ThrowingNestedCheckpoint(target: .beforeChildNodeEffect)
    )
    await XCTAssertThrowsErrorAsync(try await interrupted.dispatchCrossWorkflowCallee(
      directive: directive, parentSessionId: parent.sessionId, parentStepId: "dispatch", request: request
    ))
    let prepared = try XCTUnwrap(try persistence.nestedInvocationRecord(
      parentSessionId: parent.sessionId, sourceStepExecutionId: directive.sourceStepExecutionId, branchId: "cross-workflow"
    ))
    var runningSnapshot = try persistence.load(sessionId: prepared.reservation.childSnapshot.session.sessionId)
    runningSnapshot.session.status = .running
    try persistence.save(runningSnapshot)

    let reopenedAdapter = ProductionNestedAdapter()
    for _ in 0 ..< 2 {
      let reopened = DeterministicWorkflowRunner(
        store: InMemoryWorkflowRuntimeStore(),
        adapter: reopenedAdapter,
        calleeResolver: ProductionNestedCalleeResolver(),
        nestedInvocationPersistenceStore: SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
      )
      await XCTAssertThrowsErrorAsync(try await reopened.dispatchCrossWorkflowCallee(
        directive: directive, parentSessionId: parent.sessionId, parentStepId: "dispatch", request: request
      ))
    }
    let fenced = try XCTUnwrap(try persistence.nestedInvocationRecord(
      parentSessionId: parent.sessionId, sourceStepExecutionId: directive.sourceStepExecutionId, branchId: "cross-workflow"
    ))
    XCTAssertEqual(fenced.phase, .recoveryRequired)
    XCTAssertEqual(fenced.recoveryReason, "child was running without a terminal receipt")
    let fencedChildExecutions = await reopenedAdapter.calleeExecutions()
    XCTAssertEqual(fencedChildExecutions, 0)
  }

  func testLostParentAcknowledgmentReopensTwiceWithOneArrival() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtimeStore = InMemoryWorkflowRuntimeStore()
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let adapter = ProductionNestedAdapter()
    let interrupted = DeterministicWorkflowRunner(
      store: runtimeStore,
      adapter: adapter,
      calleeResolver: ProductionNestedCalleeResolver(),
      nestedInvocationPersistenceStore: persistence,
      nestedInvocationRecoveryCheckpointer: ThrowingNestedCheckpoint(target: .parentPublicationPersisted)
    )
    do {
      _ = try await interrupted.run(DeterministicWorkflowRunRequest(
        workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads()
      ))
      XCTFail("Expected a lost-acknowledgment interruption")
    } catch {
      XCTAssertTrue(error is NestedRecoveryInterruption)
    }
    let interruptedParent = await runtimeStore.latestSession(workflowId: "production-parent")
    let parent = try XCTUnwrap(interruptedParent)
    let sourceExecutionId = try XCTUnwrap(parent.executions.first?.executionId)
    XCTAssertEqual(try persistence.nestedInvocationRecord(
      parentSessionId: parent.sessionId, sourceStepExecutionId: sourceExecutionId, branchId: "cross-workflow"
    )?.phase, .delivered)

    let reopened = DeterministicWorkflowRunner(
      store: runtimeStore,
      adapter: adapter,
      calleeResolver: ProductionNestedCalleeResolver(),
      nestedInvocationPersistenceStore: SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    )
    let first = try await reopened.run(DeterministicWorkflowRunRequest(
      workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads(), resumeSessionId: parent.sessionId
    ))
    let second = try await reopened.run(DeterministicWorkflowRunRequest(
      workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads(), resumeSessionId: parent.sessionId
    ))
    XCTAssertEqual(first.status, .completed)
    XCTAssertEqual(second.status, .completed)
    let acknowledgedChildExecutions = await adapter.calleeExecutions()
    XCTAssertEqual(acknowledgedChildExecutions, 1)
    XCTAssertEqual(try SQLiteWorkflowMessageLog(
      databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    ).listMessages(workflowExecutionId: parent.sessionId, toStepId: "resume").count, 1)
  }

  func testProductionRunnerPersistsNestedReservationTerminalAndOneParentArrivalAcrossResume() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtimeStore = InMemoryWorkflowRuntimeStore()
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let adapter = ProductionNestedAdapter()
    let runner = DeterministicWorkflowRunner(
      store: runtimeStore,
      adapter: adapter,
      calleeResolver: ProductionNestedCalleeResolver(),
      nestedInvocationPersistenceStore: persistence
    )

    let first = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads()
    ))
    XCTAssertEqual(first.status, .completed)
    let executionsAfterFirstRun = await adapter.calleeExecutions()
    XCTAssertEqual(executionsAfterFirstRun, 1)

    let reservation = try XCTUnwrap(try persistence.nestedInvocationRecord(
      parentSessionId: first.session.sessionId,
      sourceStepExecutionId: try XCTUnwrap(first.session.executions.first?.executionId),
      branchId: "cross-workflow"
    ))
    XCTAssertEqual(reservation.phase, .delivered)
    XCTAssertEqual(reservation.childTerminalSnapshot?.session.status, .completed)
    let persistedMessages = try SQLiteWorkflowMessageLog(
      databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    ).listMessages(workflowExecutionId: first.session.sessionId, toStepId: "resume")
    XCTAssertEqual(persistedMessages.count, 1)

    let resumed = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: productionNestedCaller(),
      nodePayloads: productionNestedPayloads(),
      resumeSessionId: first.session.sessionId
    ))
    XCTAssertEqual(resumed.status, .completed)
    let executionsAfterResume = await adapter.calleeExecutions()
    XCTAssertEqual(executionsAfterResume, 1, "A recovered parent must not relaunch its terminal child")
    XCTAssertEqual(
      try SQLiteWorkflowMessageLog(
        databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
      ).listMessages(workflowExecutionId: first.session.sessionId, toStepId: "resume").count,
      1
    )
  }

  func testProductionRunnerExercisesEveryNestedCheckpointWithOneAdapterInvocation() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtimeStore = InMemoryWorkflowRuntimeStore()
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let adapter = ProductionNestedAdapter()
    let checkpoints = NestedCheckpointRecorder()
    let runner = DeterministicWorkflowRunner(
      store: runtimeStore,
      adapter: adapter,
      calleeResolver: ProductionNestedCalleeResolver(),
      nestedInvocationPersistenceStore: persistence,
      nestedInvocationRecoveryCheckpointer: checkpoints
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads()
    ))
    XCTAssertEqual(result.status, .completed)
    let observedCheckpoints = await checkpoints.observed()
    XCTAssertEqual(observedCheckpoints, [
      .prepared, .parentIntentPersisted, .beforeChildNodeEffect, .afterChildEffect,
      .childTerminalPersisted, .afterChildNodeResult, .beforeParentPublication,
      .parentPublicationPersisted
    ])
    let childExecutions = await adapter.calleeExecutions()
    XCTAssertEqual(childExecutions, 1)
    let parentMessages = try SQLiteWorkflowMessageLog(
      databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    ).listMessages(workflowExecutionId: result.session.sessionId, toStepId: "resume")
    XCTAssertEqual(parentMessages.count, 1)
  }

  func testProductionRunnerFailpointsPersistOnlyTheCompletedNestedBoundary() async throws {
    for checkpoint in [
      NestedRecoveryCheckpoint.prepared, .beforeChildNodeEffect, .afterChildNodeResult,
      .childTerminalPersisted, .parentIntentPersisted, .beforeParentPublication,
      .parentPublicationPersisted
    ] {
      let root = try taskDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let runtimeStore = InMemoryWorkflowRuntimeStore()
      let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
      let adapter = ProductionNestedAdapter()
      let runner = DeterministicWorkflowRunner(
        store: runtimeStore,
        adapter: adapter,
        calleeResolver: ProductionNestedCalleeResolver(),
        nestedInvocationPersistenceStore: persistence,
        nestedInvocationRecoveryCheckpointer: ThrowingNestedCheckpoint(target: checkpoint)
      )
      do {
        _ = try await runner.run(DeterministicWorkflowRunRequest(
          workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads()
        ))
        XCTFail("Expected controlled checkpoint stop at \(checkpoint.rawValue)")
      } catch {
        // The parent wraps a child-boundary stop as cross-workflow failure;
        // the durable record below is the asserted recovery evidence.
      }
      let latestParent = await runtimeStore.latestSession(workflowId: "production-parent")
      let parent = try XCTUnwrap(latestParent)
      let sourceExecutionId = try XCTUnwrap(parent.executions.first?.executionId)
      let record = try XCTUnwrap(try persistence.nestedInvocationRecord(
        parentSessionId: parent.sessionId, sourceStepExecutionId: sourceExecutionId, branchId: "cross-workflow"
      ), "\(checkpoint.rawValue) must preserve one child identity")
      let childExecutions = await adapter.calleeExecutions()
      if checkpoint == .prepared || checkpoint == .parentIntentPersisted || checkpoint == .beforeChildNodeEffect {
        XCTAssertEqual(childExecutions, 0)
        XCTAssertEqual(record.phase, .prepared)
      } else if checkpoint == .afterChildNodeResult || checkpoint == .childTerminalPersisted {
        XCTAssertEqual(childExecutions, 1)
        XCTAssertEqual(record.phase, .childTerminal)
      } else if checkpoint == .beforeParentPublication {
        XCTAssertEqual(childExecutions, 1)
        XCTAssertEqual(record.phase, .childTerminal)
      } else {
        XCTAssertEqual(childExecutions, 1)
        XCTAssertEqual(record.phase, .delivered)
      }
    }
  }

  func testProductionRunnerFailpointsReopenAndResumeOneNestedChildAndParentArrival() async throws {
    for checkpoint in [
      NestedRecoveryCheckpoint.prepared, .beforeChildNodeEffect, .afterChildNodeResult,
      .childTerminalPersisted, .beforeParentPublication, .parentPublicationPersisted
    ] {
      let root = try taskDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let runtimeStore = InMemoryWorkflowRuntimeStore()
      let parentSessionID = "reopen-parent-\(checkpoint.rawValue)"
      let parent = try await runtimeStore.createSession(WorkflowSessionCreateInput(
        sessionId: parentSessionID, workflowId: "production-parent", entryStepId: "dispatch"
      ))
      let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
      // The parent snapshot is explicit canonical recovery input. The second
      // runner below receives no shared in-memory state from the interrupted
      // process simulation.
      try persistence.save(WorkflowRuntimePersistenceSnapshot(session: parent))
      let interruptedAdapter = ProductionNestedAdapter()
      let directive = WorkflowCrossWorkflowDispatchDirective(
        workflowId: "production-child", calleeEntryStepId: "child", resumeStepId: "resume",
        transitionLabel: "completed", handoffPayload: ["handoff": .string("fixture")],
        sourceStepExecutionId: "loop-iteration-\(checkpoint.rawValue)"
      )
      var request = DeterministicWorkflowRunRequest(
        workflow: productionNestedCaller(), nodePayloads: productionNestedPayloads()
      )
      request.rootSessionId = parentSessionID
      let interrupted = DeterministicWorkflowRunner(
        store: runtimeStore, adapter: interruptedAdapter, calleeResolver: ProductionNestedCalleeResolver(),
        nestedInvocationPersistenceStore: persistence,
        nestedInvocationRecoveryCheckpointer: ThrowingNestedCheckpoint(target: checkpoint)
      )
      do {
        try await interrupted.dispatchCrossWorkflowCallee(
          directive: directive, parentSessionId: parentSessionID, parentStepId: "dispatch", request: request
        )
        XCTFail("Expected controlled checkpoint stop at \(checkpoint.rawValue)")
      } catch {
        // A process stop leaves the durable journal intact; the new runner is
        // intentionally constructed below to model reopening that journal.
      }

      let interruptedChildEffects = await interruptedAdapter.calleeExecutions()
      let reopenedStore = InMemoryWorkflowRuntimeStore()
      for snapshot in try persistence.loadAll() {
        await reopenedStore.seedSession(snapshot.session)
        await reopenedStore.seedWorkflowMessages(snapshot.workflowMessages)
      }
      let reopenedAdapter = ProductionNestedAdapter()
      let reopened = DeterministicWorkflowRunner(
        store: reopenedStore, adapter: reopenedAdapter, calleeResolver: ProductionNestedCalleeResolver(),
        nestedInvocationPersistenceStore: SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
      )
      do {
        try await reopened.dispatchCrossWorkflowCallee(
          directive: directive, parentSessionId: parentSessionID, parentStepId: "dispatch", request: request
        )
      } catch {
        XCTFail("\(checkpoint.rawValue) reopen failed: \(error)")
        continue
      }
      let reopenedChildEffects = await reopenedAdapter.calleeExecutions()
      XCTAssertEqual(
        interruptedChildEffects + reopenedChildEffects, 1,
        "\(checkpoint.rawValue) must reconstruct only canonical SQLite state and not duplicate the child effect"
      )
      let arrivals = try SQLiteWorkflowMessageLog(
        databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
      ).listMessages(workflowExecutionId: parentSessionID, toStepId: "resume")
      XCTAssertEqual(arrivals.count, 1, "\(checkpoint.rawValue) must recover exactly one parent arrival")
      let record = try XCTUnwrap(try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).nestedInvocationRecord(
        parentSessionId: parentSessionID, sourceStepExecutionId: directive.sourceStepExecutionId, branchId: "cross-workflow"
      ))
      XCTAssertEqual(record.phase, .delivered)
    }
  }

  func testActualLoopCheckpointInterruptsAndResumesTheProductionParentRunner() async throws {
    for checkpoint in [
      NestedRecoveryCheckpoint.prepared,
      .beforeChildNodeEffect,
      .afterChildNodeResult,
      .childTerminalPersisted,
      .beforeParentPublication,
      .parentPublicationPersisted
    ] {
      let root = try taskDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = InMemoryWorkflowRuntimeStore()
      let adapter = LoopThenNestedAdapter()
      let workflow = loopThenNestedCaller()
      let payloads = loopThenNestedPayloads()
      let interrupted = DeterministicWorkflowRunner(
        store: store,
        adapter: adapter,
        calleeResolver: ProductionNestedCalleeResolver(),
        nestedInvocationPersistenceStore: SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path),
        nestedInvocationRecoveryCheckpointer: ThrowingNestedCheckpoint(target: checkpoint)
      )
      do {
        _ = try await interrupted.run(DeterministicWorkflowRunRequest(
          workflow: workflow, nodePayloads: payloads, maxSteps: 8, disableDefaultLoopGuard: true
        ))
        XCTFail("Expected checkpoint interruption at \(checkpoint.rawValue)")
      } catch {
        // The interruption occurs after the real loop gate has selected its
        // cross-workflow transition. A new runner consumes its durable child
        // reservation rather than recreating a test-store record.
      }
      let gateExecutions = await adapter.gateExecutions()
      XCTAssertEqual(gateExecutions, 2, "The fixture must execute an actual loop before dispatch")
      let latestParent = await store.latestSession(workflowId: workflow.workflowId)
      let parent = try XCTUnwrap(latestParent)
      XCTAssertEqual(parent.status, .running, "A checkpoint interruption must leave the durable parent resumable")
      let request = DeterministicWorkflowRunRequest(
        workflow: workflow, nodePayloads: payloads, maxSteps: 8, disableDefaultLoopGuard: true
      )
      let reopened = DeterministicWorkflowRunner(
        store: store,
        adapter: adapter,
        calleeResolver: ProductionNestedCalleeResolver(),
        nestedInvocationPersistenceStore: SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
      )
      let resumed = try await reopened.run(DeterministicWorkflowRunRequest(
        workflow: request.workflow,
        nodePayloads: request.nodePayloads,
        maxSteps: request.maxSteps,
        disableDefaultLoopGuard: true,
        resumeSessionId: parent.sessionId
      ))
      XCTAssertEqual(resumed.status, .completed)
      let childExecutions = await adapter.childExecutions()
      XCTAssertEqual(childExecutions, 1, "\(checkpoint.rawValue) duplicated the loop child effect")
      let arrivals = try SQLiteWorkflowMessageLog(
        databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
      ).listMessages(workflowExecutionId: parent.sessionId, toStepId: "resume")
      XCTAssertEqual(arrivals.count, 1, "\(checkpoint.rawValue) must preserve one loop parent arrival")
    }
  }

  func testPersistentNestedReservationRecoversBeforeLaunchAndFencesConcurrentReopenPublication() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let parent = runtimeSnapshot(
      workflowId: "parent-workflow", sessionId: "parent", status: .running, date: date
    )
    try persistence.save(parent)
    let preparedChild = runtimeSnapshot(
      workflowId: "child-workflow", sessionId: "child", status: .created, date: date,
      parentSessionId: "parent"
    )
    let reservation = WorkflowNestedInvocationReservation(
      parentSessionId: "parent", parentStepId: "dispatch", resumeStepId: "resume",
      sourceStepExecutionId: "dispatch-execution", branchId: "branch-a", childSnapshot: preparedChild
    )

    // Failpoint: process stops after reservation and before launch. Reopen
    // sees the same child identity and has no parent arrival to replay.
    XCTAssertEqual(try persistence.reserveNestedInvocation(reservation).phase, .prepared)
    let afterPrelaunchCrash = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    XCTAssertEqual(try afterPrelaunchCrash.nestedInvocationRecord(reservation)?.phase, .prepared)
    XCTAssertEqual(try afterPrelaunchCrash.load(sessionId: "child").session.status, .created)
    XCTAssertTrue(try SQLiteWorkflowMessageLog(databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path))
      .listMessages(workflowExecutionId: "parent").isEmpty)

    let terminalChild = runtimeSnapshot(
      workflowId: "child-workflow", sessionId: "child", status: .completed, date: date.addingTimeInterval(1),
      parentSessionId: "parent"
    )
    XCTAssertEqual(
      try afterPrelaunchCrash.recordNestedChildTerminal(reservation: reservation, terminalSnapshot: terminalChild).phase,
      .childTerminal
    )

    // Failpoint: process stops after child terminal persistence and before
    // parent delivery. Two reopened connections race the same recovery work.
    let first = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let second = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let input = WorkflowMessageAppendInput(
      workflowExecutionId: "parent", fromStepId: "dispatch", toStepId: "resume",
      sourceStepExecutionId: "dispatch-execution", transitionCondition: "completed",
      payload: ["result": .string("completed")]
    )
    async let firstResult: WorkflowNestedInvocationRecord = Task.detached {
      try first.publishNestedParentMessage(reservation: reservation, input: input)
    }.value
    async let secondResult: WorkflowNestedInvocationRecord = Task.detached {
      try second.publishNestedParentMessage(reservation: reservation, input: input)
    }.value
    let results = try await [firstResult, secondResult]
    XCTAssertTrue(results.allSatisfy { $0.phase == .delivered })
    let reopened = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    XCTAssertEqual(try reopened.load(sessionId: "child").session.status, .completed)
    let arrivals = try SQLiteWorkflowMessageLog(databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path))
      .listMessages(workflowExecutionId: "parent", toStepId: "resume")
    XCTAssertEqual(arrivals.count, 1)
    XCTAssertEqual(try reopened.loadAll().filter { $0.session.sessionId == "child" }.count, 1)

    var changed = input
    changed.payload["result"] = .string("changed")
    XCTAssertThrowsError(try reopened.publishNestedParentMessage(reservation: reservation, input: changed))
  }

  func testNestedParentPublicationFenceAllowsOneConcurrentArrival() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    _ = try await store.createSession(WorkflowSessionCreateInput(
      sessionId: "parent", workflowId: "parent-workflow", entryStepId: "resume"
    ))
    let input = WorkflowMessageAppendInput(
      workflowExecutionId: "parent", fromStepId: "dispatch", toStepId: "resume",
      sourceStepExecutionId: "dispatch-execution", transitionCondition: "completed",
      payload: ["_rielaCrossWorkflow": .object([
        "workflowId": .string("child-workflow"), "sessionId": .string("child"), "status": .string("completed")
      ])]
    )
    async let first = store.appendWorkflowMessageOnce(input)
    async let second = store.appendWorkflowMessageOnce(input)
    let records = try await [first, second]
    XCTAssertEqual(records.map(\.communicationId).count, 2)
    XCTAssertEqual(Set(records.map(\.communicationId)).count, 1)
    let delivered = try await store.listMessages(for: "parent", toStepId: "resume")
    XCTAssertEqual(delivered.count, 1)

    var changed = input
    changed.payload["result"] = .string("different")
    do {
      _ = try await store.appendWorkflowMessageOnce(changed)
      XCTFail("Changed nested terminal payload must not create a second parent arrival")
    } catch let error as WorkflowRuntimeStoreError {
      XCTAssertEqual(error, .messageAppendRejected("nested parent publication conflicts with prior delivery"))
    }
  }

  func testPersistentFanoutTerminalSnapshotsFenceOneAggregateJoinAcrossReopenRaces() async throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try persistence.save(runtimeSnapshot(
      workflowId: "parent-workflow", sessionId: "parent", status: .running, date: date
    ))
    let reservations = ["fanout-a", "fanout-b"].map { branchId in
      WorkflowNestedInvocationReservation(
        parentSessionId: "parent", parentStepId: "dispatch", resumeStepId: "join",
        sourceStepExecutionId: "dispatch-execution", branchId: branchId,
        childSnapshot: runtimeSnapshot(
          workflowId: "child-workflow", sessionId: "child-\(branchId)", status: .created,
          date: date, parentSessionId: "parent"
        )
      )
    }
    for reservation in reservations {
      _ = try persistence.reserveNestedInvocation(reservation)
      _ = try persistence.recordNestedChildTerminal(
        reservation: reservation,
        terminalSnapshot: runtimeSnapshot(
          workflowId: "child-workflow", sessionId: reservation.childSnapshot.session.sessionId,
          status: .completed, date: date.addingTimeInterval(1), parentSessionId: "parent"
        )
      )
    }

    let input = WorkflowMessageAppendInput(
      workflowExecutionId: "parent", fromStepId: "dispatch", toStepId: "join",
      sourceStepExecutionId: "dispatch-execution", transitionCondition: "completed",
      payload: ["fanoutJoin": .object(["allBranchesCompleted": .bool(true)])]
    )
    let first = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let second = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    async let firstResult: [WorkflowNestedInvocationRecord] = Task.detached {
      try first.publishFanoutParentMessage(
        parentSessionId: "parent", sourceStepExecutionId: "dispatch-execution", input: input
      )
    }.value
    async let secondResult: [WorkflowNestedInvocationRecord] = Task.detached {
      try second.publishFanoutParentMessage(
        parentSessionId: "parent", sourceStepExecutionId: "dispatch-execution", input: input
      )
    }.value
    let results = try await [firstResult, secondResult]
    XCTAssertTrue(results.flatMap { $0 }.allSatisfy { $0.phase == .delivered })

    let reopened = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    for reservation in reservations {
      XCTAssertEqual(try reopened.nestedInvocationRecord(reservation)?.phase, .delivered)
      XCTAssertEqual(try reopened.load(sessionId: reservation.childSnapshot.session.sessionId).session.status, .completed)
    }
    let messages = try SQLiteWorkflowMessageLog(
      databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    ).listMessages(workflowExecutionId: "parent", toStepId: "join")
    XCTAssertEqual(messages.count, 1)
  }

  func testReservationPublishesCanonicalChildSnapshotBeforeLaunch() throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "a", actorId: "actor", roomId: "room")
    let request = SpecialistRequest(requestId: "request", sourceEventId: "event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version)
    _ = try store.reserveDispatch(taskId: task.taskId, dispatchId: "dispatch", childSessionId: "child", expectedVersion: claimed.version,
                                  workflowId: "workflow", workflowOriginId: "origin", workflowRevision: "sha256:pin", entryStepId: "entry", inputJSON: "{}")
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: root.appendingPathComponent("runtime-records").path
    ).load(sessionId: "child")
    XCTAssertEqual(snapshot.session.workflowId, "workflow")
    XCTAssertEqual(snapshot.session.sessionId, "child")
    XCTAssertEqual(snapshot.session.status, .created)
    XCTAssertEqual(try store.dispatch(dispatchId: "dispatch")?.state, .prepared)
  }

  func testClassificationRoundSealsAndNestedPublicationIsIdempotentAcrossReopen() throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room")
    let request = SpecialistRequest(requestId: "request-round", sourceEventId: "event-round", principal: principal, route: .work, body: "work")
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    _ = try store.accept(request)
    let started = try store.beginClassificationRound(SpecialistClassificationRound(
      requestId: request.requestId, configurationRevision: "sha256:configuration",
      catalogRevision: "sha256:catalog", deadline: Date().addingTimeInterval(30)
    ))
    XCTAssertFalse(started.sealed)
    let sealed = try store.sealClassificationRound(requestId: request.requestId, decisions: [
      SpecialistDecision(specialistId: "specialist", kind: .claim, reason: "bounded")
    ])
    XCTAssertTrue(sealed.sealed)
    XCTAssertThrowsError(try store.sealClassificationRound(requestId: request.requestId, decisions: [
      SpecialistDecision(specialistId: "other", kind: .claim)
    ]))

    let invocation = SpecialistNestedInvocation(
      rootDispatchId: "dispatch-root", parentSessionId: "parent", sourceExecutionId: "execution",
      transitionOrdinal: 0, branchId: "branch", childSessionId: "child"
    )
    XCTAssertEqual(try store.reserveNestedInvocation(invocation), invocation)
    let reopened = SpecialistSupervisorStore(rootDirectory: root.path)
    let published = try reopened.publishNestedResult(invocation, resultHash: "sha256:result")
    XCTAssertTrue(published.delivered)
    XCTAssertEqual(try reopened.publishNestedResult(invocation, resultHash: "sha256:result"), published)
    XCTAssertThrowsError(try reopened.publishNestedResult(invocation, resultHash: "sha256:changed"))
  }

  private func taskDirectory() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/recovery-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func runtimeSnapshot(
    workflowId: String,
    sessionId: String,
    status: WorkflowSessionStatus,
    date: Date,
    parentSessionId: String? = nil
  ) -> WorkflowRuntimePersistenceSnapshot {
    WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: workflowId,
      sessionId: sessionId,
      status: status,
      entryStepId: "entry",
      currentStepId: status == .completed ? nil : "entry",
      createdAt: date,
      updatedAt: date,
      parentSessionId: parentSessionId,
      rootSessionId: parentSessionId ?? sessionId
    ))
  }

  private func productionNestedCaller() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "production-parent",
      defaults: WorkflowDefaults(nodeTimeoutMs: 30_000, maxLoopIterations: 2),
      entryStepId: "dispatch",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "dispatch-node", nodeFile: "nodes/dispatch.json"),
        WorkflowNodeRegistryRef(id: "resume-node", nodeFile: "nodes/resume.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "dispatch", nodeId: "dispatch-node",
          transitions: [WorkflowStepTransition(
            toStepId: "child", toWorkflowId: "production-child", resumeStepId: "resume"
          )]
        ),
        WorkflowStepRef(id: "resume", nodeId: "resume-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "dispatch-node", nodeFile: "nodes/dispatch.json"),
        WorkflowNodeRef(id: "resume-node", nodeFile: "nodes/resume.json")
      ]
    )
  }

  private func productionNestedPayloads() -> [String: AgentNodePayload] {
    [
      "dispatch-node": AgentNodePayload(id: "dispatch-node", executionBackend: .codexAgent, model: "fixture"),
      "resume-node": AgentNodePayload(id: "resume-node", executionBackend: .codexAgent, model: "fixture")
    ]
  }

  private func loopThenNestedCaller() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "loop-then-nested-parent",
      defaults: WorkflowDefaults(nodeTimeoutMs: 30_000, maxLoopIterations: 3),
      entryStepId: "gate",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "gate-node", nodeFile: "nodes/gate.json"),
        WorkflowNodeRegistryRef(id: "dispatch-node", nodeFile: "nodes/dispatch.json"),
        WorkflowNodeRegistryRef(id: "resume-node", nodeFile: "nodes/resume.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "gate",
          nodeId: "gate-node",
          transitions: [
            WorkflowStepTransition(toStepId: "gate", label: "needs_work"),
            WorkflowStepTransition(toStepId: "dispatch", label: "!needs_work")
          ],
          loop: WorkflowStepLoopMetadata(role: "gate", gateId: "loop-before-child")
        ),
        WorkflowStepRef(
          id: "dispatch",
          nodeId: "dispatch-node",
          transitions: [WorkflowStepTransition(
            toStepId: "child", toWorkflowId: "production-child", resumeStepId: "resume"
          )]
        ),
        WorkflowStepRef(id: "resume", nodeId: "resume-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "gate-node", nodeFile: "nodes/gate.json"),
        WorkflowNodeRef(id: "dispatch-node", nodeFile: "nodes/dispatch.json"),
        WorkflowNodeRef(id: "resume-node", nodeFile: "nodes/resume.json")
      ]
    )
  }

  private func loopThenNestedPayloads() -> [String: AgentNodePayload] {
    [
      "gate-node": AgentNodePayload(id: "gate-node", executionBackend: .codexAgent, model: "fixture"),
      "dispatch-node": AgentNodePayload(id: "dispatch-node", executionBackend: .codexAgent, model: "fixture"),
      "resume-node": AgentNodePayload(id: "resume-node", executionBackend: .codexAgent, model: "fixture")
    ]
  }
}

private struct ProductionNestedCalleeResolver: WorkflowCalleeResolving {
  func resolveCallee(workflowId: String) async throws -> ResolvedWorkflowCallee {
    XCTAssertEqual(workflowId, "production-child")
    return ResolvedWorkflowCallee(
      workflow: WorkflowDefinition(
        workflowId: workflowId,
        defaults: WorkflowDefaults(nodeTimeoutMs: 30_000, maxLoopIterations: 2),
        entryStepId: "child",
        nodeRegistry: [WorkflowNodeRegistryRef(id: "child-node", nodeFile: "nodes/child.json")],
        steps: [WorkflowStepRef(id: "child", nodeId: "child-node")],
        nodes: [WorkflowNodeRef(id: "child-node", nodeFile: "nodes/child.json")]
      ),
      nodePayloads: ["child-node": AgentNodePayload(id: "child-node", executionBackend: .codexAgent, model: "fixture")]
    )
  }
}

private actor ProductionNestedAdapter: NodeAdapter {
  private var childExecutionCount = 0

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.node.id == "child" { childExecutionCount += 1 }
    let payload: JSONObject = input.node.id == "dispatch-node"
      ? ["handoff": .string("fixture")]
      : ["result": .string(input.node.id)]
    return AdapterExecutionOutput(
      provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
      payload: payload
    )
  }

  func calleeExecutions() -> Int { childExecutionCount }
}

private actor LoopThenNestedAdapter: NodeAdapter {
  private var gateCount = 0
  private var childCount = 0

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    switch input.node.id {
    case "gate":
      gateCount += 1
      return AdapterExecutionOutput(
        provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
        when: ["needs_work": gateCount == 1], payload: ["gate": .integer(Int64(gateCount))]
      )
    case "child":
      childCount += 1
      return AdapterExecutionOutput(
        provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
        payload: ["result": .string("child")]
      )
    default:
      return AdapterExecutionOutput(
        provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
        payload: ["result": .string(input.node.id)]
      )
    }
  }

  func gateExecutions() -> Int { gateCount }
  func childExecutions() -> Int { childCount }
}

private actor NestedCheckpointRecorder: NestedRecoveryCheckpointing {
  private var checkpoints: [NestedRecoveryCheckpoint] = []

  func reached(_ checkpoint: NestedRecoveryCheckpoint) async throws {
    checkpoints.append(checkpoint)
  }

  func observed() -> [NestedRecoveryCheckpoint] { checkpoints }
}

private struct ThrowingNestedCheckpoint: NestedRecoveryCheckpointing {
  let target: NestedRecoveryCheckpoint

  func reached(_ checkpoint: NestedRecoveryCheckpoint) async throws {
    guard checkpoint == target else { return }
    throw NestedRecoveryInterruption()
  }
}

private actor CancellingNestedAdapter: NodeAdapter {
  private var childExecutionCount = 0

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.node.id == "child" {
      childExecutionCount += 1
      throw CancellationError()
    }
    return AdapterExecutionOutput(
      provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
      payload: ["result": .string(input.node.id)]
    )
  }

  func calleeExecutions() -> Int { childExecutionCount }
}

private actor FailingNestedAdapter: NodeAdapter {
  private var childExecutionCount = 0

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.node.id == "child" {
      childExecutionCount += 1
      throw AdapterExecutionError(.providerError, "fixture child failure")
    }
    return AdapterExecutionOutput(
      provider: "fixture", model: "fixture", promptText: "fixture", completionPassed: true,
      payload: ["result": .string(input.node.id)]
    )
  }

  func calleeExecutions() -> Int { childExecutionCount }
}
