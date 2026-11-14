import XCTest
import RielaMemory
@testable import RielaCore

final class DeterministicWorkflowRunnerTests: XCTestCase {
  func testMultipleEnvelopeTransitionsFailClosedAfterOutputNormalization() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "left-node", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRegistryRef(id: "right-node", nodeFile: "nodes/right-node.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          transitions: [
            WorkflowStepTransition(toStepId: "left", label: "left"),
            WorkflowStepTransition(toStepId: "right", label: "right")
          ]
        ),
        WorkflowStepRef(id: "left", nodeId: "left-node"),
        WorkflowStepRef(id: "right", nodeId: "right-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "left", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRef(id: "right", nodeFile: "nodes/right-node.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: AdapterExecutionOutput(
        provider: "test",
        model: "gpt-5.5",
        promptText: "prompt",
        completionPassed: true,
        when: ["left": false, "right": false],
        payload: [
          "when": .object(["left": .bool(true), "right": .bool(true)]),
          "payload": .object(["status": .string("ok")])
        ]
      ))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": payload(),
        "left-node": payload(),
        "right-node": payload()
      ]
    )))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertEqual(session.executions.first?.failureReason, "invalid_output: multiple direct transitions are not supported by this sequential runner")
    XCTAssertNil(session.executions.first?.acceptedOutput)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testNegatedTransitionLabelPublishesWhenFlagIsFalse() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "next-node", nodeFile: "nodes/next-node.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          transitions: [WorkflowStepTransition(toStepId: "next", label: "!(needs_revision)")]
        ),
        WorkflowStepRef(id: "next", nodeId: "next-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "next", nodeFile: "nodes/next-node.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: output(when: ["needs_revision": false]))
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": payload(),
        "next-node": payload()
      ]
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.nodeExecutions, 2)
    XCTAssertEqual(result.transitions, 1)
    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: nil)
    XCTAssertEqual(messages.map(\.toStepId), ["next"])
  }

  func testMultipleExpressionTransitionsFailClosedUsingBranchEvaluator() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "left-node", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRegistryRef(id: "right-node", nodeFile: "nodes/right-node.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          transitions: [
            WorkflowStepTransition(toStepId: "left", label: "!(left)"),
            WorkflowStepTransition(toStepId: "right", label: "!(right)")
          ]
        ),
        WorkflowStepRef(id: "left", nodeId: "left-node"),
        WorkflowStepRef(id: "right", nodeId: "right-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "left", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRef(id: "right", nodeFile: "nodes/right-node.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: output(when: ["left": false, "right": false]))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": payload(),
        "left-node": payload(),
        "right-node": payload()
      ]
    )))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.failureReason, "invalid_output: multiple direct transitions are not supported by this sequential runner")
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testMessageAppendFailureDoesNotFabricateDownstreamMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore(appendFailurePredicate: { _ in "append blocked" })
    let workflow = workflow(transitions: [WorkflowStepTransition(toStepId: "step")])
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))

    await XCTAssertThrowsErrorAsync(try await runner.run(request(workflow: workflow)))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertNil(session.executions.first?.acceptedOutput)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testTimeoutOptionsPropagateAdapterDeadline() async throws {
    let adapter = DeadlineCapturingAdapter()
    let runner = DeterministicWorkflowRunner(adapter: adapter)

    _ = try await runner.run(request(timeoutMs: 500))

    let maybeDeadline = await adapter.capturedDeadline()
    let deadline = try XCTUnwrap(maybeDeadline)
    XCTAssertLessThanOrEqual(deadline.timeIntervalSinceNow, 0.5)
    XCTAssertGreaterThan(deadline.timeIntervalSinceNow, 0)
  }

  func testAddonOnlyNodePublishesThroughInjectedResolver() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = CapturingAddonResolver(output: output(payload: ["status": .string("addon-ok")]))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: addonWorkflow(),
      variables: ["request": .string("value")]
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.rootOutput, ["status": .string("addon-ok")])
    XCTAssertEqual(result.nodeExecutions, 1)
    let maybeCaptured = await resolver.capturedInput()
    let captured = try XCTUnwrap(maybeCaptured)
    XCTAssertEqual(captured.workflowId, "addon-runner")
    XCTAssertEqual(captured.stepId, "addon-step")
    XCTAssertEqual(captured.nodeId, "addon-node")
    XCTAssertEqual(captured.addon.name, "riela/native-runner")
    XCTAssertEqual(captured.variables["request"], .string("value"))
  }

  func testAddonOnlyNodeProjectsInlineAttachmentDescriptorsBeforeResolver() async throws {
    let resolver = CapturingAddonResolver(output: output(payload: ["status": .string("addon-ok")]))
    let runner = DeterministicWorkflowRunner(addonResolver: resolver)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: addonWorkflow(),
      addonAttachmentDescriptors: [
        "attachmentId": WorkflowAddonAttachmentDescriptor(
          id: "att_123",
          mediaType: "text/plain",
          filename: "note.txt",
          contentText: "hello native"
        )
      ]
    ))

    XCTAssertEqual(result.status, .completed)
    let maybeCaptured = await resolver.capturedInput()
    let captured = try XCTUnwrap(maybeCaptured)
    let attachment = try XCTUnwrap(captured.attachments["attachmentId"])
    XCTAssertEqual(attachment.id, "att_123")
    XCTAssertEqual(attachment.mediaType, "text/plain")
    XCTAssertEqual(attachment.filename, "note.txt")
    XCTAssertEqual(attachment.sizeBytes, "hello native".utf8.count)
    XCTAssertTrue(attachment.sha256.hasPrefix("sha256:"))
    XCTAssertEqual(attachment.contentText, "hello native")
    XCTAssertNil(attachment.contentBase64)
  }

  func testAddonOnlyNodeRejectsHostPathAttachmentDescriptorsBeforeResolver() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = CapturingAddonResolver(output: output(payload: ["status": .string("should-not-run")]))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver)

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: addonWorkflow(),
      addonAttachmentDescriptors: [
        "attachmentId": WorkflowAddonAttachmentDescriptor(
          id: "att_123",
          mediaType: "text/plain",
          filename: "note.txt",
          localPath: "/tmp/secret.txt"
        )
      ]
    )))

    let captured = await resolver.capturedInput()
    XCTAssertNil(captured)
    let maybeSession = await store.loadSessionForTest(id: "addon-runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertTrue(session.executions.first?.failureReason?.contains("native_attachment_metadata_only") == true)
  }

  func testAddonOnlyNodeWithoutResolverRecordsFailure() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(store: store)

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(workflow: addonWorkflow())))

    let maybeSession = await store.loadSessionForTest(id: "addon-runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertTrue(session.executions.first?.failureReason?.contains("missing add-on resolver") == true)
  }

  func testRunRendersHydratedPromptTemplateAndPromptVariantBeforeAdapterExecution() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      description: "fallback {{topic}}",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      prompts: WorkflowPrompts(workerSystemPromptTemplate: "workflow system {{topic}}"),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          description: "step fallback {{topic}}",
          role: .worker,
          promptVariant: "review"
        )
      ],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
    let node = AgentNodePayload(
      id: "node",
      executionBackend: .codexAgent,
      model: "gpt-5.5",
      systemPromptTemplate: "base system {{topic}}",
      promptTemplate: "base prompt {{topic}}",
      sessionStartPromptTemplate: "base start {{topic}}",
      promptVariants: [
        "review": NodePromptVariant(
          systemPromptTemplate: "variant system {{topic}}",
          promptTemplate: "variant prompt {{topic}} {{nodeId}} {{nodeKind}}",
          sessionStartPromptTemplate: "variant start {{topic}}"
        )
      ],
      variables: ["topic": .string("base")]
    )
    let runner = DeterministicWorkflowRunner(adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": node],
      variables: ["topic": .string("release")]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(
      input.promptText,
      "variant start release\n\nvariant prompt release step worker"
    )
    XCTAssertTrue(input.systemPromptText?.hasPrefix("workflow system release\n\nvariant system release") == true)
    XCTAssertTrue(input.systemPromptText?.contains(#""topic":"release""#) == true)
    XCTAssertFalse(input.promptText.contains("fallback"))
    XCTAssertFalse(input.promptText.contains("base prompt"))
    XCTAssertEqual(input.node.promptTemplateFile, nil)
    XCTAssertEqual(input.node.id, "step")
  }

  func testRunPreservesConfiguredPromptTemplateThatRendersEmpty() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      description: "workflow fallback",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          description: "step fallback must not run",
          role: .worker
        )
      ],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
    let node = AgentNodePayload(
      id: "node",
      executionBackend: .codexAgent,
      model: "gpt-5.5",
      promptTemplate: "{{ missing.path }}"
    )
    let runner = DeterministicWorkflowRunner(adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": node]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(input.promptText, "")
    XCTAssertFalse(input.promptText.contains("fallback"))
  }

  func testMaxLoopIterationsBoundsDeterministicRun() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let recorder = WorkflowRunEventRecorder()
    let loopingWorkflow = workflow(
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 10),
      transitions: [WorkflowStepTransition(toStepId: "step")]
    )
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))

    do {
      _ = try await runner.run(request(
        workflow: loopingWorkflow,
        maxLoopIterations: 1,
        eventHandler: { event in
          await recorder.append(event)
        }
      ))
      XCTFail("expected maxStepsExceeded")
    } catch DeterministicWorkflowRunnerError.maxStepsExceeded(let maxSteps) {
      XCTAssertEqual(maxSteps, 2)
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.failureKind, .maxStepsExceeded)
    XCTAssertEqual(session.failureReason, "maxStepsExceeded(2)")
    XCTAssertEqual(session.stepBudgetDiagnostic?.stepBudget, 2)
    XCTAssertEqual(session.stepBudgetDiagnostic?.executionCount, 2)
    XCTAssertEqual(session.stepBudgetDiagnostic?.perStepExecutionCounts, ["step": 2])
    XCTAssertEqual(session.stepBudgetDiagnostic?.dominantCycleStepIds, ["step"])
    XCTAssertEqual(session.stepBudgetDiagnostic?.dominantCycleRepeatCount, 3)
    XCTAssertEqual(session.stepBudgetDiagnostic?.perStepRevisitCap, 2)
    XCTAssertEqual(session.stepBudgetDiagnostic?.projectedCapExceededStepIds, ["step"])
    XCTAssertEqual(session.stepBudgetDiagnostic?.unscheduledStepId, "step")

    let events = await recorder.events()
    XCTAssertEqual(events.last?.type, .sessionCompleted)
    XCTAssertEqual(events.last?.status, .failed)
  }

  func testResumeAllowsBudgetFailedSessionWithRaisedBudget() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = twoStepWorkflow()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StepCapturingAdapter(outputsByStep: [
        "step-a": output(payload: ["status": .string("first")]),
        "step-b": output(payload: ["status": .string("second")])
      ])
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: nodePayloads(for: workflow),
        maxSteps: 1
      ))
      XCTFail("expected maxStepsExceeded")
    } catch DeterministicWorkflowRunnerError.maxStepsExceeded(let maxSteps) {
      XCTAssertEqual(maxSteps, 1)
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    let maybeFailed = await store.loadSessionForTest(id: "rerun-runner-session-1")
    let failed = try XCTUnwrap(maybeFailed)
    XCTAssertEqual(failed.status, .failed)
    XCTAssertEqual(failed.failureKind, .maxStepsExceeded)
    XCTAssertEqual(failed.currentStepId, "step-b")

    let resumed = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow),
      maxSteps: 3,
      resumeSessionId: failed.sessionId
    ))

    XCTAssertEqual(resumed.session.sessionId, failed.sessionId)
    XCTAssertEqual(resumed.session.status, .completed)
    XCTAssertNil(resumed.session.failureKind)
    XCTAssertEqual(resumed.session.effectiveStepBudget, 3)
    XCTAssertEqual(resumed.session.executions.map(\.stepId), ["step-a", "step-b"])
  }

  func testResumePreStepFailureOverwritesPreviousBudgetFailureMetadata() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = twoStepWorkflow()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StepCapturingAdapter(outputsByStep: [
        "step-a": output(payload: ["status": .string("first")]),
        "step-b": output(payload: ["status": .string("second")])
      ])
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: nodePayloads(for: workflow),
        maxSteps: 1
      ))
      XCTFail("expected maxStepsExceeded")
    } catch DeterministicWorkflowRunnerError.maxStepsExceeded {
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    let maybeFailed = await store.loadSessionForTest(id: "rerun-runner-session-1")
    let failed = try XCTUnwrap(maybeFailed)
    XCTAssertEqual(failed.failureKind, .maxStepsExceeded)
    XCTAssertNotNil(failed.stepBudgetDiagnostic)

    let cancellingResumeRunner = DeterministicWorkflowRunner(
      store: store,
      adapter: StepCapturingAdapter(outputsByStep: [
        "step-a": output(payload: ["status": .string("first")]),
        "step-b": output(payload: ["status": .string("second")])
      ]),
      inputResolver: StepCancellingInputResolver(cancelledStepId: "step-b")
    )

    do {
      _ = try await cancellingResumeRunner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: nodePayloads(for: workflow),
        maxSteps: 3,
        resumeSessionId: failed.sessionId
      ))
      XCTFail("expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    let maybeOverwritten = await store.loadSessionForTest(id: failed.sessionId)
    let overwritten = try XCTUnwrap(maybeOverwritten)
    XCTAssertEqual(overwritten.status, .failed)
    XCTAssertEqual(overwritten.failureKind, .cancelled)
    XCTAssertEqual(overwritten.failureReason, "workflow run cancelled")
    XCTAssertNil(overwritten.stepBudgetDiagnostic)
    XCTAssertEqual(overwritten.effectiveStepBudget, 3)

    let terminalResume = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow),
      maxSteps: 3,
      resumeSessionId: failed.sessionId
    ))

    XCTAssertEqual(terminalResume.status, .failed)
    XCTAssertEqual(terminalResume.exitCode, 1)
    XCTAssertEqual(terminalResume.session.failureKind, .cancelled)
    XCTAssertEqual(terminalResume.session.effectiveStepBudget, 3)
  }

  func testRerunCreatesNewSessionStartingAtRequestedStep() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = twoStepWorkflow()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StepCapturingAdapter(outputsByStep: [
        "step-a": output(payload: ["status": .string("first")]),
        "step-b": output(payload: ["status": .string("second")])
      ])
    )

    let first = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow)
    ))
    XCTAssertEqual(first.status, .completed)
    XCTAssertEqual(first.session.executions.map(\.stepId), ["step-a", "step-b"])
    XCTAssertEqual(first.recovery?.entryMode, .run)
    XCTAssertEqual(first.recovery?.inputReusePolicy, "fresh-input")

    let rerun = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow),
      rerunFromSessionId: first.session.sessionId,
      rerunFromStepId: "step-b"
    ))

    XCTAssertNotEqual(rerun.session.sessionId, first.session.sessionId)
    XCTAssertEqual(rerun.status, .completed)
    XCTAssertEqual(rerun.session.executions.map(\.stepId), ["step-b"])
    XCTAssertEqual(rerun.rootOutput?["status"], .string("second"))
    XCTAssertEqual(rerun.recovery?.entryMode, .rerun)
    XCTAssertEqual(rerun.recovery?.sourceSessionId, first.session.sessionId)
    XCTAssertEqual(rerun.recovery?.sourceStepId, "step-b")
    XCTAssertEqual(rerun.recovery?.sourceStepExecutionId, first.session.executions.last?.executionId)
    XCTAssertEqual(rerun.recovery?.parentSessionId, first.session.sessionId)
    XCTAssertEqual(rerun.recovery?.childSessionIds, [rerun.session.sessionId])

    let terminalResume = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow),
      resumeSessionId: rerun.session.sessionId
    ))

    XCTAssertEqual(terminalResume.session.sessionId, rerun.session.sessionId)
    XCTAssertEqual(terminalResume.recovery?.entryMode, .resume)
    XCTAssertEqual(terminalResume.recovery?.sourceSessionId, rerun.session.sessionId)
    XCTAssertEqual(terminalResume.recovery?.inputReusePolicy, "existing-session")
  }

  func testRerunInjectsUnresolvedHighAndMidReviewFindingsIntoWorkerPrompt() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = twoStepWorkflow()
    let date = Date(timeIntervalSince1970: 100)
    let sourceSession = WorkflowSession(
      workflowId: workflow.workflowId,
      sessionId: "rerun-runner-session-20",
      status: .completed,
      entryStepId: "step-a",
      currentStepId: "step-b",
      createdAt: date,
      updatedAt: date,
      reviewFindings: [
        WorkflowReviewFinding(
          id: "finding-high",
          issueReference: "owner/repo#123",
          workflowMode: "issue-resolution",
          sourceReviewStepId: "review",
          sourceStepExecutionId: "review-exec",
          sourceExecutionAttempt: 1,
          targetStepId: "step-b",
          filePath: "Sources/App.swift",
          line: 42,
          severity: .high,
          message: "Preserve review feedback.",
          feedback: "Use persisted review context.",
          originatingSessionId: "rerun-runner-session-20",
          createdAt: date
        ),
        WorkflowReviewFinding(
          id: "finding-low",
          sourceReviewStepId: "review",
          sourceStepExecutionId: "review-exec",
          sourceExecutionAttempt: 1,
          severity: .low,
          message: "Cosmetic note.",
          originatingSessionId: "rerun-runner-session-20",
          createdAt: date
        )
      ]
    )
    await store.seedSession(sourceSession)
    let adapter = InputCapturingAdapter()
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter)

    let rerun = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow),
      rerunFromSessionId: sourceSession.sessionId,
      rerunFromStepId: "step-b"
    ))

    XCTAssertEqual(rerun.status, .completed)
    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertTrue(input.systemPromptText?.contains("Prior unresolved high and mid review findings") == true)
    XCTAssertTrue(input.systemPromptText?.contains("Preserve review feedback.") == true)
    XCTAssertTrue(input.systemPromptText?.contains("Use persisted review context.") == true)
    XCTAssertFalse(input.systemPromptText?.contains("Cosmetic note.") == true)
    guard case let .array(findings)? = input.mergedVariables["priorReviewFindings"],
          case let .object(finding)? = findings.first else {
      return XCTFail("expected priorReviewFindings")
    }
    XCTAssertEqual(findings.count, 1)
    XCTAssertEqual(finding["id"], .string("finding-high"))
    XCTAssertEqual(finding["severity"], .string("high"))
    XCTAssertEqual(finding["targetStepId"], .string("step-b"))
  }

  func testRerunRejectsUnknownStepWithStepOrientedMessage() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = twoStepWorkflow()
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))
    let first = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow)
    ))

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: nodePayloads(for: workflow),
        rerunFromSessionId: first.session.sessionId,
        rerunFromStepId: "missing-step"
      ))
      XCTFail("expected rerun validation failure")
    } catch let error as DeterministicWorkflowRunnerError {
      guard case let .rerunValidation(message) = error else {
        return XCTFail("expected rerunValidation error")
      }
      XCTAssertEqual(message, "unknown rerun step 'missing-step'")
    }
  }

  func testMemoryGuidanceUsesDeclaredNodeIdWhenStepIdDiffers() async throws {
    let workflow = WorkflowDefinition(
      workflowId: "memory-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "persona-step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "persona-node",
          nodeFile: "nodes/persona.json",
          memories: [
            WorkflowMemoryDeclaration(id: "persona-events", description: "chronological persona events")
          ]
        )
      ],
      steps: [WorkflowStepRef(id: "persona-step", nodeId: "persona-node", role: .worker)],
      nodes: [
        WorkflowNodeRef(
          id: "persona-step",
          nodeFile: "nodes/persona.json",
          role: .worker,
          memories: [
            WorkflowMemoryDeclaration(id: "persona-summary", description: "summarized persona memory")
          ]
        )
      ]
    )
    let adapter = InputCapturingAdapter()
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["persona-node": AgentNodePayload(id: "persona-node", executionBackend: .codexAgent, model: "gpt-5.4-mini")]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertTrue(input.systemPromptText?.contains("persona-events") == true)
    XCTAssertTrue(input.systemPromptText?.contains("persona-summary") == true)
    XCTAssertTrue(input.systemPromptText?.contains("--workflow-id memory-runner") == true)
    XCTAssertTrue(input.systemPromptText?.contains("--node-id persona-node") == true)
    guard case let .object(availableMemories)? = input.mergedVariables["availableMemories"],
      case let .array(nodeMemories)? = availableMemories["node"]
    else {
      return XCTFail("expected availableMemories.node")
    }
    XCTAssertEqual(nodeMemories.count, 2)
  }

  func testRegisteredMemoryMetadataPrefersNodePurposeAndFillsWorkflowDefaults() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-memory-metadata-\(UUID().uuidString)", isDirectory: true)
      .path
    defer { try? FileManager.default.removeItem(atPath: root) }
    let workflow = WorkflowDefinition(
      workflowId: "memory-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      memories: [
        WorkflowMemoryDeclaration(
          id: "persona-memory",
          description: "workflow description",
          purpose: "workflow purpose",
          scope: .crossWorkflow,
          defaultLimit: 12
        )
      ],
      entryStepId: "persona-step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "persona-node",
          nodeFile: "nodes/persona.json",
          memories: [
            WorkflowMemoryDeclaration(id: "persona-memory", purpose: "node-specific purpose")
          ]
        )
      ],
      steps: [WorkflowStepRef(id: "persona-step", nodeId: "persona-node", role: .worker)],
      nodes: [WorkflowNodeRef(id: "persona-step", nodeFile: "nodes/persona.json")]
    )
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: StaticAdapter(output: output()))

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["persona-node": AgentNodePayload(id: "persona-node", executionBackend: .codexAgent, model: "gpt-5.4-mini")],
      memoryRootDirectory: root
    ))

    let metadata = try XCTUnwrap(RielaMemoryStore(rootDirectory: root).metadata(memoryId: "persona-memory"))
    XCTAssertEqual(metadata.description, "workflow description")
    XCTAssertEqual(metadata.purpose, "node-specific purpose")
  }

  func testStepSessionPolicyIsPassedToAdapterInput() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "session-policy-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "verify",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "verify-node", nodeFile: "nodes/verify.json")],
      steps: [
        WorkflowStepRef(
          id: "verify",
          nodeId: "verify-node",
          sessionPolicy: WorkflowStepSessionPolicy(mode: .new)
        )
      ],
      nodes: [WorkflowNodeRef(id: "verify", nodeFile: "nodes/verify.json")]
    )
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "verify-node": AgentNodePayload(
          id: "verify-node",
          executionBackend: .codexAgent,
          model: "gpt-5.5"
        )
      ]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(input.sessionPolicy?.mode, .new)
    XCTAssertNil(input.sessionPolicy?.inheritFromStepId)
  }

  func testStepSessionPolicyOverridesNodeSessionPolicy() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "session-policy-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "worker",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "worker-node", nodeFile: "nodes/worker.json")],
      steps: [
        WorkflowStepRef(
          id: "worker",
          nodeId: "worker-node",
          sessionPolicy: WorkflowStepSessionPolicy(mode: .new)
        )
      ],
      nodes: [WorkflowNodeRef(id: "worker", nodeFile: "nodes/worker.json")]
    )
    let node = AgentNodePayload(
      id: "worker-node",
      executionBackend: .codexAgent,
      model: "gpt-5.5",
      sessionPolicy: WorkflowStepSessionPolicy(mode: .reuse, inheritFromStepId: "worker")
    )
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["worker-node": node]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(input.sessionPolicy?.mode, .new)
    XCTAssertNil(input.sessionPolicy?.inheritFromStepId)
  }

  func testNodeSessionPolicyIsPassedToAdapterInputWhenStepDoesNotOverride() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "session-policy-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "worker",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "worker-node", nodeFile: "nodes/worker.json")],
      steps: [WorkflowStepRef(id: "worker", nodeId: "worker-node")],
      nodes: [WorkflowNodeRef(id: "worker", nodeFile: "nodes/worker.json")]
    )
    let node = AgentNodePayload(
      id: "worker-node",
      executionBackend: .codexAgent,
      model: "gpt-5.5",
      sessionPolicy: WorkflowStepSessionPolicy(mode: .reuse, inheritFromStepId: "worker")
    )
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["worker-node": node]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(input.sessionPolicy?.mode, .reuse)
    XCTAssertEqual(input.sessionPolicy?.inheritFromStepId, "worker")
  }

}
