import Foundation
import GoogleServiceGatewayCore
import RielaCore
import XCTest
@testable import RielaCLI

final class GoogleServiceGatewayAddonTests: XCTestCase {
  func testReadAddonUsesExplicitTokenBindingAndResolvedInputs() async throws {
    let client = RecordingGoogleServiceGatewayClient()
    let tokens = LockedStrings()
    let output = try await runAddon(
      name: "riela/google-service-gateway-read",
      config: ["operation": .string("services.get")],
      inputs: [
        "project": .string("{{input.project}}"),
        "service": .string("calendar")
      ],
      resolvedInputPayload: ["project": .string("sample-project")],
      environment: ["RIELA_GOOGLE_TOKEN": "secret-token"],
      clientFactory: { token in
        tokens.append(token)
        return client
      }
    )

    XCTAssertEqual(tokens.values, ["secret-token"])
    let calls = await client.calls()
    XCTAssertEqual(calls, [.getService("sample-project", "calendar")])
    XCTAssertEqual(output.provider, "google-service-gateway")
    XCTAssertEqual(output.payload["operation"], .string("services.get"))
    guard case let .object(data)? = output.payload["data"] else {
      return XCTFail("expected gateway data object")
    }
    XCTAssertEqual(data["kind"], .string("get"))
  }

  func testReadAddonRejectsMutationBeforeCreatingClient() async throws {
    let tokens = LockedStrings()
    await assertFailure(
      name: "riela/google-service-gateway-read",
      config: ["operation": .string("services.enable")],
      code: .policyBlocked,
      messageContains: "does not allow operation",
      clientFactory: { token in
        tokens.append(token)
        return RecordingGoogleServiceGatewayClient()
      }
    )
    XCTAssertTrue(tokens.values.isEmpty)
  }

  func testWriteAddonRoutesBatchEnableAndBoundsTimeoutByDeadline() async throws {
    let client = RecordingGoogleServiceGatewayClient()
    _ = try await runAddon(
      name: "riela/google-service-gateway-write",
      config: [
        "operation": .string("services.batchEnable"),
        "timeoutSeconds": .integer(300),
        "pollIntervalSeconds": .number(0.25)
      ],
      variables: [
        "project": .string("sample-project"),
        "services": .array([.string("calendar"), .string("drive")])
      ],
      environment: ["RIELA_GOOGLE_TOKEN": "token"],
      context: AdapterExecutionContext(deadline: Date(timeIntervalSinceNow: 30)),
      clientFactory: { _ in client }
    )

    let calls = await client.calls()
    guard case let .batchEnable(project, services, wait, pollInterval, timeout)? = calls.first else {
      return XCTFail("expected batch enable call")
    }
    XCTAssertEqual(project, "sample-project")
    XCTAssertEqual(services, ["calendar", "drive"])
    XCTAssertTrue(wait)
    XCTAssertEqual(pollInterval, 0.25)
    XCTAssertGreaterThan(timeout, 0)
    XCTAssertLessThanOrEqual(timeout, 30)
  }

  func testAddonRequiresExplicitCredentialBindingAndRejectsExtraTargets() async throws {
    await assertFailure(
      name: "riela/google-service-gateway-read",
      config: ["operation": .string("services.list")],
      env: nil,
      omitEnvironmentBinding: true,
      code: .policyBlocked,
      messageContains: "requires addon.env.GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"
    )
    await assertFailure(
      name: "riela/google-service-gateway-read",
      config: ["operation": .string("services.list")],
      env: [
        "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": tokenBinding,
        "LD_PRELOAD": .object(["fromEnv": .string("RIELA_GOOGLE_TOKEN")])
      ],
      environment: ["RIELA_GOOGLE_TOKEN": "token"],
      code: .policyBlocked,
      messageContains: "addon.env target 'LD_PRELOAD'"
    )
  }

  private var tokenBinding: RielaCore.JSONValue {
    .object(["fromEnv": .string("RIELA_GOOGLE_TOKEN"), "required": .bool(true)])
  }

  private func runAddon(
    name: String,
    config: JSONObject,
    inputs: JSONObject = [:],
    env: JSONObject? = nil,
    variables: JSONObject = [:],
    resolvedInputPayload: JSONObject = [:],
    environment: [String: String] = [:],
    context: AdapterExecutionContext = AdapterExecutionContext(),
    omitEnvironmentBinding: Bool = false,
    clientFactory: @escaping GoogleServiceGatewayAddonClientFactory = { _ in
      RecordingGoogleServiceGatewayClient()
    }
  ) async throws -> AdapterExecutionOutput {
    let bindings = omitEnvironmentBinding
      ? nil
      : env ?? ["GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN": tokenBinding]
    return try await BuiltinWorkflowAddonResolver(
      environment: environment,
      googleServiceGatewayClientFactory: clientFactory
    ).execute(
      WorkflowAddonExecutionInput(
        workflowId: "google-service-gateway-test",
        stepId: "gateway-step",
        nodeId: "gateway-node",
        addon: WorkflowNodeAddonRef(
          name: name,
          version: "1",
          config: config,
          env: bindings,
          inputs: inputs
        ),
        variables: variables,
        resolvedInputPayload: resolvedInputPayload
      ),
      context: context
    )
  }

  private func assertFailure(
    name: String,
    config: JSONObject,
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    omitEnvironmentBinding: Bool = false,
    code: AdapterExecutionErrorCode,
    messageContains: String,
    clientFactory: @escaping GoogleServiceGatewayAddonClientFactory = { _ in
      RecordingGoogleServiceGatewayClient()
    }
  ) async {
    do {
      _ = try await runAddon(
        name: name,
        config: config,
        env: env,
        environment: environment,
        omitEnvironmentBinding: omitEnvironmentBinding,
        clientFactory: clientFactory
      )
      XCTFail("expected google-service-gateway add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }
}

private enum RecordedGoogleServiceGatewayCall: Equatable, Sendable {
  case list(String)
  case getService(String, String)
  case getOperation(String)
  case enable(String, String)
  case disable(String, String, Bool, Bool)
  case batchEnable(String, [String], Bool, Double, Double)
}

private actor RecordingGoogleServiceGatewayClient: GoogleServiceGatewayAddonClient {
  private var recorded: [RecordedGoogleServiceGatewayCall] = []

  func calls() -> [RecordedGoogleServiceGatewayCall] { recorded }

  func listServices(_ request: ListServicesRequest) async throws -> GoogleServiceGatewayCore.JSONValue {
    recorded.append(.list(request.project))
    return .object(["kind": .string("list")])
  }

  func getService(project: String, service: String) async throws -> GoogleServiceGatewayCore.JSONValue {
    recorded.append(.getService(project, service))
    return .object(["kind": .string("get")])
  }

  func getOperation(_ operation: String) async throws -> GoogleServiceGatewayCore.JSONValue {
    recorded.append(.getOperation(operation))
    return .object(["kind": .string("operation")])
  }

  func enable(
    project: String,
    service: String,
    options _: MutationOptions
  ) async throws -> GoogleServiceGatewayCore.JSONValue {
    recorded.append(.enable(project, service))
    return .object(["kind": .string("enable")])
  }

  func disable(
    project: String,
    service: String,
    disableDependents: Bool,
    checkUsage: Bool,
    options _: MutationOptions
  ) async throws -> GoogleServiceGatewayCore.JSONValue {
    recorded.append(.disable(project, service, disableDependents, checkUsage))
    return .object(["kind": .string("disable")])
  }

  func batchEnable(
    project: String,
    services: [String],
    options: MutationOptions
  ) async throws -> GoogleServiceGatewayCore.JSONValue {
    recorded.append(.batchEnable(project, services, options.wait, options.pollInterval, options.timeout))
    return .object(["kind": .string("batchEnable")])
  }
}

private final class LockedStrings: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var values: [String] { lock.withLock { storage } }

  func append(_ value: String) {
    lock.withLock { storage.append(value) }
  }
}
