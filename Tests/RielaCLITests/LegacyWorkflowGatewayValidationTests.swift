import Foundation
import RielaAddonSupport
import RielaCore
import XCTest
@testable import RielaCLI

final class LegacyWorkflowGatewayValidationTests: XCTestCase {
  func testXEmbeddedValidationMatchesShapeAndRuntimeMediaChecks() throws {
    let valid: JSONObject = [
      "operation": .string("homeTimeline"), "arguments": .object([:]),
      "selection": .array([.string("posts.id")])
    ]
    let templatedMediaKey: JSONObject = [
      "operation": .string("homeTimeline"),
      "arguments": .object(["mediaRootDir": .string("{{input.path}}")]),
      "selection": .array([.string("posts.id")])
    ]
    let deepSelection = [JSONValue.string((0..<17).map { "field\($0)" }.joined(separator: "."))]
    let cases: [(JSONObject, Bool)] = [
      (valid, true),
      (valid.merging(["selection": .array([.string("id")]), "select": .object(["id": .bool(true)])]) { _, rhs in rhs }, false),
      (["operation": .string("{{input.operation}}"), "selection": .array([.string("id")])], false),
      (valid.merging(["arguments": .object(["mediaRootDir": .string("/tmp")])]) { _, rhs in rhs }, false),
      (templatedMediaKey, false),
      (valid.merging(["selection": .array(deepSelection)]) { _, rhs in rhs }, false)
    ]
    for (config, expected) in cases {
      let errors = validationErrors("riela/x-gateway-reader", config: config)
      XCTAssertEqual(errors.isEmpty, expected, "validation: \(config)")
      XCTAssertEqual(runtimeAcceptsXEmbedded(config), expected, "runtime: \(config)")
    }
    let unknownOperation = valid.merging(["operation": .string("notAnXOperation")]) { _, rhs in rhs }
    XCTAssertTrue(validationErrors("riela/x-gateway-reader", config: unknownOperation).contains {
      $0.path.hasSuffix(".addon.config.operation") && $0.message == "unknown operation 'notAnXOperation'"
    })

    let unsupportedFailure: JSONObject = [
      "operation": .string("homeTimeline"), "providerFailure": .string("retry"),
      "selection": .array([.string("posts.id")])
    ]
    XCTAssertTrue(validationErrors("riela/x-gateway-reader", config: unsupportedFailure).contains {
      $0.path.hasSuffix(".addon.config.providerFailure")
        && $0.message.contains("must be \"fail\" or \"output\"")
    })
    // Runtime mode handling is wired by gwjson176-03; this plan pins parsing and static validation.
    XCTAssertThrowsError(try XGatewayProviderFailureMode.parse(unsupportedFailure))
    XCTAssertEqual(try XGatewayProviderFailureMode.parse([:]), .fail)
  }

  func testXContainerValidationMatchesOperationBuilderLimitsAndLegacyMode() throws {
    let valid: JSONObject = [
      "operation": .string("homeTimeline"), "arguments": .object([:]),
      "selection": .array([.string("posts.id")])
    ]
    XCTAssertTrue(validationErrors("riela/x-gateway-read", config: valid).isEmpty)
    XCTAssertNotNil(try ContainerGatewayAddonExecutor.operationDocument(
      gateway: .xRead, config: valid, variables: [:], addonName: "riela/x-gateway-read"
    ))

    let oversized: JSONObject = [
      "operation": .string("homeTimeline"),
      "arguments": .object(["paginationToken": .string(String(repeating: "x", count: 120_000))]),
      "selection": .array([.string("posts.id")])
    ]
    XCTAssertFalse(validationErrors("riela/x-gateway-read", config: oversized).isEmpty)
    XCTAssertThrowsError(try ContainerGatewayAddonExecutor.operationDocument(
      gateway: .xRead, config: oversized, variables: [:], addonName: "riela/x-gateway-read"
    ))

    let missingLegacyTemplate: JSONObject = ["arguments": .object([:])]
    let missingLegacyErrors = validationErrors("riela/x-gateway-read", config: missingLegacyTemplate)
    XCTAssertEqual(missingLegacyErrors.count, 1)
    XCTAssertEqual(missingLegacyErrors[0].message,
      "riela/x-gateway-read config.queryTemplate is required; JSON arguments require operation")
    XCTAssertThrowsError(try ContainerGatewayAddonExecutor.legacyModeIssue(
      config: missingLegacyTemplate, addonName: "riela/x-gateway-read"
    ))
    let legacy: JSONObject = ["queryTemplate": .string("query { accountMe { id } }")]
    XCTAssertTrue(validationErrors("riela/x-gateway-read", config: legacy).isEmpty)
    XCTAssertNoThrow(try ContainerGatewayAddonExecutor.legacyModeIssue(config: legacy, addonName: "riela/x-gateway-read"))
  }

  func testLegacyGmailValidationMatchesReaderBuilder() throws {
    let valid: JSONObject = [
      "operation": .string("account"), "arguments": .object(["id": .string("personal")]),
      "selection": .array([.string("id")])
    ]
    XCTAssertTrue(validationErrors("riela/gmail-gateway-read", config: valid).isEmpty)
    XCTAssertNotNil(try ContainerGatewayAddonExecutor.operationDocument(
      gateway: .gmailRead, config: valid, variables: [:], addonName: "riela/gmail-gateway-read"
    ))

    let unknown: JSONObject = ["operation": .string("sendMessage"), "arguments": .object([:])]
    XCTAssertFalse(validationErrors("riela/gmail-gateway-read", config: unknown).isEmpty)
    XCTAssertThrowsError(try ContainerGatewayAddonExecutor.operationDocument(
      gateway: .gmailRead, config: unknown, variables: [:], addonName: "riela/gmail-gateway-read"
    ))

    let templatedUnknown: JSONObject = ["operation": .string("unknown"), "arguments": .object(["id": .string("{{input.id}}")])]
    XCTAssertTrue(validationErrors("riela/gmail-gateway-read", config: templatedUnknown).contains {
      $0.path.hasSuffix(".addon.config.operation") && $0.message.contains("unknown operation 'unknown'")
    })
    XCTAssertThrowsError(try ContainerGatewayAddonExecutor.operationDocument(
      gateway: .gmailRead, config: templatedUnknown, variables: [:], addonName: "riela/gmail-gateway-read"
    ))

    let forbiddenSelect = valid.merging(["select": .object(["id": .bool(true)])]) { _, rhs in rhs }
    XCTAssertFalse(validationErrors("riela/gmail-gateway-read", config: forbiddenSelect).isEmpty)
    XCTAssertThrowsError(try ContainerGatewayAddonExecutor.operationDocument(
      gateway: .gmailRead, config: forbiddenSelect, variables: [:], addonName: "riela/gmail-gateway-read"
    ))
  }

  func testGoogleServiceValidationMatchesSharedShapeAndValueParsing() throws {
    let name = "riela/google-service-gateway-read"
    let valid: JSONObject = [
      "operation": .string("services.get"),
      "arguments": .object(["project": .string("sample"), "service": .string("calendar")])
    ]
    assertGoogleServiceParity(name: name, config: valid, expected: true)

    let cases: [(JSONObject, Bool)] = [
      (valid.merging(["arguments": .object(["project": .string("p"), "service": .string("s"), "unknown": .string("x")])]) { _, rhs in rhs }, false),
      (["operation": .string("services.get"), "arguments": .object(["project": .string("p"), "service": .number(10)])], false),
      (["operation": .string("services.list"), "arguments": .object(["project": .string("p"), "pageSize": .string("10")])], false),
      (["operation": .string("services.list"), "arguments": .object(["project": .string("p"), "state": .string("bogus")])], false),
      (["operation": .string("services.list"), "arguments": .object(["project": .string("p"), "pageToken": .null])], false),
      (["operation": .string("services.enable"), "arguments": .object([:])], false),
      (valid.merging(["project": .string("mixed")]) { _, rhs in rhs }, false),
      (["operation": .string("services.get"), "arguments": .object(["project": .string("{{input.project}}"), "service": .string("calendar")])], true)
    ]
    for (config, expected) in cases { assertGoogleServiceParity(name: name, config: config, expected: expected) }

    let writeName = "riela/google-service-gateway-write"
    let readOperationOnWrite: JSONObject = ["operation": .string("services.get")]
    assertGoogleServiceParity(name: writeName, config: readOperationOnWrite, expected: false)
    let invalidWait: JSONObject = [
      "operation": .string("services.enable"),
      "arguments": .object([
        "project": .string("sample"), "service": .string("calendar"), "wait": .string("invalid")
      ])
    ]
    assertGoogleServiceParity(name: writeName, config: invalidWait, expected: false)
  }

  func testGoogleServiceDeadlineKeepsPriorityOverInvalidWait() throws {
    let name = "riela/google-service-gateway-write"
    let request = try GoogleServiceGatewayAddonEngine.parse(
      operation: "services.enable",
      values: GatewayAddonValues(config: [
        "project": .string("sample"), "service": .string("calendar"), "wait": .string("invalid")
      ], variables: [:]),
      addonName: name
    )
    guard case let .enable(_, _, mutation) = request else { return XCTFail("expected enable request") }

    XCTAssertThrowsError(try GoogleServiceGatewayAddonEngine.mutationOptions(
      values: mutation, context: .init(deadline: Date(timeIntervalSinceNow: -1)), addonName: name
    )) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .timeout)
    }
    XCTAssertThrowsError(try GoogleServiceGatewayAddonEngine.mutationOptions(
      values: mutation, context: .init(), addonName: name
    )) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput)
      XCTAssertEqual((error as? AdapterExecutionError)?.message, "wait must be a boolean")
    }
  }

  func testGoogleServiceRuntimeChecksRenderedExactPlaceholderArgumentKeys() async throws {
    let name = "riela/google-service-gateway-write"
    let config: JSONObject = [
      "operation": .string("services.disable"),
      "arguments": .string("{{input.request}}")
    ]
    XCTAssertTrue(validationErrors(name, config: config).isEmpty, "exact placeholders defer argument validation")

    let client = RecordingGoogleServiceRuntimeCalls()
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ["RIELA_GOOGLE_TOKEN": "synthetic-token"],
      googleServiceGatewayClientFactory: { _ in client }
    )
    let input = WorkflowAddonExecutionInput(
      workflowId: "google-service-placeholder-test",
      stepId: "disable",
      nodeId: "disable-node",
      addon: WorkflowNodeAddonRef(
        name: name,
        version: "1",
        config: config,
        env: ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": .object([
          "fromEnv": .string("RIELA_GOOGLE_TOKEN"), "required": .bool(true)
        ])]
      ),
      resolvedInputPayload: ["request": .object([
        "project": .string("sample"), "service": .string("calendar"), "bogus": .bool(true)
      ])]
    )

    do {
      _ = try await resolver.execute(input, context: AdapterExecutionContext())
      XCTFail("rendered unknown argument must be rejected")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(error.message, "\(name) contains arguments outside its operation")
    }
    let callCount = await client.callCount()
    XCTAssertEqual(callCount, 0)
  }

  private func assertGoogleServiceParity(name: String, config: JSONObject, expected: Bool) {
    let validationAccepts = validationErrors(name, config: config).isEmpty
    let capability: BuiltinGoogleServiceGatewayAddon = name.hasSuffix("-read") ? .read : .write
    let runtimeAccepts = runtimeAcceptsGoogleService(config, capability: capability, addonName: name)
    XCTAssertEqual(validationAccepts, expected, "validation: \(name) \(config)")
    XCTAssertEqual(runtimeAccepts, expected, "runtime: \(name) \(config)")
  }

  private func runtimeAcceptsGoogleService(
    _ config: JSONObject,
    capability: BuiltinGoogleServiceGatewayAddon,
    addonName: String
  ) -> Bool {
    do {
      try GoogleServiceGatewayAddonEngine.requestShapeIssue(
        capability: capability, config: config, inputs: nil, addonName: addonName
      )
      guard let operation = config["operation"], case let .string(operationName) = operation else { return false }
      let arguments: JSONObject
      if config["arguments"] != nil {
        let variables: JSONObject = ["input": .object(["project": .string("resolved")])]
        arguments = try renderGatewayJSONArguments(config["arguments"], variables: variables, addonName: addonName)
      } else {
        return true
      }
      let request = try GoogleServiceGatewayAddonEngine.parse(
        operation: operationName,
        values: GatewayAddonValues(config: arguments, variables: [:]),
        addonName: addonName
      )
      return request.deferredValueError == nil
    } catch { return false }
  }

  private func runtimeAcceptsXEmbedded(_ config: JSONObject) -> Bool {
    do {
      guard let document = try xGatewayJSONDocument(config: config, variables: [:], addonName: "riela/x-gateway-reader") else {
        return false
      }
      try xGatewayRejectHostMediaArguments(document)
      return true
    } catch { return false }
  }

  private func validationErrors(
    _ name: String,
    config: JSONObject,
    inputs: JSONObject? = nil
  ) -> [WorkflowValidationDiagnostic] {
    let addon = WorkflowNodeAddonRef(name: name, config: config, inputs: inputs)
    let workflow = WorkflowDefinition(
      workflowId: "legacy-gateway-request-parity",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", addon: addon)],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "step", addon: addon)]
    )
    return DefaultWorkflowValidator(context: .production()).validate(workflow).filter { $0.severity == .error }
  }
}

private actor RecordingGoogleServiceRuntimeCalls: GoogleServiceGatewayAddonClient {
  private var count = 0

  func callCount() -> Int { count }

  func listServices(_: ListServicesRequest) async throws -> GoogleServiceGatewayCore.JSONValue {
    count += 1
    return .object([:])
  }

  func getService(project _: String, service _: String) async throws -> GoogleServiceGatewayCore.JSONValue {
    count += 1
    return .object([:])
  }

  func getOperation(_: String) async throws -> GoogleServiceGatewayCore.JSONValue {
    count += 1
    return .object([:])
  }

  func enable(project _: String, service _: String, options _: MutationOptions) async throws -> GoogleServiceGatewayCore.JSONValue {
    count += 1
    return .object([:])
  }

  func disable(
    project _: String,
    service _: String,
    disableDependents _: Bool,
    checkUsage _: Bool,
    options _: MutationOptions
  ) async throws -> GoogleServiceGatewayCore.JSONValue {
    count += 1
    return .object([:])
  }

  func batchEnable(project _: String, services _: [String], options _: MutationOptions) async throws -> GoogleServiceGatewayCore.JSONValue {
    count += 1
    return .object([:])
  }
}
