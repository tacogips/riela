import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

/// Opt-in OS-boundary gate. Uses synthetic source/auth and a fake vendor;
/// no account, inference, external network or publication is involved.
final class PrivateWorkflowLiveTests: XCTestCase {
  func testActualPrivateGraphKeepsSourceCredentialsAndInnerSessionsInGuest() async throws {
    let image = ProcessInfo.processInfo.environment["RIELA_PRIVATE_WORKFLOW_IMAGE"]
    try XCTSkipUnless(image != nil, "opt-in private workflow image required")
    let root = try makeRielaCLITestTemporaryDirectory("private-workflow-live")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle")
    let workflow = bundle.appendingPathComponent("verified")
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    let sentinel = root.appendingPathComponent("host-sentinel")
    try Data("host-only-canary".utf8).write(to: sentinel)
    let vendor = bundle.appendingPathComponent("codex-fixture")
    let source = bundle.appendingPathComponent("source-fixture")
    try """
    #!/bin/sh
    set -eu
    [ "$X_GW_TOKEN" = synthetic-source-auth ]
    [ "${UNRELATED_PRIVATE+x}" != x ]
    cat >/dev/null
    printf '%s\\n' '{"raw":"RAW_INTERMEDIATE_CANARY"}'
    """.write(to: source, atomically: true, encoding: .utf8)
    try """
    #!/bin/sh
    set -eu
    if [ "${1:-}" = --version ]; then echo codex-fixture; exit 0; fi
    case "$HOME" in /tmp/riela-private-*/home) ;; *) exit 20 ;; esac
    [ "$(cat "$HOME/.vendor/auth.json")" = synthetic-model-auth ]
    [ "${UNRELATED_PRIVATE+x}" != x ]
    [ ! -e '\(sentinel.path)' ]
    grep -q 'NoNewPrivs:[[:space:]]*1' /proc/self/status
    grep -q 'CapEff:[[:space:]]*0000000000000000' /proc/self/status
    grep -q ' /tmp tmpfs ' /proc/mounts
    prompt=$(cat)
    case "$prompt" in *RAW_INTERMEDIATE_CANARY*) ;; *) exit 21 ;; esac
    printf 'guest-only-refreshed-auth' > "$HOME/.vendor/auth.json"
    printf '%s\\n' '{"type":"thread.started","thread_id":"private-source-session"}' \\
      '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"status\\":\\"ok\\"}"}}' \\
      '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    """.write(to: vendor, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vendor.path)
    let schema: JSONObject = ["type": .string("object"), "required": .array([.string("status")]),
      "properties": .object(["status": .object(["const": .string("ok")])]), "additionalProperties": .bool(false)]
    let graph: JSONObject = ["workflowId": .string("verified"), "description": .string("Synthetic private source to agent"),
      "defaults": .object(["nodeTimeoutMs": .integer(30000), "maxLoopIterations": .integer(1)]),
      "entryStepId": .string("source"), "nodes": .array([
        .object(["id": .string("source"), "nodeFile": .string("source.json")]),
        .object(["id": .string("screen"), "nodeFile": .string("screen.json")])]), "steps": .array([
          .object(["id": .string("source"), "nodeId": .string("source"),
            "transitions": .array([.object(["toStepId": .string("screen")])])]),
          .object(["id": .string("screen"), "nodeId": .string("screen")])])]
    let agent: JSONObject = ["id": .string("screen"), "executionBackend": .string("codex-agent"),
      "model": .string("fixture"), "agentSandbox": .string("read-only"),
      "variables": .object(["codexExecutable": .string(vendor.path)]),
      "promptTemplate": .string("Inspect this synthetic source: {{raw}}"),
      "includeRuntimeVariablesInPrompt": .bool(false),
      "output": .object(["jsonSchema": .object(schema), "maxValidationAttempts": .integer(1)])]
    try JSONEncoder().encode(graph).write(to: workflow.appendingPathComponent("workflow.json"))
    try JSONEncoder().encode(agent).write(to: workflow.appendingPathComponent("screen.json"))
    let sourceNode: JSONObject = ["id": .string("source"), "nodeType": .string("command"), "variables": .object([:]),
      "requiredEnvironment": .array([.string("X_GW_TOKEN")]),
      "command": .object(["executable": .string("/bin/sh"), "arguments": .array([.string(source.path)])])]
    try JSONEncoder().encode(sourceNode).write(to: workflow.appendingPathComponent("source.json"))
    let worker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath().path
    let host = PrivateWorkflowHost(environment: [
      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "RIELA_SANDBOX_WORKER_EXECUTABLE": worker,
      "SOURCE_AUTH": "synthetic-source-auth", "MODEL_AUTH": "synthetic-model-auth", "UNRELATED_PRIVATE": "never-forward"
    ], workingDirectory: root, runner: FoundationLocalProcessRunner(), directoryParent: root)
    let baseline = bundle.appendingPathComponent("baseline")
    try FileManager.default.createDirectory(at: baseline, withIntermediateDirectories: false)
    let baselineGraph: JSONObject = ["workflowId": .string("baseline"), "description": .string("Private builtin boundary probe"),
      "defaults": .object(["nodeTimeoutMs": .integer(30000), "maxLoopIterations": .integer(1)]),
      "entryStepId": .string("checked"), "nodes": .array([.object(["id": .string("checked"),
        "addon": .object(["name": .string("riela/json-compose"), "version": .string("1"),
          "config": .object(["payload": .object(["status": .string("ok")])])])])]),
      "steps": .array([.object(["id": .string("checked"), "nodeId": .string("checked")])])]
    try JSONEncoder().encode(baselineGraph).write(to: baseline.appendingPathComponent("workflow.json"))
    let input = WorkflowAddonExecutionInput(workflowId: "outer", stepId: "private", nodeId: "private",
      addon: .init(name: "riela/private-workflow", version: "1",
        config: ["workflowId": .string("verified"), "definitionRoot": .string(bundle.path), "outputSchema": .object(schema)],
        env: ["X_GW_TOKEN": .object(["fromEnv": .string("SOURCE_AUTH")])],
        sandbox: .init(backend: .container, networkPolicy: .denied, readPaths: [bundle.path],
          container: .init(image: image!, runtime: .appleContainer), ephemeralHome: true,
          credentialEnvironment: ["MODEL_AUTH": ".vendor/auth.json"])))
    var baselineInput = input
    baselineInput.addon.config?["workflowId"] = .string("baseline")
    let baselineOutput = try await host.execute(baselineInput, context: .init(deadline: Date().addingTimeInterval(120)))
    XCTAssertEqual(baselineOutput.payload, ["status": .string("ok")])
    print("private builtin baseline passed")
    let output = try await host.execute(input, context: .init(deadline: Date().addingTimeInterval(120)))
    XCTAssertEqual(output.payload, ["status": .string("ok")])
    XCTAssertEqual(output.promptText, "")
    XCTAssertNil(output.usage)
    let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(output), encoding: .utf8))
    for canary in ["RAW_INTERMEDIATE_CANARY", "synthetic-model-auth", "synthetic-source-auth", "private-source-session"] {
      XCTAssertFalse(encoded.contains(canary))
    }
    XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "host-only-canary")
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["bundle", "host-sentinel"])
  }
}
