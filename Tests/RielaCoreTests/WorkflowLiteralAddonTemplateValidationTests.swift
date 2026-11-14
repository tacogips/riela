import XCTest
@testable import RielaCore

final class LiteralTemplateValidationTests: XCTestCase {
  func testWholePlaceholderInKVSetLiteralValueIsError() {
    let diagnostics = validate(addon: WorkflowNodeAddonRef(
      name: "riela/kv-set",
      config: ["value": .string("{{input.state}}")]
    ))

    let diagnostic = diagnostic(at: "workflow.nodes[0].addon.config.value", in: diagnostics)
    XCTAssertEqual(diagnostic?.severity, .error)
    XCTAssertTrue(diagnostic?.message.contains("stored literally") == true)
    XCTAssertTrue(diagnostic?.message.contains("config.valueTemplate") == true)
    XCTAssertTrue(diagnostic?.message.contains("cursor") == true)
  }

  func testEmbeddedPlaceholderInKVSetLiteralValueIsWarning() {
    let diagnostics = validate(addon: WorkflowNodeAddonRef(
      name: "riela/kv-set",
      config: ["value": .string("cursor={{input.state}}")]
    ))

    XCTAssertEqual(
      diagnostic(at: "workflow.nodes[0].addon.config.value", in: diagnostics)?.severity,
      .warning
    )
  }

  func testTemplateFieldAndPlainLiteralHaveNoDiagnostic() {
    let templateDiagnostics = validate(addon: WorkflowNodeAddonRef(
      name: "riela/kv-set",
      config: ["valueTemplate": .string("{{input.state}}")]
    ))
    let literalDiagnostics = validate(addon: WorkflowNodeAddonRef(
      name: "riela/kv-set",
      config: ["value": .object(["state": .string("ready")])]
    ))

    XCTAssertFalse(templateDiagnostics.contains { $0.path.contains(".config.value") })
    XCTAssertFalse(literalDiagnostics.contains { $0.path.contains(".config.value") })
  }

  func testNestedPlaceholderReportsNestedPath() {
    let diagnostics = validate(addon: WorkflowNodeAddonRef(
      name: "riela/kv-set",
      config: ["value": .object([
        "cursor": .string("{{input.state}}"),
        "history": .array([.string("previous"), .string("from {{input.source}}")])
      ])]
    ))

    XCTAssertEqual(diagnostic(at: "workflow.nodes[0].addon.config.value.cursor", in: diagnostics)?.severity, .error)
    XCTAssertEqual(diagnostic(at: "workflow.nodes[0].addon.config.value.history[1]", in: diagnostics)?.severity, .warning)
  }

  func testRenderedAddonInputValueIsNotReported() {
    let diagnostics = validate(addon: WorkflowNodeAddonRef(
      name: "riela/kv-set",
      inputs: ["value": .string("{{input.state}}")]
    ))

    XCTAssertTrue(diagnostics.filter { $0.path.contains(".addon.") }.isEmpty)
  }

  func testMemorySavePayloadUsesItsPayloadTemplatePair() {
    let diagnostics = validate(addon: WorkflowNodeAddonRef(
      name: "riela/memory-save",
      config: ["payload": .object(["text": .string("{{input.text}}")])]
    ))

    let diagnostic = diagnostic(at: "workflow.nodes[0].addon.config.payload.text", in: diagnostics)
    XCTAssertEqual(diagnostic?.severity, .error)
    XCTAssertTrue(diagnostic?.message.contains("config.payloadTemplate") == true)
  }

  private func validate(addon: WorkflowNodeAddonRef) -> [WorkflowValidationDiagnostic] {
    let workflow = WorkflowDefinition(
      workflowId: "literal-addon-template-validation",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "only",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "cursor", nodeFile: "nodes/cursor.json", addon: addon)],
      steps: [WorkflowStepRef(id: "only", nodeId: "cursor")],
      nodes: [WorkflowNodeRef(id: "cursor", nodeFile: "nodes/cursor.json")]
    )
    return DefaultWorkflowValidator().validate(workflow)
  }

  private func diagnostic(
    at path: String,
    in diagnostics: [WorkflowValidationDiagnostic]
  ) -> WorkflowValidationDiagnostic? {
    diagnostics.first { $0.path == path }
  }
}
