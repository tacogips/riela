import Foundation
import CryptoKit
import XCTest
@testable import CodexAgent
@testable import RielaCore

final class CodexAgentCompatibilityCLITests: XCTestCase {
  func testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps() throws {
    let lines = [
      CodexRolloutLine(timestamp: "2025-05-07T17:24:24.000Z", type: "event_msg", payload: .object(["type": .string("TurnStarted")])),
      CodexRolloutLine(timestamp: "2025-05-07T17:24:25.000Z", type: "event_msg", payload: .object(["type": .string("ExecApprovalRequest")]))
    ]
    let activity = CodexSessionIndex.deriveActivityEntry(sessionId: "session-1", lines: lines)
    XCTAssertEqual(activity.status, .waitingApproval)

    let runningSession = MockCodexRunningSession(sessionId: "session-1", messages: lines)
    let runner = createMockCodexSessionRunner(startSessions: [runningSession])
    let started = try runner.startSession(config: CodexSessionConfig(prompt: "hello"))
    XCTAssertEqual(started.sessionId, "session-1")
    XCTAssertEqual(runner.startSessionCalls.map(\.config.prompt), ["hello"])
    XCTAssertEqual(started.messages().count, 2)
    XCTAssertEqual(started.waitForCompletion().exitCode, 0)

    let emitter = BasicCodexSDKEventEmitter()
    var seenPayload: JSONObject?
    let id = emitter.on(.sessionStarted) { payload in
      seenPayload = payload
    }
    emitter.emit(.sessionStarted, payload: ["sessionId": .string("session-1")])
    XCTAssertEqual(seenPayload?["sessionId"], .string("session-1"))
    emitter.off(.sessionStarted, id: id)

    var registry = CodexToolRegistry()
    registry.register(name: "read_file", definition: ["description": .string("Read a file")])
    XCTAssertEqual(registry.listNames(), ["read_file"])

    let temp = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: temp)
    }
    let paths = try CodexAgentAttachments.imagePathArguments(
      from: [.path("/tmp/source.png"), .base64(data: Data("png".utf8).base64EncodedString(), mediaType: "image/png", filename: "../unsafe name.png")],
      tempDirectory: temp
    )
    XCTAssertEqual(paths.first, "/tmp/source.png")
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths[1]))
    CodexAgentAttachments.cleanup(paths: [paths[1]])
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths[1]))

    XCTAssertEqual(CodexCLICompatibility.parseProcessOptions(["--model", "gpt-5.5", "--sandbox", "read-only", "--full-auto"]).model, "gpt-5.5")
    XCTAssertEqual(try CodexCLICompatibility.parseCommand(["queue", "move", "queue-1", "prompt-1", "0"]).family, .queue)
    XCTAssertThrowsError(try CodexCLICompatibility.parseCommand(["queue", "unknown"]))
    XCTAssertTrue(CodexCLICompatibility.usage().contains("graphql"))
    XCTAssertTrue(CodexGraphQLCommandExecutor.normalizeDocument("session.list").contains(#"command(name: "session.list""#))
    XCTAssertTrue(CodexGraphQLCommandExecutor.normalizeDocument("group.create").hasPrefix("mutation"))
    XCTAssertTrue(CodexGraphQLCommandExecutor.normalizeDocument("session.watch").hasPrefix("subscription"))
    XCTAssertEqual(try CodexGraphQLCommandExecutor.parseParams(["limit=5", "tag=ship"])["limit"], .number(5))
    let graphQLParamResult = CodexCLICommandExecutor.execute(arguments: ["graphql", "session.list", "--param", #"{"limit":1}"#], context: CodexAgentCompatibilityContext(codexHome: temp.path, configDir: temp.path))
    XCTAssertEqual(graphQLParamResult.errors, [])
    let variablesPath = temp.appendingPathComponent("graphql-vars.json")
    try #"{"param":{"limit":1}}"#.write(to: variablesPath, atomically: true, encoding: .utf8)
    let graphQLVariablesResult = CodexCLICommandExecutor.execute(
      arguments: ["graphql", "session.list", "--variables", variablesPath.path],
      context: CodexAgentCompatibilityContext(codexHome: temp.path, configDir: temp.path)
    )
    XCTAssertEqual(graphQLVariablesResult.errors, [])
    XCTAssertEqual(jsonObject(CodexGraphQLCommandExecutor.execute(command: "query { ping }").data)?["ping"], .bool(true))
    let variableNameCommand = CodexGraphQLCommandExecutor.execute(
      command: #"query ($name: String!, $param: JSON) { command(name: $name, params: $param) }"#,
      variables: ["name": .string("session.list"), "param": .object(["limit": .number(1)])],
      context: CodexAgentCompatibilityContext(codexHome: temp.path, configDir: temp.path)
    )
    XCTAssertEqual(variableNameCommand.errors, [])
    let inlineParams = CodexGraphQLCommandExecutor.execute(
      command: #"mutation { command(name: "group.create", params: {name: "inline", description: "from inline"}) }"#,
      context: CodexAgentCompatibilityContext(codexHome: temp.path, configDir: temp.path)
    )
    XCTAssertEqual(inlineParams.errors, [])
    XCTAssertEqual(try CodexGroupPersistence.findGroup("inline", configDir: temp.path)?.description, "from inline")
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "unknown.command").errors, ["Unknown command: unknown.command"])
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "subscription { queue.run }").errors, ["Unsupported subscription command: queue.run"])
    let fakeCodex = try createExecutable(
      directory: temp,
      name: "fake-codex-session-run.sh",
      body: """
      printf '{"type":"turn_complete","session_id":"session-test"}\\n'
      printf 'CODEX_HOME=%s\\n' "${CODEX_HOME:-}" >&2
      """
    )
    let versionDefault = CodexGraphQLCommandExecutor.execute(command: "version.get", variables: ["executableName": .string(fakeCodex.path)])
    XCTAssertEqual(versionDefault.errors, [])
    XCTAssertNotEqual(jsonObject(versionDefault.data)?["git"], .null)
    let versionWithoutGit = CodexGraphQLCommandExecutor.execute(command: "version.get", variables: ["executableName": .string(fakeCodex.path), "includeGit": .bool(false)])
    XCTAssertEqual(jsonObject(versionWithoutGit.data)?["git"], .null)
    let runResult = CodexGraphQLCommandExecutor.execute(
      command: "session.run",
      variables: ["prompt": .string("hello with spaces"), "model": .string("gpt-5.5"), "fullAuto": .bool(true), "streamGranularity": .string("event"), "executableName": .string(fakeCodex.path)],
      context: CodexAgentCompatibilityContext(codexHome: temp.path, configDir: temp.path)
    )
    if case let .object(data) = runResult.data, case let .array(arguments) = data["arguments"] {
      XCTAssertTrue(arguments.contains(.string("--model")))
      XCTAssertTrue(arguments.contains(.string("gpt-5.5")))
      XCTAssertTrue(arguments.contains(.string("--dangerously-bypass-approvals-and-sandbox")))
      XCTAssertTrue(arguments.contains(.string("--stream-granularity")))
      XCTAssertTrue(arguments.contains(.string("event")))
      XCTAssertEqual(Array(arguments.suffix(2)), [.string("--"), .string("-")])
      XCTAssertFalse(arguments.contains(.string("hello with spaces")))
      XCTAssertEqual(jsonNumber(data["exitCode"]), 0)
      XCTAssertEqual(jsonString(data["stderr"]), "CODEX_HOME=\(temp.path)\n")
    } else {
      XCTFail("expected session.run arguments")
    }
    XCTAssertTrue(CodexGraphQLCommandExecutor.supportedCommandNames.isSuperset(of: ["queue.move", "bookmark.search", "token.rotate", "files.rebuild", "session.watch"]))
    XCTAssertEqual(CodexMarkdown.parseTasks("# Work\n- [ ] one\n- [x] two").map(\.checked), [false, true])
    XCTAssertEqual(CodexMarkdown.parseSections("# Work\nBody\n## Next\nMore").map(\.heading), ["Work", "Next"])
    let patch = "*** Add File: Sources/New.swift\n"
    let changes = CodexFileChanges.extract(from: CodexRolloutLine(timestamp: "now", type: "event_msg", payload: .object(["patch": .string(patch)])))
    XCTAssertEqual(changes, [CodexFileChange(path: "Sources/New.swift", operation: .created, source: .applyPatch, patch: patch)])
  }

  func testLegacyTokenHashConfigQueueGroupRunAndGraphQLAliases() throws {
    let configDir = try makeTemporaryDirectory()
    let codexHome = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: configDir)
      try? FileManager.default.removeItem(at: codexHome)
    }
    let context = CodexAgentCompatibilityContext(codexHome: codexHome.path, configDir: configDir.path)

    let legacyTokenHash = SHA256.hash(data: Data("legacy-secret".utf8)).map { String(format: "%02x", $0) }.joined()
    try """
    {
      "tokens": [
        {
          "id": "legacy-token",
          "name": "legacy",
          "permissions": ["session:read"],
          "createdAt": "2026-02-20T10:00:00.000Z",
          "tokenHash": "\(legacyTokenHash)"
        }
      ]
    }
    """.write(to: configDir.appendingPathComponent("tokens.json"), atomically: true, encoding: .utf8)
    XCTAssertEqual(try CodexTokenPersistence.verify(rawToken: "legacy-token.legacy-secret", permission: "session:read", configDir: configDir.path)?.name, "legacy")
    XCTAssertFalse(String(describing: CodexGraphQLCommandExecutor.execute(command: "token.list", context: context).data).contains("legacy-secret"))

    let marker = configDir.appendingPathComponent("codex-run-marker.txt")
    let fakeCodex = try createExecutable(
      directory: configDir,
      name: "fake-codex-runner.sh",
      body: """
      printf 'ARGS %s\\n' "$*" >> "\(marker.path)"
      stdin="$(cat)"
      if [ -n "$stdin" ]; then
        printf 'STDIN %s\\n' "$stdin" >> "\(marker.path)"
      fi
      printf '{"type":"turn_complete","session_id":"fake"}\\n'
      exit "${FAKE_CODEX_EXIT_CODE:-0}"
      """
    )

    let cliRun = CodexCLICommandExecutor.execute(
      arguments: ["session", "run", "--prompt", "cli prompt", "--model", "gpt-5.5", "--sandbox", "read-only", "--full-auto", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliRun.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(cliRun.data)?["exitCode"]), 0)
    let cliEqualsPromptRun = CodexCLICommandExecutor.execute(
      arguments: ["session", "run", "foo=bar", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliEqualsPromptRun.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(cliEqualsPromptRun.data)?["exitCode"]), 0)
    let cliModelCheck = CodexCLICommandExecutor.execute(
      arguments: ["model", "check", "--model", "gpt-5.5", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliModelCheck.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(cliModelCheck.data)?["exitCode"]), 0)
    XCTAssertEqual(jsonObject(cliModelCheck.data)?["ok"], .bool(true))
    let appVersion = CodexAgentCLIApplication.run(arguments: ["version", "includeGit=false"], context: context)
    XCTAssertEqual(appVersion.exitCode, 0)
    XCTAssertEqual(appVersion.stderr, "")
    XCTAssertTrue(appVersion.stdout.contains(#""version""#))

    let cliQueueCreate = CodexCLICommandExecutor.execute(
      arguments: ["queue", "create", "cli-release", "--project", configDir.path],
      context: context
    )
    XCTAssertEqual(cliQueueCreate.errors, [])
    let cliQueueAdd = CodexCLICommandExecutor.execute(
      arguments: ["queue", "add", "cli-release", "--prompt", "queued via cli", "--image", "/tmp/cli-a.png", "--image", "/tmp/cli-b.png"],
      context: context
    )
    XCTAssertEqual(cliQueueAdd.errors, [])
    let cliQueuePromptId = try XCTUnwrap(jsonString(jsonObject(cliQueueAdd.data)?["id"]))
    XCTAssertEqual(try CodexQueuePersistence.findQueue("cli-release", configDir: configDir.path)?.projectPath, configDir.path)
    XCTAssertEqual(try CodexQueuePersistence.findQueue("cli-release", configDir: configDir.path)?.prompts.first?.imagePaths, ["/tmp/cli-a.png", "/tmp/cli-b.png"])
    XCTAssertEqual(CodexCLICommandExecutor.execute(arguments: ["queue", "mode", "cli-release", cliQueuePromptId, "--mode", "manual"], context: context).errors, [])
    XCTAssertEqual(CodexCLICommandExecutor.execute(arguments: ["queue", "move", "cli-release", "--from", "0", "--to", "0"], context: context).errors, [])

    let cliGroupCreate = CodexCLICommandExecutor.execute(arguments: ["group", "create", "cli-batch"], context: context)
    XCTAssertEqual(cliGroupCreate.errors, [])
    XCTAssertEqual(CodexCLICommandExecutor.execute(arguments: ["group", "add", "cli-batch", "session-cli"], context: context).errors, [])
    let cliGroupRun = CodexCLICommandExecutor.execute(
      arguments: ["group", "run", "cli-batch", "--prompt", "group via cli", "--max-concurrent", "1", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliGroupRun.errors, [])
    let cliResumeWithFlagPrompt = CodexCLICommandExecutor.execute(
      arguments: ["session", "resume", "session-1", "--prompt", "resume via cli flag", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliResumeWithFlagPrompt.errors, [])
    let cliResumeWithPositionalPrompt = CodexCLICommandExecutor.execute(
      arguments: ["session", "resume", "session-1", "resume", "via", "cli", "positionals", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliResumeWithPositionalPrompt.errors, [])
    let cliForkWithNthMessage = CodexCLICommandExecutor.execute(
      arguments: ["session", "fork", "session-1", "--nth-message", "2", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliForkWithNthMessage.errors, [])

    let queueCreate = CodexGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("release"), "projectPath": .string(configDir.path)], context: context)
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("invalid")], context: context).errors, ["missingVariable(\"projectPath\")"])
    let queueId = try XCTUnwrap(jsonString(jsonObject(queueCreate.data)?["id"]))
    let first = CodexGraphQLCommandExecutor.execute(command: "queue.add", variables: ["id": .string(queueId), "prompt": .string("first"), "images": .array([.string("/tmp/a.png")])], context: context)
    let firstId = try XCTUnwrap(jsonString(jsonObject(first.data)?["id"]))
    let second = CodexGraphQLCommandExecutor.execute(command: "queue.add", variables: ["id": .string(queueId), "prompt": .string("second")], context: context)
    let secondId = try XCTUnwrap(jsonString(jsonObject(second.data)?["id"]))
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "queue.move", variables: ["id": .string(queueId), "from": .number(1), "to": .number(0)], context: context).errors, [])
    XCTAssertEqual(try CodexQueuePersistence.findQueue(queueId, configDir: configDir.path)?.prompts.map(\.id), [secondId, firstId])
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "queue.move", variables: ["id": .string(queueId), "from": .number(0), "to": .number(2)], context: context).errors, ["Queue command not found"])
    XCTAssertEqual(try CodexQueuePersistence.findQueue(queueId, configDir: configDir.path)?.prompts.map(\.id), [secondId, firstId])
    XCTAssertEqual(
      CodexGraphQLCommandExecutor.execute(
        command: "queue.update",
        variables: [
          "id": .string(queueId),
          "commandId": .string(firstId),
          "prompt": .string("updated"),
          "status": .string("pending")
        ],
        context: context
      ).errors,
      []
    )
    let invalidStatus = CodexGraphQLCommandExecutor.execute(command: "queue.update", variables: ["id": .string(queueId), "commandId": .string(firstId), "status": .string("archived")], context: context)
    XCTAssertEqual(invalidStatus.errors, ["status must be one of: pending, running, completed, failed"])
    XCTAssertEqual(try CodexQueuePersistence.findQueue(queueId, configDir: configDir.path)?.prompts.first(where: { $0.id == firstId })?.status, .pending)
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "queue.mode", variables: ["id": .string(queueId), "commandId": .string(firstId), "mode": .string("manual")], context: context).errors, [])
    let queueRun = CodexGraphQLCommandExecutor.execute(command: "queue.run", variables: ["id": .string(queueId), "executableName": .string(fakeCodex.path)], context: context)
    XCTAssertEqual(queueRun.errors, [])
    XCTAssertTrue(String(describing: queueRun.data).contains("queue_completed"))

    let groupCreate = CodexGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("batch")], context: context)
    let groupId = try XCTUnwrap(jsonString(jsonObject(groupCreate.data)?["id"]))
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "group.add", variables: ["id": .string(groupId), "sessionId": .string("session-1")], context: context).errors, [])
    let groupRun = CodexGraphQLCommandExecutor.execute(command: "group.run", variables: ["id": .string(groupId), "prompt": .string("ship"), "executableName": .string(fakeCodex.path)], context: context)
    XCTAssertEqual(groupRun.errors, [])
    XCTAssertTrue(String(describing: groupRun.data).contains("session_completed"))
    var markerText = ""
    for _ in 0..<20 {
      markerText = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
      if markerText.contains("resume via cli flag"),
         markerText.contains("resume via cli positionals"),
         markerText.contains("--nth-message 2") {
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    XCTAssertTrue(markerText.contains("updated"), markerText)
    XCTAssertTrue(markerText.contains("second"), markerText)
    XCTAssertTrue(markerText.contains("ship"), markerText)
    XCTAssertTrue(markerText.contains("resume"), markerText)
    XCTAssertTrue(markerText.contains("session-1"), markerText)
    XCTAssertTrue(markerText.contains("foo=bar"), markerText)
    XCTAssertTrue(markerText.contains("resume via cli flag"), markerText)
    XCTAssertTrue(markerText.contains("resume via cli positionals"), markerText)
    XCTAssertTrue(markerText.contains("--nth-message 2"), markerText)
    let aliasRun = CodexGraphQLCommandExecutor.execute(
      command: "session.run",
      variables: [
        "prompt": .string("alias"),
        "codexBinary": .string(fakeCodex.path),
        "environmentVariables": .object(["FAKE_CODEX_EXIT_CODE": .string("0")])
      ],
      context: context
    )
    XCTAssertEqual(aliasRun.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(aliasRun.data)?["exitCode"]), 0)
  }

  func testSessionRunValidationAndAsyncHandles() throws {
    let configDir = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: configDir)
    }
    let context = CodexAgentCompatibilityContext(codexHome: configDir.path, configDir: configDir.path)
    let fakeCodex = try createExecutable(
      directory: configDir,
      name: "fake-codex-validation.sh",
      body: """
      printf '{"type":"turn_complete","session_id":"fake"}\n'
      """
    )

    let invalidEnvironment = CodexGraphQLCommandExecutor.execute(
      command: "session.run",
      variables: ["prompt": .string("bad"), "environmentVariables": .object(["FAKE_CODEX_EXIT_CODE": .number(0)])],
      context: context
    )
    XCTAssertFalse(invalidEnvironment.errors.isEmpty)
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["executableName": .string(fakeCodex.path)], context: context).errors, ["missingVariable(\"prompt\")"])
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("   "), "executableName": .string(fakeCodex.path)], context: context).errors, ["missingVariable(\"prompt\")"])
    XCTAssertEqual(CodexCLICommandExecutor.execute(arguments: ["session", "run", "--codex-binary", fakeCodex.path], context: context).errors, ["missingVariable(\"prompt\")"])
    let appMissingPrompt = CodexAgentCLIApplication.run(arguments: ["session", "run", "--codex-binary", fakeCodex.path], context: context)
    XCTAssertEqual(appMissingPrompt.exitCode, 1)
    XCTAssertTrue(appMissingPrompt.stderr.contains("prompt"))
    XCTAssertFalse(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("bad"), "images": .array([.number(1)])], context: context).errors.isEmpty)
    XCTAssertFalse(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("bad"), "sandbox": .string("bad")], context: context).errors.isEmpty)
    XCTAssertFalse(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("bad"), "approvalMode": .string("bad")], context: context).errors.isEmpty)
    let approvalRun = CodexGraphQLCommandExecutor.execute(
      command: "session.run",
      variables: [
        "prompt": .string("approval"),
        "approvalMode": .string("always"),
        "executableName": .string(fakeCodex.path)
      ],
      context: context
    )
    XCTAssertEqual(approvalRun.errors, [])
    XCTAssertFalse(String(describing: approvalRun.data).contains("--approval-mode"))
    XCTAssertFalse(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("bad"), "streamGranularity": .string("word")], context: context).errors.isEmpty)
    let slowCodex = try createExecutable(
      directory: configDir,
      name: "fake-codex-slow.sh",
      body: """
      sleep 1
      printf '{"type":"turn_complete","session_id":"fake"}\\n'
      """
    )
    let resumeHandle = CodexGraphQLCommandExecutor.execute(command: "session.resume", variables: ["id": .string("session-1"), "prompt": .string("resume"), "executableName": .string(slowCodex.path)], context: context)
    XCTAssertEqual(resumeHandle.errors, [])
    XCTAssertEqual(jsonString(jsonObject(resumeHandle.data)?["status"]), "running")
    let forkHandle = CodexGraphQLCommandExecutor.execute(command: "session.fork", variables: ["id": .string("session-1"), "nthMessage": .number(1), "executableName": .string(slowCodex.path)], context: context)
    XCTAssertEqual(forkHandle.errors, [])
    XCTAssertEqual(jsonString(jsonObject(forkHandle.data)?["status"]), "running")
    let defaultToken = CodexGraphQLCommandExecutor.execute(command: "token.create", variables: ["name": .string("default")], context: context)
    let defaultRawToken = try XCTUnwrap(jsonString(defaultToken.data))
    XCTAssertNotNil(try CodexTokenPersistence.verify(rawToken: defaultRawToken, permission: "session:read", configDir: configDir.path))
    XCTAssertNil(try CodexTokenPersistence.verify(rawToken: defaultRawToken, permission: "session:cancel", configDir: configDir.path))
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "token.create", variables: ["permissions": .array([.string("session:read")])], context: context).errors, ["missingVariable(\"name\")"])
    XCTAssertEqual(
      CodexGraphQLCommandExecutor.execute(
        command: "token.create",
        variables: ["name": .string("bad"), "permissions": .array([.string("session:*")])],
        context: context
      ).errors,
      ["No valid permissions provided"]
    )
    let cliToken = CodexCLICommandExecutor.execute(arguments: ["token", "create", "--name", "cli-token", "--permissions", "session:cancel,session:*", "--expires-at", "2099-01-01T00:00:00Z"], context: context)
    XCTAssertEqual(cliToken.errors, [])
    let cliRawToken = try XCTUnwrap(jsonString(cliToken.data))
    let cliTokenMetadata = try XCTUnwrap(try CodexTokenPersistence.verify(rawToken: cliRawToken, permission: "session:cancel", configDir: configDir.path))
    XCTAssertEqual(cliTokenMetadata.name, "cli-token")
    XCTAssertEqual(cliTokenMetadata.permissions, ["session:cancel"])
  }

  func testSessionSearchWatchFilesAndTranscriptAliases() throws {
    let configDir = try makeTemporaryDirectory()
    let codexHome = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: configDir)
      try? FileManager.default.removeItem(at: codexHome)
    }
    let context = CodexAgentCompatibilityContext(codexHome: codexHome.path, configDir: configDir.path)

    let day = codexHome.appendingPathComponent("sessions/2026/02/20", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let rolloutA = day.appendingPathComponent("rollout-session-a.jsonl")
    try writeRollout(rolloutA, id: "session-a", cwd: configDir.path, source: "cli", branch: "main", message: "FindMe")
    let rolloutFiles = day.appendingPathComponent("rollout-session-files.jsonl")
    try writeRollout(rolloutFiles, id: "session-files", cwd: configDir.path, source: "cli", branch: "files", message: "files")
    try "{\"timestamp\":\"2025-05-07T17:26:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"patch\":\"*** Add File: Sources/A.swift\\n\"}}".appendLine(to: rolloutFiles)
    try writeRollout(day.appendingPathComponent("rollout-session-b.jsonl"), id: "session-b", cwd: "/tmp/other", source: "exec", branch: "dev", message: "skip")
    let cliList = CodexCLICommandExecutor.execute(arguments: ["session", "list", "--source", "cli", "--cwd", configDir.path, "--branch", "main", "--limit", "1"], context: context)
    XCTAssertEqual(cliList.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(cliList.data)?["total"]), 1)
    let list = CodexGraphQLCommandExecutor.execute(
      command: "session.list",
      variables: [
        "source": .string("cli"),
        "cwd": .string(configDir.path),
        "branch": .string("main"),
        "limit": .number(1),
        "offset": .number(0)
      ],
      context: context
    )
    XCTAssertEqual(jsonNumber(jsonObject(list.data)?["total"]), 1)
    let search = CodexGraphQLCommandExecutor.execute(command: "session.search", variables: ["query": .string("findme"), "role": .string("user"), "caseSensitive": .bool(false), "limit": .number(1)], context: context)
    XCTAssertEqual(jsonArray(jsonObject(search.data)?["sessionIds"]), [.string("session-a")])
    XCTAssertEqual(jsonNumber(jsonObject(search.data)?["offset"]), 0)
    XCTAssertEqual(jsonNumber(jsonObject(search.data)?["limit"]), 1)
    XCTAssertNotNil(jsonObject(search.data)?["durationMs"])
    let byteLimitedSearch = CodexGraphQLCommandExecutor.execute(command: "session.search", variables: ["query": .string("findme"), "role": .string("user"), "maxBytes": .number(20)], context: context)
    XCTAssertEqual(jsonArray(jsonObject(byteLimitedSearch.data)?["sessionIds"]), [.string("session-a")])
    XCTAssertEqual(jsonObject(byteLimitedSearch.data)?["truncated"], .bool(false))
    let cappedSearch = CodexGraphQLCommandExecutor.execute(command: "session.search", variables: ["query": .string("FindMe"), "maxSessions": .number(0)], context: context)
    XCTAssertEqual(jsonArray(jsonObject(cappedSearch.data)?["sessionIds"]), [])
    let negativeSearch = CodexGraphQLCommandExecutor.execute(command: "session.search", variables: ["query": .string("FindMe"), "maxSessions": .number(-1), "offset": .number(-1), "limit": .number(-1)], context: context)
    XCTAssertEqual(negativeSearch.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(negativeSearch.data)?["sessionIds"]), [])
    let wrapperSearch = CodexGraphQLCommandExecutor.execute(
      command: #"query ($param: JSON) { command(name: "session.search", params: $param) }"#,
      variables: ["param": .object(["query": .string("findme"), "role": .string("user")])],
      context: context
    )
    XCTAssertEqual(jsonArray(jsonObject(wrapperSearch.data)?["sessionIds"]), [.string("session-a")])
    let transcript = CodexGraphQLCommandExecutor.execute(command: "session.searchTranscript", variables: ["id": .string("session-a"), "query": .string("FindMe")], context: context)
    XCTAssertEqual(jsonObject(transcript.data)?["matched"], .bool(true))
    XCTAssertEqual(jsonNumber(jsonObject(transcript.data)?["matchCount"]), 1)
    XCTAssertEqual(jsonNumber(jsonObject(transcript.data)?["scannedEvents"]), 1)
    let missingTranscript = CodexGraphQLCommandExecutor.execute(command: "session.searchTranscript", variables: ["id": .string("missing-session"), "query": .string("FindMe")], context: context)
    XCTAssertEqual(missingTranscript.errors, [])
    XCTAssertEqual(jsonString(jsonObject(missingTranscript.data)?["sessionId"]), "missing-session")
    XCTAssertEqual(jsonObject(missingTranscript.data)?["matched"], .bool(false))
    let cliTranscript = CodexCLICommandExecutor.execute(arguments: ["session", "searchTranscript", "session-a", "FindMe"], context: context)
    XCTAssertEqual(cliTranscript.errors, [])
    XCTAssertEqual(jsonObject(cliTranscript.data)?["matched"], .bool(true))
    let watch = CodexGraphQLCommandExecutor.execute(
      command: #"subscription ($param: JSON) { command(name: "session.watch", params: $param) }"#,
      variables: ["param": .object(["id": .string("session-a"), "startOffset": .number(0)])],
      context: context
    )
    XCTAssertEqual(watch.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(watch.data)?["events"])?.count, 2)
    let negativeOffsetWatch = CodexGraphQLCommandExecutor.execute(command: "session.watch", variables: ["id": .string("session-a"), "startOffset": .number(-1)], context: context)
    XCTAssertEqual(negativeOffsetWatch.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(negativeOffsetWatch.data)?["events"])?.count, 2)
    let defaultOffsetWatch = CodexGraphQLCommandExecutor.execute(command: "session.watch", variables: ["id": .string("session-a")], context: context)
    XCTAssertEqual(defaultOffsetWatch.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(defaultOffsetWatch.data)?["events"])?.count, 2)
    let liveWatch = try CodexGraphQLCommandExecutor.watchSession(id: "session-a", codexHome: codexHome.path)
    defer {
      liveWatch.cancel()
    }
    try #"{"timestamp":"2025-05-07T17:27:00.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"Live watch"}}"#.appendLine(to: rolloutA)
    XCTAssertEqual(liveWatch.next(timeout: 1)?.payload, .object(["type": .string("AgentMessage"), "message": .string("Live watch")]))
    let cliFileList = CodexCLICommandExecutor.execute(arguments: ["files", "list", "session-files", "codexHome=\(codexHome.path)"], context: context)
    XCTAssertEqual(jsonString(jsonObject(cliFileList.data)?["sessionId"]), "session-files")
    XCTAssertEqual(jsonNumber(jsonObject(cliFileList.data)?["totalFiles"]), 1)
    XCTAssertEqual(jsonString(jsonObject(jsonArray(jsonObject(cliFileList.data)?["files"])?.first)?["path"]), "Sources/A.swift")
    let cliPatches = CodexCLICommandExecutor.execute(arguments: ["files", "patches", "session-files", "codexHome=\(codexHome.path)"], context: context)
    XCTAssertEqual(jsonString(jsonObject(cliPatches.data)?["sessionId"]), "session-files")
    XCTAssertEqual(jsonNumber(jsonObject(cliPatches.data)?["totalFiles"]), 1)
    XCTAssertEqual(jsonNumber(jsonObject(cliPatches.data)?["totalChanges"]), 1)
    let firstPatchFile = jsonObject(jsonArray(jsonObject(cliPatches.data)?["files"])?.first)
    XCTAssertEqual(jsonString(firstPatchFile?["path"]), "Sources/A.swift")
    let firstPatchChange = jsonObject(jsonArray(firstPatchFile?["changes"])?.first)
    XCTAssertTrue(jsonString(firstPatchChange?["patch"])?.contains("*** Add File: Sources/A.swift\\n") == true)
    let rebuild = CodexGraphQLCommandExecutor.execute(command: "files.rebuild", context: context)
    XCTAssertEqual(rebuild.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(rebuild.data)?["indexedSessions"]), 3)
    let fileFind = CodexGraphQLCommandExecutor.execute(command: "files.find", variables: ["path": .string("Sources/A.swift")], context: context)
    XCTAssertEqual(fileFind.errors, [])
    XCTAssertEqual(jsonString(jsonObject(fileFind.data)?["path"]), "Sources/A.swift")
    XCTAssertEqual(jsonString(jsonObject(jsonArray(jsonObject(fileFind.data)?["sessions"])?.first)?["sessionId"]), "session-files")

    try writeRollout(day.appendingPathComponent("rollout-session-long.jsonl"), id: "session-long", cwd: configDir.path, source: "cli", branch: "long", message: "Needle " + String(repeating: "x", count: 100))
    let longPrefixTranscript = CodexGraphQLCommandExecutor.execute(command: "session.searchTranscript", variables: ["id": .string("session-long"), "query": .string("Needle"), "maxBytes": .number(10)], context: context)
    XCTAssertEqual(longPrefixTranscript.errors, [])
    XCTAssertEqual(jsonObject(longPrefixTranscript.data)?["matched"], .bool(true))
    XCTAssertEqual(jsonNumber(jsonObject(longPrefixTranscript.data)?["matchCount"]), 1)
    XCTAssertEqual(jsonObject(longPrefixTranscript.data)?["truncated"], .bool(true))
  }

  func testFailedProcessStreamStartupClosesLineStream() {
    let manager = CodexProcessManager(executableName: "codex")
    let stream = manager.spawnExecStream(
      prompt: "hello",
      options: CodexProcessOptions(cwd: "/definitely/missing/riela/codex-agent-test")
    )

    XCTAssertEqual(stream.waitForCompletion(), 127)
    XCTAssertNil(stream.lines.next(timeout: nil))
  }

  func testGraphQLExecutesOperationalCommandsTokensFilesAndDefaultProcess() throws {
    let configDir = try makeTemporaryDirectory()
    let codexHome = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: configDir)
      try? FileManager.default.removeItem(at: codexHome)
    }
    let context = CodexAgentCompatibilityContext(codexHome: codexHome.path, configDir: configDir.path)

    let queueCreate = CodexGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("release"), "projectPath": .string("/project")], context: context)
    XCTAssertEqual(queueCreate.errors, [])
    let queueId = try XCTUnwrap(jsonString(jsonObject(queueCreate.data)?["id"]))
    let prompt = CodexGraphQLCommandExecutor.execute(command: "queue.add", variables: ["id": .string(queueId), "prompt": .string("ship")], context: context)
    let promptId = try XCTUnwrap(jsonString(jsonObject(prompt.data)?["id"]))
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "queue.move", variables: ["id": .string(queueId), "promptId": .string(promptId), "toIndex": .number(0)], context: context).errors, [])
    XCTAssertEqual(try CodexQueuePersistence.findQueue(queueId, configDir: configDir.path)?.prompts.map(\.id), [promptId])
    let cliQueueWithoutProject = CodexCLICommandExecutor.execute(arguments: ["queue", "create", "cli-release", "configDir=\(configDir.path)"], context: context)
    XCTAssertEqual(cliQueueWithoutProject.errors, ["missingVariable(\"projectPath\")"])

    let group = CodexGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("parallel"), "description": .string("release batch")], context: context)
    let groupId = try XCTUnwrap(jsonString(jsonObject(group.data)?["id"]))
    XCTAssertEqual(try CodexGroupPersistence.findGroup(groupId, configDir: configDir.path)?.description, "release batch")
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "group.add", variables: ["id": .string(groupId), "sessionId": .string("session-a")], context: context).errors, [])
    XCTAssertEqual(try CodexGroupPersistence.findGroup(groupId, configDir: configDir.path)?.sessionIds, ["session-a"])

    XCTAssertFalse(CodexGraphQLCommandExecutor.execute(command: "bookmark.add", variables: ["type": .string("bad"), "sessionId": .string("session-a")], context: context).errors.isEmpty)
    let bookmark = CodexGraphQLCommandExecutor.execute(
      command: "bookmark.add",
      variables: [
        "type": .string("session"),
        "sessionId": .string("session-a"),
        "name": .string("postmortem"),
        "description": .string("postmortem"),
        "tags": .array([.string("Review")])
      ],
      context: context
    )
    let bookmarkId = try XCTUnwrap(jsonString(jsonObject(bookmark.data)?["id"]))
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "bookmark.search", variables: ["query": .string("post")], context: context).errors, [])
    let bookmarkSearch = CodexGraphQLCommandExecutor.execute(command: "bookmark.search", variables: ["query": .string("post"), "limit": .number(1)], context: context)
    let bookmarkResults = try XCTUnwrap(jsonArray(bookmarkSearch.data))
    XCTAssertEqual(bookmarkResults.count, 1)
    XCTAssertNotNil(jsonObject(bookmarkResults.first)?["score"])
    XCTAssertEqual(try CodexBookmarkPersistence.getBookmark(id: bookmarkId, configDir: configDir.path)?.tags, ["Review"])
    let cliBookmark = CodexCLICommandExecutor.execute(
      arguments: [
        "bookmark", "add",
        "--type", "message",
        "--session", "session-a",
        "--message", "message-a",
        "--name", "cli note",
        "--description", "cli note",
        "--tag", "Review",
        "--tag", "Ship",
        "configDir=\(configDir.path)"
      ],
      context: context
    )
    XCTAssertEqual(cliBookmark.errors, [])
    let cliBookmarkId = try XCTUnwrap(jsonString(jsonObject(cliBookmark.data)?["id"]))
    XCTAssertEqual(try CodexBookmarkPersistence.getBookmark(id: cliBookmarkId, configDir: configDir.path)?.tags, ["Review", "Ship"])
    let cliRangeBookmark = CodexCLICommandExecutor.execute(
      arguments: [
        "bookmark", "add",
        "--type", "range",
        "--session", "session-a",
        "--name", "range note",
        "--from", "message-a",
        "--to", "message-b",
        "configDir=\(configDir.path)"
      ],
      context: context
    )
    XCTAssertEqual(cliRangeBookmark.errors, [])
    let cliRangeBookmarkId = try XCTUnwrap(jsonString(jsonObject(cliRangeBookmark.data)?["id"]))
    XCTAssertEqual(try CodexBookmarkPersistence.getBookmark(id: cliRangeBookmarkId, configDir: configDir.path)?.fromMessageId, "message-a")
    let cliBookmarkList = CodexCLICommandExecutor.execute(arguments: ["bookmark", "list", "--session", "session-a", "--type", "message", "--tag", "ship", "configDir=\(configDir.path)"], context: context)
    XCTAssertEqual(cliBookmarkList.errors, [])
    XCTAssertEqual(jsonArray(cliBookmarkList.data)?.count, 1)

    let tokenCreate = CodexGraphQLCommandExecutor.execute(command: "token.create", variables: ["name": .string("ci"), "permissions": .array([.string("session:read")])], context: context)
    let rawToken = try XCTUnwrap(jsonString(tokenCreate.data))
    XCTAssertNotNil(try CodexTokenPersistence.verify(rawToken: rawToken, permission: "session:read", configDir: configDir.path))
    XCTAssertNil(try CodexTokenPersistence.verify(rawToken: rawToken, permission: "session:write", configDir: configDir.path))
    let listedTokens = CodexGraphQLCommandExecutor.execute(command: "token.list", context: context)
    XCTAssertFalse(String(describing: listedTokens.data).contains(rawToken))
    let tokenId = String(rawToken.split(separator: ".", maxSplits: 1).first ?? "")
    let rotated = CodexGraphQLCommandExecutor.execute(command: "token.rotate", variables: ["id": .string(tokenId)], context: context)
    let rotatedToken = try XCTUnwrap(jsonString(rotated.data))
    XCTAssertNotEqual(rotatedToken, rawToken)
    XCTAssertNil(try CodexTokenPersistence.verify(rawToken: rawToken, permission: "session:read", configDir: configDir.path))
    XCTAssertNotNil(try CodexTokenPersistence.verify(rawToken: rotatedToken, permission: "session:read", configDir: configDir.path))
    let cliTokenList = CodexCLICommandExecutor.execute(arguments: ["token", "list", "configDir=\(configDir.path)"], context: context)
    XCTAssertEqual(cliTokenList.errors, [])
    XCTAssertFalse(String(describing: cliTokenList.data).contains(rotatedToken))

    let day = codexHome.appendingPathComponent("sessions/2026/02/20", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let rollout = day.appendingPathComponent("rollout-files.jsonl")
    try [
      #"{"timestamp":"2026-02-20T10:00:00.000Z","type":"session_meta","payload":{"meta":{"id":"file-session","timestamp":"2026-02-20T10:00:00.000Z","cwd":"/tmp/project","source":"cli"}}}"#,
      #"{"timestamp":"2026-02-20T10:00:01.000Z","type":"event_msg","payload":{"patch":"*** Add File: Sources/New.swift\n"}}"#
    ].joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
    let files = CodexGraphQLCommandExecutor.execute(command: "files.list", variables: ["sessionId": .string("file-session")], context: context)
    XCTAssertEqual(jsonString(jsonObject(files.data)?["sessionId"]), "file-session")
    XCTAssertEqual(jsonNumber(jsonObject(files.data)?["totalFiles"]), 1)
    XCTAssertEqual(jsonString(jsonObject(jsonArray(jsonObject(files.data)?["files"])?.first)?["path"]), "Sources/New.swift")
    let cliFiles = CodexCLICommandExecutor.execute(arguments: ["files", "list", "file-session", "codexHome=\(codexHome.path)"], context: context)
    XCTAssertEqual(jsonString(jsonObject(jsonArray(jsonObject(cliFiles.data)?["files"])?.first)?["path"]), "Sources/New.swift")
    let found = CodexGraphQLCommandExecutor.execute(command: "files.find", variables: ["path": .string("Sources/New.swift")], context: context)
    XCTAssertEqual(jsonString(jsonObject(found.data)?["path"]), "Sources/New.swift")

    let fakeCodex = try createExecutable(
      directory: configDir,
      name: "fake-codex.sh",
      body: """
      printf '{"timestamp":"2026-02-20T10:00:00.000Z","type":"session_meta","payload":{"meta":{"id":"process-session","timestamp":"2026-02-20T10:00:00.000Z","cwd":"%s","source":"exec"}}}\\n' "$PWD"
      printf '{"timestamp":"2026-02-20T10:00:01.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"done"}}\\n'
      """
    )
    let processRun = CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("hello"), "executableName": .string(fakeCodex.path), "cwd": .string(configDir.path)], context: context)
    XCTAssertEqual(processRun.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(processRun.data)?["exitCode"]), 0)
    XCTAssertEqual(jsonString(jsonObject(processRun.data)?["sessionId"]), "process-session")
    XCTAssertEqual(jsonArray(jsonObject(processRun.data)?["lines"])?.count, 2)
    XCTAssertTrue(jsonString(jsonObject(processRun.data)?["stdout"])?.contains("process-session") == true)
  }
}
