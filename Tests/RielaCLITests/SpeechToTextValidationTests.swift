import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class SpeechToTextValidationTests: XCTestCase {
  private func addon(_ options: JSONObject, env: JSONObject? = nil, container: Bool = false,
                     sandbox: Bool = false) -> WorkflowNodeAddonRef {
    .init(name: "riela/speech-to-text", config: ["options": .object(options)], env: env,
          container: container ? .init() : nil, sandbox: sandbox ? .init(backend: .container) : nil)
  }

  func testLiteralErrorsAndTemplates() {
    let fallback: JSONValue = .array([.object(["provider": .string("deepgram")])])
    let invalid: [(JSONObject, String)] = [
      (["provider": .string("nope")], "provider"),
      (["provider": .string("gemini")], "model"),
      (["provider": .string("whisper-cpp")], "whisperCpp"),
      (["maxAttempts": .string("{{n}}"), "fallback": .array([.object(["provider": .string("nope")])])], "fallback[0].provider"),
      (["fallback": .array([.object(["provider": .string("whisper-cpp")])])], "fallback[0].whisperCpp"),
      (["fallback": fallback, "fallbackOn": .array([.string("rejected")]), "maxAttempts": .string("{{n}}")], "fallbackOn"),
      (["fallbackOn": .array([.string("unavailable")])], "fallbackOn"),
      (["provider": .string("command"), "command": .string("{{cmd}}")], "command")
    ]
    for (options, name) in invalid {
      let issues = BuiltinGatewayRequestChecks.issues(addon(options))
      XCTAssertEqual(issues.map(\.relativePath), ["options.\(name)"])
      XCTAssertEqual(issues.first?.message, "invalid speech-to-text option '\(name)'")
    }
    let valid: [JSONObject] = [
      [:], ["provider": .string("{{p}}")], ["path": .string("{{audio}}"), "maxAttempts": .string("{{n}}")],
      ["timeoutSeconds": .string("{{t}}"), "onDevice": .string("{{b}}"), "cacheAcceptsFallback": .string("{{b}}")],
      ["provider": .string("gemini"), "model": .string("{{m}}")],
      ["provider": .string("whisper-cpp"), "whisperCpp": .object(["model": .string("{{m}}"),
        "binary": .string("{{b}}"), "threads": .string("{{t}}"), "extraArgs": .array([.string("{{a}}")])])],
      ["provider": .string("whisper-cpp"), "whisperCpp": .string("{{w}}")],
      ["fallback": fallback, "fallbackOn": .string("{{classes}}")],
      ["provider": .string("apple")], ["provider": .string("command"), "command": .array([.string("tool"), .string("{{path}}")])]
    ]
    for options in valid { XCTAssertTrue(BuiltinGatewayRequestChecks.issues(addon(options)).isEmpty, "\(options)") }
  }

  func testProductionValidationContextUsesSpeechChecks() throws {
    let checker = try XCTUnwrap(WorkflowValidationContext.production().addonRequestChecker)
    XCTAssertEqual(checker(addon(["provider": .string("nope")])).map(\.relativePath), ["options.provider"])
  }

  func testEnvironmentAndHostPolicy() {
    let env: JSONObject = ["DEEPGRAM_API_KEY": .string("secret")]
    let issue = BuiltinGatewayRequestChecks.issues(addon([:], env: env))
    XCTAssertEqual(issue.map(\.relativePath), ["env"])
    XCTAssertTrue(issue[0].message.contains("DEEPGRAM_API_KEY"))
    XCTAssertFalse(issue[0].message.contains("secret"))
    XCTAssertTrue(BuiltinGatewayRequestChecks.issues(addon(["fallback": .array([.object(["provider": .string("deepgram")])])], env: env)).isEmpty)
    let whisper: JSONObject = ["provider": .string("whisper-cpp"), "whisperCpp": .object(["model": .string("model")])]
    let chained: JSONObject = ["fallback": .array([.object(whisper)])]
    for options in [whisper, chained] {
      XCTAssertTrue(BuiltinGatewayRequestChecks.issues(addon(options)).isEmpty)
      XCTAssertEqual(BuiltinGatewayRequestChecks.issues(addon(options, container: true)).map(\.relativePath), ["options.provider"])
      XCTAssertEqual(BuiltinGatewayRequestChecks.issues(addon(options, sandbox: true)).map(\.relativePath), ["options.provider"])
    }
  }

  func testHostPolicyBeforeDispatchAndRawFallback() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("stt-validation")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = SpeechValidationRunner()
    let primary = SpeechValidationNative()
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
      primary: primary, environment: ["RIELA_CONTAINER_RUNTIME": "docker"], workingDirectory: root, runner: runner)
    let whisper: JSONObject = ["provider": .string("whisper-cpp"), "whisperCpp": .object(["model": .string("m.bin")])]
    let templated: JSONObject = ["provider": .string("{{input.p}}"), "whisperCpp": .object(["model": .string("m.bin")])]
    let numeric: JSONObject = ["provider": .string("whisper-cpp"), "maxAttempts": .string("{{input.n}}"),
      "whisperCpp": .object(["model": .string("m.bin"), "threads": .string("{{input.t}}")])]
    let chained: JSONObject = ["provider": .string("openai"), "fallback": .array([.object(whisper)])]
    XCTAssertTrue(BuiltinGatewayRequestChecks.issues(addon(templated)).isEmpty)
    for options in [whisper, templated, numeric, chained] {
      for sandbox in [false, true] {
        let input = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n",
          addon: addon(options, container: !sandbox, sandbox: sandbox),
          resolvedInputPayload: ["p": .string("whisper-cpp"), "n": .number(2), "t": .number(2)])
        do {
          _ = try await resolver.execute(input, context: .init())
          XCTFail("expected host policy")
        } catch let error as AdapterExecutionError {
          XCTAssertEqual(error.code, .policyBlocked)
          XCTAssertEqual(error.message, "speech-to-text provider 'whisper-cpp' runs on the host; remove addon.container/addon.sandbox")
        }
      }
    }
    let before = await runner.configurations
    let primaryCalls = await primary.calls
    XCTAssertTrue(before.isEmpty)
    XCTAssertEqual(primaryCalls, 0)
    let fallback: JSONValue = .array([.object(["provider": .string("command"),
      "command": .array([.string("x"), .string("{{path}}")])])])
    let input = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n",
      addon: addon(["provider": .string("openai"), "fallback": fallback], container: true))
    _ = try await resolver.execute(input, context: .init())
    let after = await runner.configurations
    XCTAssertTrue(try XCTUnwrap(after.first).arguments.contains("riela-video-addons:local"))
    let requests = await runner.requests
    XCTAssertEqual(requests.first?.input?.addon.config?["options"], .object(["provider": .string("openai"), "fallback": fallback]))
    do {
      _ = try await resolver.execute(.init(workflowId: "w", stepId: "s", nodeId: "n",
        addon: addon(["provider": .string("openai")], sandbox: true)), context: .init())
    } catch let error as AdapterExecutionError {
      XCTAssertNotEqual(error.message, "speech-to-text provider 'whisper-cpp' runs on the host; remove addon.container/addon.sandbox")
    }
  }

}

private actor SpeechValidationNative: WorkflowAddonResolving {
  var calls = 0
  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    calls += 1
    return .init(provider: "test", model: "test", promptText: "", completionPassed: true, payload: [:])
  }
}

private actor SpeechValidationRunner: LocalProcessRunning {
  var configurations: [LocalProcessConfiguration] = []
  var requests: [BuiltinAddonContainerRequest] = []
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    configurations.append(configuration)
    requests.append(try JSONDecoder().decode(BuiltinAddonContainerRequest.self, from: Data(stdin.utf8)))
    let output = AdapterExecutionOutput(provider: "test", model: "test", promptText: "", completionPassed: true, payload: [:])
    let data = try JSONEncoder().encode(BuiltinAddonContainerReply(output: output))
    return .init(stdout: try XCTUnwrap(String(data: data, encoding: .utf8)) + "\n", stderr: "", terminationStatus: 0)
  }
}
