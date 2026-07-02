import Foundation

extension DeterministicWorkflowRunner {
  func workflowOutputContract(from output: NodeOutputContract?) -> WorkflowOutputContract? {
    guard let output else {
      return nil
    }
    return WorkflowOutputContract(schema: output.jsonSchema, requiredObject: true)
  }

  func maxValidationAttempts(from output: NodeOutputContract?) -> Int {
    max(1, output?.maxValidationAttempts ?? 1)
  }

  func payload(_ basePayload: AgentNodePayload, applyingPromptVariantFrom step: WorkflowStepRef) throws -> AgentNodePayload {
    guard let promptVariantName = step.promptVariant else {
      return basePayload
    }
    guard let promptVariant = basePayload.promptVariants?[promptVariantName] else {
      throw DeterministicWorkflowRunnerError.missingPromptVariant(step.id, promptVariantName)
    }

    var payload = basePayload
    if promptVariant.systemPromptTemplate != nil || promptVariant.systemPromptTemplateFile != nil {
      payload.systemPromptTemplate = promptVariant.systemPromptTemplate
      payload.systemPromptTemplateFile = promptVariant.systemPromptTemplateFile
    }
    if promptVariant.promptTemplate != nil || promptVariant.promptTemplateFile != nil {
      payload.promptTemplate = promptVariant.promptTemplate
      payload.promptTemplateFile = promptVariant.promptTemplateFile
    }
    if promptVariant.sessionStartPromptTemplate != nil || promptVariant.sessionStartPromptTemplateFile != nil {
      payload.sessionStartPromptTemplate = promptVariant.sessionStartPromptTemplate
      payload.sessionStartPromptTemplateFile = promptVariant.sessionStartPromptTemplateFile
    }
    return payload
  }

  func promptVariables(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload,
    requestVariables: JSONObject,
    resolvedInputPayload: JSONObject
  ) -> JSONObject {
    var variables = payload.variables
    for (key, value) in requestVariables {
      variables[key] = value
    }
    for (key, value) in resolvedInputPayload {
      variables[key] = value
    }
    variables["runtimeVariables"] = .object(runtimeVariables(
      requestVariables: requestVariables,
      resolvedInputPayload: resolvedInputPayload
    ))
    variables["workflowId"] = .string(workflow.workflowId)
    variables["workflowDescription"] = .string(workflow.description)
    variables["nodeId"] = .string(step.id)
    variables["nodeKind"] = .string(step.role?.rawValue ?? "task")
    let nodeMemories = effectiveNodeMemories(workflow: workflow, step: step, payload: payload)
    variables["availableMemories"] = .object([
      "workflow": .array((workflow.memories ?? []).map(memoryJSON)),
      "node": .array(nodeMemories.map(memoryJSON))
    ])
    variables["memoryCommandHelp"] = .string(memoryCommandHelp(
      workflowId: workflow.workflowId,
      nodeId: step.nodeId,
      workflowMemories: workflow.memories ?? [],
      nodeMemories: nodeMemories
    ))
    return variables
  }

  private func runtimeVariables(requestVariables: JSONObject, resolvedInputPayload: JSONObject) -> JSONObject {
    var variables = requestVariables
    for (key, value) in resolvedInputPayload {
      variables[key] = value
    }
    return variables
  }

  func composedPrompts(
    workflow: WorkflowDefinition,
    step: WorkflowStepRef,
    payload: AgentNodePayload,
    variables: JSONObject
  ) -> (promptText: String, systemPromptText: String?) {
    let fallbackPrompt = step.description ?? workflow.description
    let usesConfiguredPromptTemplate = payload.promptTemplate != nil
    let promptTemplate = payload.promptTemplate ?? fallbackPrompt
    let sessionStartPrompt = payload.sessionStartPromptTemplate.map {
      renderPromptTemplate($0, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
    } ?? ""
    let promptText = renderPromptTemplate(promptTemplate, variables: variables)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let renderedPromptText = [sessionStartPrompt, promptText]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")

    let renderedSystemPromptTemplates = [
      workflow.prompts?.workerSystemPromptTemplate,
      payload.systemPromptTemplate
    ]
      .compactMap { template in
        template.map {
          renderPromptTemplate($0, variables: variables)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }

    let systemPromptText = (
      renderedSystemPromptTemplates + [
      runtimeVariablesPrompt(variables: variables),
      priorReviewFeedbackPrompt(variables: variables),
      memoryGuidance(variables: variables)
      ]
    )
      .compactMap { template in
        template?.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")

    return (
      promptText: renderedPromptText.isEmpty && !usesConfiguredPromptTemplate ? fallbackPrompt : renderedPromptText,
      systemPromptText: systemPromptText.isEmpty ? nil : systemPromptText
    )
  }

  private func runtimeVariablesPrompt(variables: JSONObject) -> String? {
    guard case let .object(runtimeVariables)? = variables["runtimeVariables"], !runtimeVariables.isEmpty else {
      return nil
    }
    guard let rendered = try? JSONValue.object(runtimeVariables).compactJSONString() else {
      return nil
    }
    return """
    Runtime variables are available under `runtimeVariables`. Use this JSON as the authoritative runtimeVariables object:
    \(rendered)
    """
  }

  private func priorReviewFeedbackPrompt(variables: JSONObject) -> String? {
    guard case let .string(feedback)? = variables["priorReviewFeedback"] else {
      return nil
    }
    let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    return "Prior unresolved high and mid review findings for this rerun:\n\(trimmed)"
  }

  func multiplePublishableTransitionFailure(
    transitions: [WorkflowStepTransition],
    candidate: RuntimeOutputCandidate
  ) -> AdapterExecutionError? {
    let evaluator = WorkflowBranchEvaluator()
    let publishableCount = transitions.filter { transition in
      evaluator.evaluate(label: transition.label, when: candidate.when, payload: candidate.payload)
    }.count
    guard publishableCount > 1 else {
      return nil
    }
    return AdapterExecutionError(
      .invalidOutput,
      "multiple direct transitions are not supported by this sequential runner"
    )
  }

  func deadline(for step: WorkflowStepRef, request: DeterministicWorkflowRunRequest) -> Date? {
    let timeoutMs = request.timeoutMs ?? step.timeoutMs ?? request.defaultTimeoutMs ?? request.workflow.defaults.nodeTimeoutMs
    guard timeoutMs > 0 else {
      return nil
    }
    return Date(timeIntervalSinceNow: Double(timeoutMs) / 1000)
  }
}
