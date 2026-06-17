import Foundation
import Dispatch
import XCTest
@testable import ClaudeCodeAgent
@testable import RielaCore

final class ClaudeCodeAgentCompatibilityTests: XCTestCase {
  func testLegacyClaudeCodeAgentUnitTestSurfaceHasSwiftCoverage() throws {
    let coverage: [(category: String, legacyTests: [String], probe: () throws -> Void)] = [
      ("auth", ["duration.test.ts", "token-manager.test.ts"], {
        XCTAssertEqual(try ClaudeCodeDurationParser.seconds("1d"), 86_400)
        XCTAssertTrue(try ClaudeCodeTokenPersistence.createRawToken(name: "probe", permissions: ["session:read"], configDir: makeTemporaryDirectory().path).hasPrefix("cca_"))
      }),
      ("cli", ["activity/*.test.ts", "auth/*.test.ts", "bookmark.test.ts", "edge-cases.test.ts", "error-handling.test.ts", "graphql.test.ts", "group.test.ts", "main.test.ts", "output.test.ts", "queue.test.ts", "session.test.ts", "version.test.ts"], {
        XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["version", "includeGit=false"]).exitCode, 0)
      }),
      ("container-and-core", ["container.test.ts", "errors.test.ts", "lib.test.ts", "package-metadata.test.ts", "result.test.ts"], {
        XCTAssertEqual(ClaudeCodeProcessCommandBuilder.buildExecArguments(prompt: "probe").first, "-p")
      }),
      ("graphql", ["index.test.ts"], {
        XCTAssertEqual(try ClaudeCodeGraphQLCommandExecutor.parseParams(["limit=2"])["limit"], .number(2))
      }),
      ("polling", ["event-parser.test.ts", "group-monitor.test.ts", "monitor.test.ts", "output.test.ts", "parser.test.ts", "state-manager.test.ts", "watcher.test.ts"], {
        var parser = ClaudeCodeJsonlStreamParser()
        XCTAssertEqual(parser.feed(#"{"type":"assistant","content":"ok"}"# + "\n").first?.type, "assistant")
      }),
      ("repository", ["file/*.test.ts", "in-memory/*.test.ts"], {
        var repository = ClaudeCodeQueueRepository()
        XCTAssertEqual(repository.createQueue(name: "probe").name, "probe")
      }),
      ("sdk", ["agent.test.ts", "client.test.ts", "control-protocol.test.ts", "environment.test.ts", "errors.test.ts", "exports.test.ts", "jsonl-parser.test.ts", "mock-session-runner.test.ts", "readiness.test.ts", "receiver.test.ts", "session-reader.test.ts", "session-state.test.ts", "tool-registry.test.ts", "tool-versions.test.ts", "tool-call.integration.test.ts"], {
        let manager = ClaudeCodeProcessManager(executableName: "claude-probe") { _, _, _ in ClaudeCodeProcessExecution(exitCode: 0) }
        XCTAssertEqual(manager.spawnExec(prompt: "probe").result.exitCode, 0)
      }),
      ("sdk-activity", ["hook-types.test.ts", "integration.test.ts", "manager.test.ts", "store.test.ts", "transcript-analyzer.test.ts"], {
        XCTAssertEqual(ClaudeCodeActivityAnalyzer.status(hookEventName: "PermissionRequest"), .waitingUserResponse)
      }),
      ("sdk-bookmarks", ["manager.test.ts", "search.test.ts"], {
        var manager = ClaudeCodeBookmarkManager()
        _ = try manager.create(type: .session, sessionId: "probe", name: "Probe")
        XCTAssertEqual(manager.search(text: "probe").count, 1)
      }),
      ("sdk-credentials", ["integration.test.ts", "manager.test.ts", "reader.test.ts", "validation.test.ts", "writer.test.ts"], {
        XCTAssertTrue(ClaudeCodeConfigReader.defaultConfigPath(environment: ["HOME": "/tmp/home"]).hasSuffix("/.claude.json"))
      }),
      ("sdk-file-changes", ["extractor.test.ts", "index-manager.test.ts", "service.test.ts"], {
        let index = ClaudeCodeFileChangeIndex(changes: [ClaudeCodeFileChange(path: "Sources/A.swift", operation: .modified, source: .shell)])
        XCTAssertEqual(index.find("Sources/A.swift")?.operation, .modified)
      }),
      ("sdk-group", ["config-generator.test.ts", "dependency-graph.test.ts", "events.test.ts", "manager.test.ts", "progress.test.ts", "runner.test.ts", "session-processor.test.ts", "types.test.ts"], {
        var groups = ClaudeCodeGroupRepository()
        XCTAssertEqual(groups.createGroup(name: "g").name, "g")
      }),
      ("sdk-markdown-parser", ["detectors.test.ts", "parser.test.ts"], {
        XCTAssertEqual(ClaudeCodeMarkdown.parseTasks("# Work\n- [x] done").first?.text, "done")
      }),
      ("sdk-queue", ["manager.test.ts", "recovery.test.ts", "runner.test.ts"], {
        var queues = ClaudeCodeQueueRepository()
        let queue = queues.createQueue(name: "q")
        XCTAssertNotNil(queues.addPrompt(queueId: queue.id, prompt: "p"))
      }),
      ("services", ["atomic-writer.test.ts", "file-lock.test.ts"], {
        let store = ClaudeCodeJSONStore<ClaudeCodeQueuesConfig>(url: try makeTemporaryDirectory().appendingPathComponent("queues.json"))
        try store.save(ClaudeCodeQueuesConfig())
      }),
      ("test-support", ["fixtures.test.ts", "helpers.test.ts", "mocks/*.test.ts", "utils/concurrency.test.ts"], {
        XCTAssertFalse(try makeTemporaryDirectory().path.isEmpty)
      }),
      ("types", ["activity.test.ts", "types.test.ts"], {
        XCTAssertEqual(ClaudeCodeActivityStatusValue.waitingUserResponse.rawValue, "waiting_user_response")
      }),
    ]

    XCTAssertEqual(coverage.count, 17)
    XCTAssertTrue(coverage.allSatisfy { !$0.legacyTests.isEmpty })
    XCTAssertTrue(coverage.first { $0.category == "sdk" }?.legacyTests.contains("control-protocol.test.ts") == true)
    XCTAssertTrue(coverage.first { $0.category == "sdk-credentials" }?.legacyTests.contains("reader.test.ts") == true)
    XCTAssertTrue(coverage.first { $0.category == "polling" }?.legacyTests.contains("parser.test.ts") == true)
    try coverage.forEach { try $0.probe() }
  }

  func testClaudeProcessBuilderMatchesLegacyCliShape() {
    let args = ClaudeCodeProcessCommandBuilder.buildExecArguments(
      prompt: "fix bug",
      options: ClaudeCodeProcessOptions(
        model: "claude-sonnet-4",
        approvalMode: "acceptEdits",
        fullAuto: true,
        images: ["/tmp/a/image.png", "/tmp/b/doc.txt"],
        additionalArguments: ["--max-turns", "3"],
        systemPrompt: "system"
      )
    )

    XCTAssertEqual(args.prefix(3), ["-p", "--output-format", "stream-json"])
    XCTAssertTrue(args.containsSubsequence(["--model", "claude-sonnet-4"]))
    XCTAssertTrue(args.containsSubsequence(["--permission-mode", "acceptEdits"]))
    XCTAssertTrue(args.contains("--dangerously-skip-permissions"))
    XCTAssertTrue(args.containsSubsequence(["--system-prompt", "system"]))
    XCTAssertTrue(args.containsSubsequence(["--add-dir", "/tmp/a"]))
    XCTAssertTrue(args.containsSubsequence(["--add-dir", "/tmp/b"]))
    XCTAssertEqual(args.last, "fix bug")
    XCTAssertTrue(ClaudeCodeProcessCommandBuilder.buildExecArguments(prompt: "ask", options: ClaudeCodeProcessOptions(approvalMode: "ask")).containsSubsequence(["--permission-mode", "ask"]))
    XCTAssertTrue(ClaudeCodeProcessCommandBuilder.buildExecArguments(prompt: "allow", options: ClaudeCodeProcessOptions(approvalMode: "allow_all")).containsSubsequence(["--permission-mode", "allow_all"]))
    let sanitized = ClaudeCodeProcessCommandBuilder.buildExecArguments(
      prompt: "safe",
      options: ClaudeCodeProcessOptions(additionalArguments: ["--output-format", "text", "--input-format=json", "--print", "-p", "--max-turns", "3"])
    )
    XCTAssertFalse(sanitized.contains("text"))
    XCTAssertFalse(sanitized.contains("--input-format=json"))
    XCTAssertEqual(sanitized.filter { $0 == "-p" }.count, 1)
    XCTAssertTrue(sanitized.containsSubsequence(["--max-turns", "3"]))

    let resume = ClaudeCodeProcessCommandBuilder.buildResumeArguments(sessionId: "session-1", prompt: "continue")
    XCTAssertEqual(resume.prefix(5), ["-p", "--output-format", "stream-json", "--resume", "session-1"])
    XCTAssertEqual(resume.last, "continue")

    let env = ClaudeCodeProcessCommandBuilder.buildEnvironment(base: [:], options: ClaudeCodeProcessOptions(claudeCodeHome: "/tmp/claude-config"))
    XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/tmp/claude-config")
  }

  func testProcessManagerExecutesInjectedRunnerAndRecordsLifecycle() {
    let manager = ClaudeCodeProcessManager(executableName: "claude-test") { arguments, prompt, environment in
      XCTAssertEqual(arguments.first, "claude-test")
      XCTAssertEqual(prompt, "hello")
      XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/claude-home")
      return ClaudeCodeProcessExecution(stdout: #"{"type":"assistant","content":"ok"}"#, stderr: "", exitCode: 0)
    }

    let run = manager.spawnExec(prompt: "hello", options: ClaudeCodeProcessOptions(claudeCodeHome: "/tmp/claude-home"))
    XCTAssertEqual(run.result.exitCode, 0)
    XCTAssertEqual(run.process.status, .exited)
    XCTAssertEqual(manager.list().count, 1)
    XCTAssertEqual(manager.prune(), 1)
  }

  func testTokenPersistenceUsesLegacyCcaTokensAndSha256Hashes() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }

    let raw = try ClaudeCodeTokenPersistence.createRawToken(name: "bot", permissions: ["session:read", "group:run", "queue:*"], configDir: config.path)
    XCTAssertTrue(raw.hasPrefix("cca_"))
    XCTAssertEqual(raw.split(separator: ".").count, 1)

    let metadata = try XCTUnwrap(ClaudeCodeTokenPersistence.verify(rawToken: raw, permission: "session:read", configDir: config.path))
    XCTAssertEqual(metadata.name, "bot")
    XCTAssertNotNil(metadata.lastUsedAt)
    XCTAssertNotNil(try ClaudeCodeTokenPersistence.verify(rawToken: raw, permission: "group:run", configDir: config.path))
    XCTAssertNotNil(try ClaudeCodeTokenPersistence.verify(rawToken: raw, permission: "queue:add", configDir: config.path))
    XCTAssertNil(try ClaudeCodeTokenPersistence.verify(rawToken: raw, permission: "group:delete", configDir: config.path))
    XCTAssertEqual(ClaudeCodeTokenManager.normalizePermissions(["group:create", "group:run", "group:*"]), ["group:create", "group:run"])

    XCTAssertFalse(FileManager.default.fileExists(atPath: config.appendingPathComponent("tokens.json").path))
    let tokenFile = try String(contentsOf: config.appendingPathComponent("api-tokens.json"), encoding: .utf8)
    XCTAssertTrue(tokenFile.contains(#""hash""#))
    XCTAssertTrue(tokenFile.contains("sha256:"))
    XCTAssertTrue(tokenFile.contains(#""lastUsedAt""#))
    XCTAssertTrue(tokenFileContainsLegacyTimestamp(tokenFile, key: "createdAt"))
    XCTAssertTrue(tokenFileContainsLegacyTimestamp(tokenFile, key: "lastUsedAt"))
    XCTAssertFalse(tokenFile.contains(raw))

    let context = ClaudeCodeAgentCompatibilityContext(configDir: config.path)
    let expiringToken = ClaudeCodeAgentCLIApplication.run(arguments: ["token", "create", "--name", "expiring", "--expires", "7d"], context: context)
    XCTAssertEqual(expiringToken.exitCode, 0)
    let expiringMetadata = try XCTUnwrap(try ClaudeCodeTokenPersistence.listMetadata(configDir: config.path).first { $0.name == "expiring" })
    XCTAssertNotNil(expiringMetadata.expiresAt)
    XCTAssertEqual(Set(expiringMetadata.permissions), Set(["session:read", "session:create"]))
    let tokenFileWithExpiry = try String(contentsOf: config.appendingPathComponent("api-tokens.json"), encoding: .utf8)
    XCTAssertTrue(tokenFileContainsLegacyTimestamp(tokenFileWithExpiry, key: "expiresAt"))
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["token", "create", "--name", "bad", "--expires", "0d"], context: context).exitCode, 1)
    let expiredRaw = try ClaudeCodeTokenPersistence.createRawToken(name: "expired", permissions: ["session:read"], expiresAt: "2020-01-01T00:00:00.000Z", configDir: config.path)
    XCTAssertNil(try ClaudeCodeTokenPersistence.verify(rawToken: expiredRaw, permission: "session:read", configDir: config.path))
    let expiredMetadata = try XCTUnwrap(try ClaudeCodeTokenPersistence.listMetadata(configDir: config.path).first { $0.name == "expired" })

    let rotated = try XCTUnwrap(ClaudeCodeTokenPersistence.rotate(id: metadata.id, configDir: config.path))
    XCTAssertTrue(rotated.hasPrefix("cca_"))
    XCTAssertFalse(rotated.hasPrefix("cca_\(metadata.id)"))
    XCTAssertNil(try ClaudeCodeTokenPersistence.verify(rawToken: raw, permission: "session:read", configDir: config.path))
    XCTAssertNotNil(try ClaudeCodeTokenPersistence.verify(rawToken: rotated, permission: "session:read", configDir: config.path))
    let rotatedMetadata = try XCTUnwrap(try ClaudeCodeTokenPersistence.verify(rawToken: rotated, permission: "session:read", configDir: config.path))
    XCTAssertTrue(try ClaudeCodeTokenPersistence.revoke(id: rotatedMetadata.id, configDir: config.path))
    XCTAssertTrue(try ClaudeCodeTokenPersistence.revoke(id: expiringMetadata.id, configDir: config.path))
    XCTAssertTrue(try ClaudeCodeTokenPersistence.revoke(id: expiredMetadata.id, configDir: config.path))
    XCTAssertEqual(try ClaudeCodeTokenPersistence.listMetadata(configDir: config.path).map(\.id), [])
  }

  func testRepositoriesAndGraphQLFacadeMutateSwiftStores() throws {
    var queues = ClaudeCodeQueueRepository()
    let queue = queues.createQueue(name: "migration", projectPath: "/tmp/project")
    let prompt = try XCTUnwrap(queues.addPrompt(queueId: queue.id, prompt: "ship it"))
    XCTAssertTrue(queues.updatePrompt(queueId: queue.id, promptId: prompt.id, status: .completed, resultExitCode: 0))
    XCTAssertEqual(queues.getQueue(id: queue.id)?.prompts.first?.status, .completed)

    var groups = ClaudeCodeGroupRepository()
    let group = groups.createGroup(name: "parallel", description: "work")
    XCTAssertTrue(groups.addSession(groupId: group.id, sessionId: "session-a"))
    XCTAssertEqual(groups.getGroup(id: group.id)?.sessionIds, ["session-a"])

    var bookmarks = ClaudeCodeBookmarkManager()
    let bookmark = try bookmarks.create(type: .message, sessionId: "session-a", messageId: "msg-1", name: "important", tags: ["auth"])
    XCTAssertEqual(bookmarks.search(text: "important").map(\.id), [bookmark.id])

    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let context = ClaudeCodeAgentCompatibilityContext(configDir: config.path)
    let created = ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("graphql"), "projectPath": .string("/tmp/project")], context: context)
    let queueId = try XCTUnwrap(jsonString(jsonObject(created.data)?["id"]))
    let added = ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.addCommand", variables: ["id": .string(queueId), "prompt": .string("run")], context: context)
    XCTAssertNotNil(jsonObject(added.data)?["id"])
    let listed = ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.list", variables: [:], context: context)
    XCTAssertEqual(jsonArray(listed.data)?.count, 1)
  }

  func testDefaultStorageRootsMatchLegacySplitConfigAndDataLocations() {
    XCTAssertTrue(defaultClaudeCodeAgentConfigDir().hasSuffix("/.config/claude-code-agent"))
    XCTAssertTrue(defaultClaudeCodeAgentDataDir().hasSuffix("/.local/claude-code-agent"))
    XCTAssertNotEqual(defaultClaudeCodeAgentConfigDir(), defaultClaudeCodeAgentDataDir())
  }

  func testGraphQLLegacyAliasesParamsAndErrorsAreCovered() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let context = ClaudeCodeAgentCompatibilityContext(configDir: config.path)

    XCTAssertEqual(ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.nope", context: context).errors, ["Unknown command: queue.nope"])
    XCTAssertEqual(ClaudeCodeGraphQLCommandExecutor.execute(command: "subscription { command(name: \"queue.list\") }", context: context).errors, ["Unsupported subscription command: queue.list"])

    let params = try ClaudeCodeGraphQLCommandExecutor.parseParams(["limit=2", "active=true", #"payload={"a":1}"#])
    XCTAssertEqual(params["limit"], .number(2))
    XCTAssertEqual(params["active"], .bool(true))
    XCTAssertEqual(jsonObject(params["payload"])?.count, 1)

    let variablesPath = config.appendingPathComponent("variables.json")
    try #"{"name":"from-file","projectPath":"/tmp/project"}"#.write(to: variablesPath, atomically: true, encoding: .utf8)
    let loaded = try ClaudeCodeGraphQLCommandExecutor.loadVariables("@\(variablesPath.path)")
    XCTAssertEqual(loaded["name"], .string("from-file"))
    let arbitraryParamsVariable = ClaudeCodeGraphQLCommandExecutor.execute(
      command: #"query ($p: JSON) { command(name: "queue.create", params: $p) }"#,
      variables: ["p": .object(["name": .string("from-p"), "projectPath": .string("/tmp/p")])],
      context: context
    )
    XCTAssertNotNil(jsonObject(arbitraryParamsVariable.data)?["id"])

    let groupCreate = ClaudeCodeGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("g")], context: context)
    let groupId = try XCTUnwrap(jsonString(jsonObject(groupCreate.data)?["id"]))
    let groupAdd = ClaudeCodeGraphQLCommandExecutor.execute(command: "group.addSession", variables: ["id": .string(groupId), "sessionId": .string("s1")], context: context)
    XCTAssertEqual(jsonObject(groupAdd.data)?["ok"], .bool(true))
    let fullSessionAdd = ClaudeCodeGraphQLCommandExecutor.execute(command: "group.addSession", variables: [
      "id": .string(groupId),
      "session": .object([
        "id": .string("s2"),
        "projectPath": .string("/tmp/project"),
        "prompt": .string("ship"),
        "status": .string("pending"),
        "dependsOn": .array([.string("s1")]),
      ]),
    ], context: context)
    XCTAssertEqual(jsonObject(fullSessionAdd.data)?["ok"], .bool(true))
    let groupWithSessionObject = try XCTUnwrap(try ClaudeCodeGroupPersistence.findGroup(groupId, configDir: config.path))
    XCTAssertEqual(groupWithSessionObject.sessions.first { $0.id == "s2" }?.projectPath, "/tmp/project")
    let groupPause = ClaudeCodeGraphQLCommandExecutor.execute(command: "group.pause", variables: ["id": .string(groupId)], context: context)
    XCTAssertEqual(jsonObject(groupPause.data)?["success"], .bool(true))
    XCTAssertEqual(jsonObject(groupPause.data)?["id"], .string(groupId))
    let groupResume = ClaudeCodeGraphQLCommandExecutor.execute(command: "group.resume", variables: ["id": .string(groupId)], context: context)
    XCTAssertEqual(jsonObject(groupResume.data)?["success"], .bool(true))
    let deletableGroupId = try XCTUnwrap(jsonString(jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("delete-me")], context: context).data)?["id"]))
    let groupDelete = ClaudeCodeGraphQLCommandExecutor.execute(command: "group.delete", variables: ["id": .string(deletableGroupId)], context: context)
    XCTAssertEqual(jsonObject(groupDelete.data)?["success"], .bool(true))
    XCTAssertEqual(jsonObject(groupDelete.data)?["id"], .string(deletableGroupId))

    let bookmark = ClaudeCodeGraphQLCommandExecutor.execute(
      command: "bookmark.add",
      variables: ["type": .string("message"), "sessionId": .string("s1"), "messageId": .string("m1"), "name": .string("Needle")],
      context: context
    )
    XCTAssertNotNil(jsonObject(bookmark.data)?["id"])
    let bookmarkSearch = ClaudeCodeGraphQLCommandExecutor.execute(command: "bookmark.search", variables: ["query": .string("Needle")], context: context)
    XCTAssertEqual(jsonArray(bookmarkSearch.data)?.count, 1)
    let bookmarkId = try XCTUnwrap(jsonString(jsonObject(bookmark.data)?["id"]))
    let bookmarkDelete = ClaudeCodeGraphQLCommandExecutor.execute(command: "bookmark.delete", variables: ["id": .string(bookmarkId)], context: context)
    XCTAssertEqual(jsonObject(bookmarkDelete.data)?["deleted"], .bool(true))

    let token = ClaudeCodeGraphQLCommandExecutor.execute(command: "token.create", variables: ["name": .string("bot"), "permissions": .array([.string("session:read")])], context: context)
    let rawToken = try XCTUnwrap(jsonString(token.data))
    XCTAssertTrue(rawToken.hasPrefix("cca_"))

    let groupToken = ClaudeCodeGraphQLCommandExecutor.execute(command: "token.create", variables: ["name": .string("group-bot"), "permissions": .array([.string("group:run")])], context: context)
    let groupRawToken = try XCTUnwrap(jsonString(groupToken.data))
    XCTAssertNotNil(try ClaudeCodeTokenPersistence.verify(rawToken: groupRawToken, permission: "group:run", configDir: config.path))

    let limitedToken = try ClaudeCodeTokenPersistence.createRawToken(name: "limited", permissions: ["bookmark:*"], configDir: config.path)
    let tokenManagementError = "Token management commands are not available in token-authenticated GraphQL contexts"
    XCTAssertEqual(ClaudeCodeGraphQLCommandExecutor.execute(command: "token.list", context: ClaudeCodeAgentCompatibilityContext(configDir: config.path, authToken: limitedToken)).errors, [tokenManagementError])
    XCTAssertEqual(ClaudeCodeGraphQLCommandExecutor.execute(command: "token.create", variables: ["name": .string("blocked")], context: ClaudeCodeAgentCompatibilityContext(configDir: config.path, authToken: limitedToken)).errors, [tokenManagementError])
    XCTAssertEqual(ClaudeCodeGraphQLCommandExecutor.execute(command: "token.revoke", variables: ["id": .string("any")], context: ClaudeCodeAgentCompatibilityContext(configDir: config.path, authToken: "not-a-token")).errors, [tokenManagementError])
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["token", "create", "--name", "local-ok"], context: context).exitCode, 0)
    let permissionModeCheck = ClaudeCodeGraphQLCommandExecutor.execute(command: "model.check", variables: ["model": .string("claude-sonnet-4"), "approvalMode": .string("allow_all"), "executableName": .string("/usr/bin/true")], context: context)
    XCTAssertEqual(permissionModeCheck.errors, [])
  }

  func testAuthCliGraphQLPermissionsActivityAndSessionCompatibilityCommands() throws {
    let config = try makeTemporaryDirectory()
    let home = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: config)
      try? FileManager.default.removeItem(at: home)
    }

    try #"{"oauthAccount":{"accountUuid":"acct","emailAddress":"user@example.test","displayName":"User","organizationUuid":"org","organizationName":"Org","organizationBillingType":"pro","organizationRole":"admin"}}"#
      .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
    try writeClaudeCredentials(home: home, expiresAt: Date().addingTimeInterval(3600))

    let context = ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path)
    let authStatus = ClaudeCodeAgentCLIApplication.run(arguments: ["auth", "status"], context: context)
    XCTAssertEqual(authStatus.exitCode, 0)
    XCTAssertTrue(authStatus.stdout.contains(#""loggedIn":true"#))
    XCTAssertTrue(authStatus.stdout.contains(#""ready":true"#))
    let verify = ClaudeCodeAgentCLIApplication.run(arguments: ["auth", "verify", "--model", "claude-sonnet-4"], context: context)
    XCTAssertEqual(verify.exitCode, 0)
    XCTAssertTrue(verify.stdout.contains(#""requested":"claude-sonnet-4"#))

    let missingAuth = ClaudeCodeAgentCLIApplication.run(arguments: ["auth", "status"], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: config.appendingPathComponent("missing-home").path, configDir: config.path))
    XCTAssertEqual(missingAuth.exitCode, 1)
    let accountOnlyHome = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: accountOnlyHome) }
    try #"{"oauthAccount":{"accountUuid":"acct","emailAddress":"user@example.test","displayName":"User","organizationUuid":"org","organizationName":"Org","organizationBillingType":"pro","organizationRole":"admin"}}"#
      .write(to: accountOnlyHome.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["auth", "status"], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: accountOnlyHome.path, configDir: config.path)).exitCode, 1)
    try writeClaudeCredentials(home: accountOnlyHome, expiresAt: Date().addingTimeInterval(-3600))
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["auth", "status"], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: accountOnlyHome.path, configDir: config.path)).exitCode, 1)

    let bookmarkOnlyToken = try ClaudeCodeTokenPersistence.createRawToken(name: "bookmark", permissions: ["bookmark:*"], configDir: config.path)
    let denied = ClaudeCodeGraphQLCommandExecutor.execute(command: "session.list", context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: bookmarkOnlyToken))
    XCTAssertEqual(denied.errors, ["Missing permission: session:read"])

    let sessionToken = try ClaudeCodeTokenPersistence.createRawToken(name: "session", permissions: ["session:read"], configDir: config.path)
    let authorized = ClaudeCodeGraphQLCommandExecutor.execute(command: "session.list", context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(authorized.errors, [])
    XCTAssertNotNil(jsonArray(authorized.data))
    for command in ["session.create", "session.cancel", "session.pause", "session.resume"] {
      XCTAssertEqual(
        ClaudeCodeGraphQLCommandExecutor.execute(command: command, context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken)).errors,
        ["Missing permission: session:create"]
      )
    }
    let sessionCreateToken = try ClaudeCodeTokenPersistence.createRawToken(name: "session-create", permissions: ["session:create"], configDir: config.path)
    XCTAssertEqual(
      ClaudeCodeGraphQLCommandExecutor.execute(command: "session.create", context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionCreateToken)).errors,
      ["session.create is not implemented in this runtime"]
    )

    let store = ClaudeCodeActivityStore(dataDir: config.path)
    try store.save([ClaudeCodeStoredActivityEntry(sessionId: "session-auth", status: .working, updatedAt: "2026-06-17T00:00:00Z")])
    let activityList = ClaudeCodeGraphQLCommandExecutor.execute(command: "activity.list", context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(jsonObject(activityList.data)?["entries"])?.count, 1)
    let activityGet = ClaudeCodeGraphQLCommandExecutor.execute(command: "activity.get", variables: ["sessionId": .string("session-auth")], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(activityGet.data)?["status"], .string("working"))

    try writeClaudeRollout(home: home, sessionId: "session-auth")
    try writeClaudeRollout(home: home, sessionId: "session-other", cwd: "/tmp/other")
    try writeClaudeSQLiteState(home: home, sessionId: "sqlite-session")
    try writeLegacyClaudeProjectSession(home: home, projectPath: "/tmp/legacy-project", sessionId: "88487b4c-f3f6-4a49-b59b-d1d4a098425f")
    try writeLegacyClaudeProjectSessionWithoutCwd(home: home, encodedProjectPath: "my-project", sessionId: "relative-legacy-session")
    let sessionGet = ClaudeCodeGraphQLCommandExecutor.execute(command: "session.get", variables: ["id": .string("session-auth")], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(sessionGet.data)?["id"], .string("session-auth"))
    let projectSessions = ClaudeCodeGraphQLCommandExecutor.execute(command: "session.list", variables: ["projectPath": .string("/tmp/project")], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(projectSessions.data)?.map { jsonObject($0)?["id"] }, [.string("session-auth")])
    let sqliteSessions = ClaudeCodeGraphQLCommandExecutor.execute(command: "session.list", variables: ["projectPath": .string("/tmp/sqlite-project")], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(sqliteSessions.data)?.map { jsonObject($0)?["id"] }, [.string("sqlite-session")])
    let legacyProjectSessions = ClaudeCodeGraphQLCommandExecutor.execute(command: "session.list", variables: ["projectPath": .string("/tmp/legacy-project")], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(legacyProjectSessions.data)?.map { jsonObject($0)?["id"] }, [.string("88487b4c-f3f6-4a49-b59b-d1d4a098425f")])
    let relativeLegacyProjectSessions = ClaudeCodeGraphQLCommandExecutor.execute(command: "session.list", variables: ["projectPath": .string("my/project")], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(relativeLegacyProjectSessions.data)?.map { jsonObject($0)?["id"] }, [.string("relative-legacy-session")])
    let legacyMessages = ClaudeCodeGraphQLCommandExecutor.execute(command: "session.messages", variables: ["id": .string("88487b4c-f3f6-4a49-b59b-d1d4a098425f")], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    let legacyUserPayload = jsonArray(jsonObject(legacyMessages.data)?["messages"])?
      .compactMap { jsonObject(jsonObject($0)?["payload"]) }
      .first { $0["type"] == .string("UserMessage") }
    XCTAssertEqual(legacyUserPayload?["message"], .string("hello legacy"))
    let messages = ClaudeCodeGraphQLCommandExecutor.execute(command: "session.messages", variables: ["id": .string("session-auth")], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(jsonObject(messages.data)?["messages"])?.count, 2)
    let typedSessions = ClaudeCodeGraphQLCommandExecutor.execute(command: #"query { sessions { nodes { id messageCount } total } }"#, context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(jsonObject(typedSessions.data)?["sessions"])?.keys.contains("nodes"), true)
    let typedSessionHistory = ClaudeCodeGraphQLCommandExecutor.execute(command: #"query { session(id: "session-auth") { id history(limit: 1) { total events { type } } } }"#, context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(jsonObject(typedSessionHistory.data)?["session"])?.keys.contains("history"), true)
    let typedSessionGrep = ClaudeCodeGraphQLCommandExecutor.execute(command: #"query { session(id: "session-auth") { grep(query: "hello", maxMatches: 5) { matched matchCount } } }"#, context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(jsonObject(typedSessionGrep.data)?["session"])?.keys.contains("grep"), true)
    let typedSearch = ClaudeCodeGraphQLCommandExecutor.execute(command: #"query { searchSessions(query: "hello") { sessionIds total scannedSessions } }"#, context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(jsonObject(typedSearch.data)?["searchSessions"])?.keys.contains("sessionIds"), true)

    let sessionResume = ClaudeCodeGraphQLCommandExecutor.execute(command: "session.resume", variables: ["id": .string("session-auth")], context: ClaudeCodeAgentCompatibilityContext(claudeCodeHome: home.path, configDir: config.path, authToken: sessionCreateToken))
    XCTAssertEqual(sessionResume.errors, ["session.resume is not implemented in this runtime"])
    XCTAssertEqual(ClaudeCodeGraphQLCommandExecutor.execute(command: "session.create", context: context).errors, ["session.create is not implemented in this runtime"])
    XCTAssertEqual(ClaudeCodeGraphQLCommandExecutor.execute(command: "session.cancel", context: context).errors, ["session.cancel is not implemented in this runtime"])
    XCTAssertEqual(ClaudeCodeGraphQLCommandExecutor.execute(command: "session.pause", context: context).errors, ["session.pause is not implemented in this runtime"])
  }

  func testLegacyGroupQueueGetAliasesAndGroupPermissionBoundaries() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let context = ClaudeCodeAgentCompatibilityContext(configDir: config.path)

    let groupCreate = ClaudeCodeGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("g")], context: context)
    let groupId = try XCTUnwrap(jsonString(jsonObject(groupCreate.data)?["id"]))
    let queueCreate = ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("q"), "projectPath": .string("/tmp/project")], context: context)
    let queueId = try XCTUnwrap(jsonString(jsonObject(queueCreate.data)?["id"]))
    _ = ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("other"), "projectPath": .string("/tmp/other")], context: context)
    XCTAssertNotNil(jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.create", variables: ["projectPath": .string("/tmp/project-only")], context: context).data)?["id"])
    XCTAssertEqual(
      ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("missing-project")], context: context).errors,
      ["missingVariable(\"projectPath\")"]
    )

    XCTAssertEqual(jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "group.get", variables: ["id": .string(groupId)], context: context).data)?["id"], .string(groupId))
    XCTAssertEqual(jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.get", variables: ["id": .string(queueId)], context: context).data)?["id"], .string(queueId))
    XCTAssertEqual(jsonArray(ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.list", variables: ["projectPath": .string("/tmp/project")], context: context).data)?.count, 1)
    XCTAssertEqual(jsonArray(ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.list", variables: ["status": .string("pending")], context: context).data)?.count, 3)

    let readToken = try ClaudeCodeTokenPersistence.createRawToken(name: "reader", permissions: ["session:read"], configDir: config.path)
    let runToken = try ClaudeCodeTokenPersistence.createRawToken(name: "runner", permissions: ["group:run"], configDir: config.path)
    let createToken = try ClaudeCodeTokenPersistence.createRawToken(name: "creator", permissions: ["group:create"], configDir: config.path)

    XCTAssertEqual(
      ClaudeCodeGraphQLCommandExecutor.execute(command: "group.list", context: ClaudeCodeAgentCompatibilityContext(configDir: config.path, authToken: readToken)).errors,
      []
    )
    XCTAssertEqual(
      ClaudeCodeGraphQLCommandExecutor.execute(command: "group.delete", variables: ["id": .string(groupId)], context: ClaudeCodeAgentCompatibilityContext(configDir: config.path, authToken: runToken)).errors,
      ["Missing permission: group:create"]
    )
    XCTAssertEqual(
      jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "group.addSession", variables: ["id": .string(groupId), "sessionId": .string("s1")], context: ClaudeCodeAgentCompatibilityContext(configDir: config.path, authToken: createToken)).data)?["ok"],
      .bool(true)
    )
  }

  func testLegacyPerFileGroupAndBookmarkStoresRemainCompatible() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let legacyGroup = ClaudeCodeGroup(id: "legacy-group", name: "Legacy Group", sessionIds: ["s1"])
    let legacyGroupURL = ClaudeCodeGroupPersistence.legacyMetaURL(groupId: legacyGroup.id, configDir: config.path)
    try FileManager.default.createDirectory(at: legacyGroupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(legacyGroup).write(to: legacyGroupURL)

    let context = ClaudeCodeAgentCompatibilityContext(configDir: config.path)
    XCTAssertEqual(jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "group.get", variables: ["id": .string("legacy-group")], context: context).data)?["name"], .string("Legacy Group"))
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["group", "add", "legacy-group", "s2"], context: context).exitCode, 0)
    let savedGroup = try JSONDecoder().decode(ClaudeCodeGroup.self, from: Data(contentsOf: legacyGroupURL))
    XCTAssertEqual(savedGroup.sessionIds, ["s1", "s2"])

    let legacyBookmark = ClaudeCodeBookmark(id: "legacy-bookmark", type: .session, sessionId: "s1", name: "Legacy Bookmark", description: "needle", tags: ["legacy"])
    let legacyBookmarkURL = ClaudeCodeBookmarkPersistence.legacyURL(bookmarkId: legacyBookmark.id, configDir: config.path)
    try FileManager.default.createDirectory(at: legacyBookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(legacyBookmark).write(to: legacyBookmarkURL)

    XCTAssertEqual(jsonArray(ClaudeCodeGraphQLCommandExecutor.execute(command: "bookmark.list", variables: ["tag": .string("legacy")], context: context).data)?.count, 1)
    XCTAssertEqual(jsonArray(ClaudeCodeGraphQLCommandExecutor.execute(command: "bookmark.search", variables: ["query": .string("needle")], context: context).data)?.count, 1)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["bookmark", "delete", "legacy-bookmark"], context: context).exitCode, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyBookmarkURL.path))
  }

  func testLegacyCliFormsAndGraphQLQueueBookmarkParameters() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let context = ClaudeCodeAgentCompatibilityContext(configDir: config.path)

    let groupId = try XCTUnwrap(jsonString(jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("g")], context: context).data)?["id"]))
    let queueId = try XCTUnwrap(jsonString(jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("q"), "projectPath": .string("/tmp/project")], context: context).data)?["id"]))
    let rootFormat = ClaudeCodeAgentCLIApplication.run(arguments: ["--format", "json", "version"], context: context)
    XCTAssertEqual(rootFormat.exitCode, 0)
    XCTAssertTrue(rootFormat.stdout.contains("version"))
    XCTAssertNotNil(jsonObject(try JSONDecoder().decode(JSONValue.self, from: Data(rootFormat.stdout.utf8))))
    let localJson = ClaudeCodeAgentCLIApplication.run(arguments: ["version", "--json"], context: context)
    XCTAssertEqual(localJson.exitCode, 0)
    XCTAssertNotNil(jsonObject(try JSONDecoder().decode(JSONValue.self, from: Data(localJson.stdout.utf8))))
    let rootJson = ClaudeCodeAgentCLIApplication.run(arguments: ["--json", "version"], context: context)
    XCTAssertEqual(rootJson.exitCode, 0)
    XCTAssertNotNil(jsonObject(try JSONDecoder().decode(JSONValue.self, from: Data(rootJson.stdout.utf8))))
    let defaultTable = ClaudeCodeAgentCLIApplication.run(arguments: ["version"], context: context)
    XCTAssertEqual(defaultTable.exitCode, 0)
    XCTAssertTrue(defaultTable.stdout.contains("Tool"))
    XCTAssertFalse(defaultTable.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["--format", "xml", "version"], context: context).exitCode, 2)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["group", "watch", groupId], context: context).exitCode, 0)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["--json", "queue", "list"], context: context).exitCode, 0)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["--json", "group", "list"], context: context).exitCode, 0)

    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "add", queueId, "prompt=second"], context: context).exitCode, 0)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "add", queueId, "prompt=first", "position=0", "--session-mode", "new"], context: context).exitCode, 0)
    var queue = try XCTUnwrap(ClaudeCodeQueuePersistence.findQueue(queueId, configDir: config.path))
    XCTAssertEqual(queue.prompts.map(\.prompt), ["first", "second"])
    XCTAssertEqual(queue.prompts.first?.mode, .new)

    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "toggle-mode", queueId, "0"], context: context).exitCode, 0)
    queue = try XCTUnwrap(ClaudeCodeQueuePersistence.findQueue(queueId, configDir: config.path))
    XCTAssertEqual(queue.prompts.first?.mode, .continueMode)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "edit", queueId, "0", "--prompt", "edited"], context: context).exitCode, 0)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "move", queueId, "from=0", "to=1"], context: context).exitCode, 0)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "remove", queueId, "0"], context: context).exitCode, 0)
    XCTAssertEqual(ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.addCommand", variables: ["id": .string(queueId), "prompt": .string("shape")], context: context).errors, [])
    let removeCommandShape = ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.removeCommand", variables: ["id": .string(queueId), "index": .number(1)], context: context)
    XCTAssertEqual(jsonObject(removeCommandShape.data)?["success"], .bool(true))
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "stop", queueId], context: context).exitCode, 0)
    queue = try XCTUnwrap(ClaudeCodeQueuePersistence.findQueue(queueId, configDir: config.path))
    XCTAssertTrue(queue.paused)
    XCTAssertEqual(queue.status, .stopped)
    XCTAssertEqual(queue.prompts.map(\.prompt), ["edited"])
    XCTAssertEqual(queue.prompts.map(\.status), [.skipped])
    XCTAssertFalse(ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.resume", variables: ["id": .string(queueId)], context: context).errors.isEmpty)
    XCTAssertEqual(jsonArray(ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.list", variables: ["status": .string("stopped")], context: context).data)?.map { jsonObject($0)?["id"] }, [.string(queueId)])
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "create", "slug", "--project", "/tmp/named-project", "--name", "Human Name"], context: context).exitCode, 0)
    XCTAssertEqual(try ClaudeCodeQueuePersistence.listQueues(configDir: config.path).first { $0.projectPath == "/tmp/named-project" }?.name, "Human Name")

    let bookmark = ClaudeCodeGraphQLCommandExecutor.execute(
      command: "bookmark.add",
      variables: ["type": .string("session"), "sessionId": .string("session-a"), "name": .string("Needle"), "description": .string("content text")],
      context: context
    )
    let bookmarkId = try XCTUnwrap(jsonString(jsonObject(bookmark.data)?["id"]))
    let inferredSessionBookmark = ClaudeCodeGraphQLCommandExecutor.execute(command: "bookmark.add", variables: ["sessionId": .string("session-a"), "name": .string("Session inferred")], context: context)
    XCTAssertEqual(jsonObject(inferredSessionBookmark.data)?["type"], .string("session"))
    let inferredMessageBookmark = ClaudeCodeGraphQLCommandExecutor.execute(command: "bookmark.add", variables: ["sessionId": .string("session-a"), "messageId": .string("message-a"), "name": .string("Message inferred")], context: context)
    XCTAssertEqual(jsonObject(inferredMessageBookmark.data)?["type"], .string("message"))
    let inferredRangeBookmark = ClaudeCodeGraphQLCommandExecutor.execute(command: "bookmark.add", variables: ["sessionId": .string("session-a"), "fromMessageId": .string("m1"), "toMessageId": .string("m2"), "name": .string("Range inferred")], context: context)
    XCTAssertEqual(jsonObject(inferredRangeBookmark.data)?["type"], .string("range"))
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["bookmark", "add", "--session", "session-a", "--name", "Tagged", "--tags", "a,b"], context: context).exitCode, 0)
    XCTAssertEqual(jsonArray(ClaudeCodeGraphQLCommandExecutor.execute(command: "bookmark.list", variables: ["tag": .string("b")], context: context).data)?.count, 1)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["bookmark", "show", bookmarkId], context: context).exitCode, 0)
    XCTAssertEqual(jsonArray(ClaudeCodeGraphQLCommandExecutor.execute(command: "bookmark.search", variables: ["q": .string("Needle")], context: context).data)?.count, 1)
    XCTAssertEqual(jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "bookmark.content", variables: ["id": .string(bookmarkId)], context: context).data)?["content"], .string("content text"))
    let bookmarkDeleteShape = ClaudeCodeGraphQLCommandExecutor.execute(command: "bookmark.delete", variables: ["id": .string(bookmarkId)], context: context)
    XCTAssertEqual(jsonObject(bookmarkDeleteShape.data)?["deleted"], .bool(true))
    let queueDeleteShape = ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.delete", variables: ["id": .string(queueId)], context: context)
    XCTAssertEqual(jsonObject(queueDeleteShape.data)?["deleted"], .bool(true))
  }

  func testLegacyQueueFileBackedRepositoryCompatibility() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let legacyDir = ClaudeCodeQueuePersistence.legacyDirectory(configDir: config.path)
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    try """
    {
      "id": "legacy-q",
      "name": "Legacy Queue",
      "projectPath": "/tmp/legacy-project",
      "status": "pending",
      "commands": [
        {
          "id": "cmd-1",
          "prompt": "legacy prompt",
          "sessionMode": "new",
          "status": "pending"
        }
      ],
      "currentIndex": 0,
      "totalCostUsd": 0,
      "createdAt": "2026-06-17T00:00:00Z",
      "updatedAt": "2026-06-17T00:00:00Z"
    }
    """.write(to: legacyDir.appendingPathComponent("legacy-q.json"), atomically: true, encoding: .utf8)

    var queue = try XCTUnwrap(ClaudeCodeQueuePersistence.findQueue("legacy-q", configDir: config.path))
    XCTAssertEqual(queue.projectPath, "/tmp/legacy-project")
    XCTAssertEqual(queue.prompts.map(\.prompt), ["legacy prompt"])
    XCTAssertEqual(queue.prompts.first?.mode, .new)

    let context = ClaudeCodeAgentCompatibilityContext(configDir: config.path)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "edit", "legacy-q", "0", "--prompt", "edited legacy"], context: context).exitCode, 0)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "toggle-mode", "legacy-q", "0"], context: context).exitCode, 0)
    queue = try XCTUnwrap(ClaudeCodeQueuePersistence.findQueue("legacy-q", configDir: config.path))
    XCTAssertEqual(queue.prompts.first?.prompt, "edited legacy")
    XCTAssertEqual(queue.prompts.first?.mode, .continueMode)

    let savedLegacy = try String(contentsOf: ClaudeCodeQueuePersistence.legacyURL(queueId: "legacy-q", configDir: config.path), encoding: .utf8)
    XCTAssertTrue(savedLegacy.contains(#""commands""#))
    XCTAssertTrue(savedLegacy.contains(#""sessionMode" : "continue""#))

    try """
    {
      "id": "running-q",
      "name": "Running Queue",
      "projectPath": "/tmp/legacy-project",
      "status": "running",
      "commands": [
        {
          "id": "cmd-running",
          "prompt": "busy",
          "sessionMode": "continue",
          "status": "running"
        }
      ],
      "currentIndex": 0,
      "currentSessionId": "session-running",
      "totalCostUsd": 0,
      "createdAt": "2026-06-17T00:00:00Z",
      "updatedAt": "2026-06-17T00:00:00Z"
    }
    """.write(to: legacyDir.appendingPathComponent("running-q.json"), atomically: true, encoding: .utf8)
    XCTAssertNotEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "edit", "running-q", "0", "--prompt", "should not edit"], context: context).exitCode, 0)
    let runningQueue = try XCTUnwrap(ClaudeCodeQueuePersistence.findQueue("running-q", configDir: config.path))
    XCTAssertEqual(runningQueue.status, .running)
    XCTAssertEqual(runningQueue.prompts.first?.prompt, "busy")
  }

  func testQueueRunResumesContinueCommandsAndSkipsAfterFailure() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let script = config.appendingPathComponent("fake-claude.sh")
    let argsLog = config.appendingPathComponent("args.log")
    let scriptText = """
#!/bin/sh
printf '%s\\n' "$*" >> "\(argsLog.path)"
printf '%s\\n' '{"timestamp":"2026-06-17T00:00:00Z","type":"session_meta","payload":{"meta":{"id":"session-legacy"}}}'
case " $* " in
  *" fail command "*) exit 7 ;;
  *) exit 0 ;;
esac
"""
    try scriptText.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let context = ClaudeCodeAgentCompatibilityContext(configDir: config.path)
    let queueId = try XCTUnwrap(jsonString(jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("run"), "projectPath": .string(config.path)], context: context).data)?["id"]))
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "add", queueId, "prompt=first", "--session-mode", "new"], context: context).exitCode, 0)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "add", queueId, "prompt=second", "--session-mode", "continue"], context: context).exitCode, 0)
    let run = ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.run", variables: ["id": .string(queueId), "executableName": .string(script.path)], context: context)
    XCTAssertEqual(run.errors, [])
    var queue = try XCTUnwrap(ClaudeCodeQueuePersistence.findQueue(queueId, configDir: config.path))
    XCTAssertEqual(queue.status, .completed)
    XCTAssertEqual(queue.currentSessionId, "session-legacy")
    XCTAssertEqual(queue.prompts.map(\.sessionId), ["session-legacy", "session-legacy"])
    let args = try String(contentsOf: argsLog, encoding: .utf8)
    XCTAssertTrue(args.contains("--resume session-legacy"))

    let failingQueueId = try XCTUnwrap(jsonString(jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("fail"), "projectPath": .string(config.path)], context: context).data)?["id"]))
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "add", failingQueueId, "prompt=fail command"], context: context).exitCode, 0)
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["queue", "command", "add", failingQueueId, "prompt=never"], context: context).exitCode, 0)
    let failedRun = ClaudeCodeGraphQLCommandExecutor.execute(command: "queue.run", variables: ["id": .string(failingQueueId), "executableName": .string(script.path)], context: context)
    XCTAssertEqual(failedRun.errors, [])
    queue = try XCTUnwrap(ClaudeCodeQueuePersistence.findQueue(failingQueueId, configDir: config.path))
    XCTAssertEqual(queue.status, .failed)
    XCTAssertEqual(queue.prompts.map(\.status), [.failed, .skipped])
  }

  func testDefaultActivityStoreUsesLegacyXDGDataHomeAndObjectShape() throws {
    let xdg = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: xdg) }
    let priorXDG = getenv("XDG_DATA_HOME").map { String(cString: $0) }
    setenv("XDG_DATA_HOME", xdg.path, 1)
    defer {
      if let priorXDG {
        setenv("XDG_DATA_HOME", priorXDG, 1)
      } else {
        unsetenv("XDG_DATA_HOME")
      }
    }

    let dataDir = xdg.appendingPathComponent("claude-code-agent", isDirectory: true)
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    try """
    {
      "sessions": {
        "legacy-activity": {
          "status": "working",
          "projectPath": "/tmp/project",
          "lastUpdated": "2026-06-17T00:00:00Z"
        }
      }
    }
    """.write(to: dataDir.appendingPathComponent("activity.json"), atomically: true, encoding: .utf8)

    let listed = ClaudeCodeGraphQLCommandExecutor.execute(command: "activity.list")
    XCTAssertEqual(jsonArray(jsonObject(listed.data)?["entries"])?.count, 1)
    let entry = ClaudeCodeGraphQLCommandExecutor.execute(command: "activity.get", variables: ["sessionId": .string("legacy-activity")])
    XCTAssertEqual(jsonObject(entry.data)?["status"], .string("working"))
    let updated = ClaudeCodeAgentCLIApplication.run(arguments: ["activity", "update", "new-activity", "--status", "idle", "--updated-at", "2026-06-17T01:00:00Z", "--project", "/tmp/new-project"])
    XCTAssertEqual(updated.exitCode, 0)
    let updatedActivity = jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "activity.get", variables: ["sessionId": .string("new-activity")]).data)
    XCTAssertEqual(updatedActivity?["status"], .string("idle"))
    XCTAssertEqual(updatedActivity?["projectPath"], .string("/tmp/new-project"))
    XCTAssertEqual(updatedActivity?["lastUpdated"], .string("2026-06-17T01:00:00Z"))
    let cleaned = ClaudeCodeAgentCLIApplication.run(arguments: ["activity", "cleanup", "--older-than", "2026-06-17T00:30:00Z"])
    XCTAssertEqual(cleaned.exitCode, 0)
    XCTAssertEqual(jsonArray(jsonObject(ClaudeCodeGraphQLCommandExecutor.execute(command: "activity.list").data)?["entries"])?.map { jsonObject($0)?["sessionId"] }, [.string("new-activity")])
    let activityFile = try String(contentsOf: dataDir.appendingPathComponent("activity.json"), encoding: .utf8)
    XCTAssertTrue(activityFile.contains(#""version" : "1.0""#))
    XCTAssertTrue(activityFile.contains(#""sessions" : {"#))
  }

  func testActivityHookUpdateAndSetupMatchLegacyBehavior() throws {
    let dataDir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dataDir) }
    let transcript = dataDir.appendingPathComponent("transcript.jsonl")
    try #"{"name":"AskUserQuestion"}"#.write(to: transcript, atomically: true, encoding: .utf8)

    let hookPayload = #"{"session_id":"hook-session","hook_event_name":"Stop","cwd":"/tmp/hook-project","transcript_path":"\#(transcript.path)"}"#
    let hook = ClaudeCodeAgentCLIApplication.runActivityHookUpdate(stdin: Data(hookPayload.utf8), context: ClaudeCodeAgentCompatibilityContext(configDir: dataDir.path))
    XCTAssertEqual(hook.exitCode, 0)
    XCTAssertEqual(hook.stdout, "")
    XCTAssertEqual(hook.stderr, "")
    let hookEntry = try XCTUnwrap(try ClaudeCodeActivityStore(dataDir: dataDir.path).load().first { $0.sessionId == "hook-session" })
    XCTAssertEqual(hookEntry.status, .waitingUserResponse)
    XCTAssertEqual(hookEntry.projectPath, "/tmp/hook-project")
    XCTAssertEqual(ClaudeCodeAgentCLIApplication.runActivityHookUpdate(stdin: Data("not json".utf8), context: ClaudeCodeAgentCompatibilityContext(configDir: dataDir.path)).exitCode, 0)

    let project = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let claudeDir = project.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep"}]}]},"env":{"KEEP":"1"}}"#.write(to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let setup = ClaudeCodeAgentCLIApplication.run(arguments: ["activity", "setup", "cwd=\(project.path)"])
    XCTAssertEqual(setup.exitCode, 0)
    let settingsText = try String(contentsOf: claudeDir.appendingPathComponent("settings.json"), encoding: .utf8)
    XCTAssertTrue(settingsText.contains("echo keep"))
    XCTAssertTrue(settingsText.contains("claude-code-agent activity update"))
    XCTAssertTrue(settingsText.contains("UserPromptSubmit"))
    XCTAssertTrue(settingsText.contains("PermissionRequest"))
    XCTAssertTrue(settingsText.contains("Stop"))
    XCTAssertTrue(settingsText.contains(#""KEEP" : "1""#))

    let dryProject = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dryProject) }
    let dryRun = ClaudeCodeAgentCLIApplication.run(arguments: ["activity", "setup", "cwd=\(dryProject.path)", "--dry-run"])
    XCTAssertEqual(dryRun.exitCode, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: dryProject.appendingPathComponent(".claude/settings.json").path))

    let malformedProject = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: malformedProject) }
    let malformedClaudeDir = malformedProject.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: malformedClaudeDir, withIntermediateDirectories: true)
    let malformedSettings = malformedClaudeDir.appendingPathComponent("settings.json")
    try #"["not-an-object"]"#.write(to: malformedSettings, atomically: true, encoding: .utf8)
    let malformedSetup = ClaudeCodeAgentCLIApplication.run(arguments: ["activity", "setup", "cwd=\(malformedProject.path)"])
    XCTAssertEqual(malformedSetup.exitCode, 1)
    XCTAssertTrue(malformedSetup.stderr.contains("settings.json must contain a JSON object"))
    XCTAssertEqual(try String(contentsOf: malformedSettings, encoding: .utf8), #"["not-an-object"]"#)
  }

  func testActivityCleanupSupportsLegacyHoursAndDefaultWindow() throws {
    let dataDir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dataDir) }
    let store = ClaudeCodeActivityStore(dataDir: dataDir.path)
    let formatter = ISO8601DateFormatter()

    try store.save([
      ClaudeCodeStoredActivityEntry(sessionId: "stale-default", status: .idle, updatedAt: formatter.string(from: Date().addingTimeInterval(-48 * 60 * 60))),
      ClaudeCodeStoredActivityEntry(sessionId: "fresh-default", status: .working, updatedAt: formatter.string(from: Date())),
    ])
    let defaultCleanup = ClaudeCodeGraphQLCommandExecutor.execute(command: "activity.cleanup", context: ClaudeCodeAgentCompatibilityContext(configDir: dataDir.path))
    XCTAssertEqual(defaultCleanup.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(defaultCleanup.data)?["entries"])?.map { jsonObject($0)?["sessionId"] }, [.string("fresh-default")])

    try store.save([
      ClaudeCodeStoredActivityEntry(sessionId: "stale-hour", status: .idle, updatedAt: formatter.string(from: Date().addingTimeInterval(-2 * 60 * 60))),
      ClaudeCodeStoredActivityEntry(sessionId: "fresh-hour", status: .working, updatedAt: formatter.string(from: Date())),
    ])
    let hourlyCleanup = ClaudeCodeGraphQLCommandExecutor.execute(command: "activity.cleanup", variables: ["olderThan": .string("1")], context: ClaudeCodeAgentCompatibilityContext(configDir: dataDir.path))
    XCTAssertEqual(hourlyCleanup.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(hourlyCleanup.data)?["entries"])?.map { jsonObject($0)?["sessionId"] }, [.string("fresh-hour")])

    try store.save([
      ClaudeCodeStoredActivityEntry(sessionId: "stale-fractional", status: .idle, updatedAt: "2020-01-01T00:00:00.000Z"),
      ClaudeCodeStoredActivityEntry(sessionId: "fresh-fractional", status: .working, updatedAt: "2999-01-01T00:00:00.000Z"),
    ])
    let fractionalCleanup = ClaudeCodeGraphQLCommandExecutor.execute(command: "activity.cleanup", variables: ["olderThan": .string("2026-01-01T00:00:00.000Z")], context: ClaudeCodeAgentCompatibilityContext(configDir: dataDir.path))
    XCTAssertEqual(fractionalCleanup.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(fractionalCleanup.data)?["entries"])?.map { jsonObject($0)?["sessionId"] }, [.string("fresh-fractional")])
  }

  func testActivityStoreMutationsAreLockProtectedAcrossInstances() throws {
    let dataDir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dataDir) }
    let queue = DispatchQueue(label: "claude-activity-lock-test", attributes: .concurrent)
    let group = DispatchGroup()
    let errors = LockedErrorCounter()

    for index in 0..<20 {
      group.enter()
      queue.async {
        defer { group.leave() }
        do {
          try ClaudeCodeActivityStore(dataDir: dataDir.path).mutate { entries in
            Thread.sleep(forTimeInterval: 0.002)
            entries.append(ClaudeCodeStoredActivityEntry(sessionId: "parallel-\(index)", status: .working, updatedAt: "2026-06-17T00:00:00.000Z"))
          }
        } catch {
          errors.increment()
        }
      }
    }

    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(errors.count(), 0)
    let entries = try ClaudeCodeActivityStore(dataDir: dataDir.path).load()
    XCTAssertEqual(Set(entries.map(\.sessionId)), Set((0..<20).map { "parallel-\($0)" }))
  }

  func testPollingActivityDurationAndClaudeConfigReader() throws {
    XCTAssertEqual(try ClaudeCodeDurationParser.seconds("2h"), 7200)
    XCTAssertThrowsError(try ClaudeCodeDurationParser.seconds("0d"))

    var parser = ClaudeCodeJsonlStreamParser()
    XCTAssertEqual(parser.feed(#"{"type":"user","content":"hel"#), [])
    let parsed = parser.feed(#"lo","uuid":"m1"}"# + "\n")
    XCTAssertEqual(parsed.first?.type, "user")
    XCTAssertEqual(parsed.first?.uuid, "m1")
    XCTAssertEqual(parsed.first?.content, "hello")
    XCTAssertEqual(parsed.first?.raw["content"], "hello")
    XCTAssertEqual(parser.feed(#"not-json"# + "\n"), [])

    var eventParser = ClaudeCodePollingEventParser(now: { Date(timeIntervalSince1970: 10) })
    XCTAssertEqual(eventParser.map(ClaudeCodeTranscriptEvent(type: "tool_use", uuid: "tool-1", raw: ["name": "Bash"]))?.type, .toolStart)
    var endParser = ClaudeCodePollingEventParser(now: { Date(timeIntervalSince1970: 10) })
    _ = endParser.map(ClaudeCodeTranscriptEvent(type: "tool_use", uuid: "tool-1", raw: ["name": "Bash"]))
    XCTAssertEqual(endParser.map(ClaudeCodeTranscriptEvent(type: "tool_result", uuid: "tool-1", content: "done", raw: ["name": "Bash"]))?.type, .toolEnd)

    var nestedParser = ClaudeCodeJsonlStreamParser()
    let nestedToolUse = nestedParser.feed(#"{"type":"tool_use","timestamp":"2026-06-17T00:00:00Z","content":{"name":"Bash"},"uuid":"nested-1"}"# + "\n")
    let nestedToolResult = nestedParser.feed(#"{"type":"tool_result","timestamp":"2026-06-17T00:00:01Z","content":{"name":"Bash"}}"# + "\n")
    var nestedEventParser = ClaudeCodePollingEventParser(now: { Date(timeIntervalSince1970: 0) })
    let start = nestedEventParser.map(try XCTUnwrap(nestedToolUse.first))
    let end = nestedEventParser.map(try XCTUnwrap(nestedToolResult.first))
    XCTAssertEqual(start?.name, "Bash")
    XCTAssertEqual(end?.type, .toolEnd)
    XCTAssertEqual(end?.name, "Bash")
    XCTAssertEqual(end?.durationMs, 1000)

    var states = ClaudeCodePollingStateManager()
    states.apply(sessionId: "s1", event: ClaudeCodeMonitorEvent(type: .message, id: "m1"))
    states.apply(sessionId: "s1", event: ClaudeCodeMonitorEvent(type: .toolStart, id: "tool-1"))
    XCTAssertEqual(states.state(sessionId: "s1")?.messageCount, 1)
    XCTAssertEqual(states.state(sessionId: "s1")?.activeToolIds, ["tool-1"])

    XCTAssertEqual(ClaudeCodeActivityAnalyzer.status(hookEventName: "UserPromptSubmit"), .working)
    XCTAssertEqual(ClaudeCodeActivityAnalyzer.status(hookEventName: "PermissionRequest"), .waitingUserResponse)
    XCTAssertEqual(ClaudeCodeActivityAnalyzer.status(hookEventName: "Stop", transcriptTail: #"{"name":"AskUserQuestion"}"#), .waitingUserResponse)

    let dataDir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dataDir) }
    let store = ClaudeCodeActivityStore(dataDir: dataDir.path)
    try store.save([
      ClaudeCodeStoredActivityEntry(sessionId: "old", status: .idle, updatedAt: "2020-01-01T00:00:00Z"),
      ClaudeCodeStoredActivityEntry(sessionId: "new", status: .working, updatedAt: "2026-06-17T00:00:00Z"),
    ])
    let retained = try store.cleanup(olderThan: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")))
    XCTAssertEqual(retained.map(\.sessionId), ["new"])

    let home = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let config = home.appendingPathComponent(".claude.json")
    try #"{"oauthAccount":{"accountUuid":"acct","emailAddress":"user@example.test","displayName":"User","organizationUuid":"org","organizationName":"Org","organizationBillingType":"pro","organizationRole":"admin"}}"#.write(to: config, atomically: true, encoding: .utf8)
    XCTAssertEqual(try ClaudeCodeConfigReader.account(environment: ["HOME": home.path])?.organizationName, "Org")
  }

  func testCliApplicationExposesClaudeCodeAgentEntryPoint() {
    let result = ClaudeCodeAgentCLIApplication.run(arguments: ["version", "includeGit=false"])
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("version"))
  }
}

private func makeTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("riela-claude-agent-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func writeClaudeRollout(home: URL, sessionId: String, cwd: String = "/tmp/project") throws {
  let day = home.appendingPathComponent("sessions/2026/06/17", isDirectory: true)
  try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
  let rollout = day.appendingPathComponent("rollout-2026-06-17T00-00-00-\(sessionId).jsonl")
  let lines = [
    #"{"timestamp":"2026-06-17T00:00:00.000Z","type":"session_meta","payload":{"meta":{"id":"\#(sessionId)","timestamp":"2026-06-17T00:00:00.000Z","cwd":"\#(cwd)","cli_version":"0.1.0","source":"cli","model_provider":"anthropic"}}}"#,
    #"{"timestamp":"2026-06-17T00:00:01.000Z","type":"event_msg","payload":{"type":"UserMessage","message":"hello"}}"#,
  ]
  try lines.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
}

private func writeClaudeSQLiteState(home: URL, sessionId: String) throws {
  let state = home.appendingPathComponent("state")
  let rollout = home.appendingPathComponent("sqlite-\(sessionId).jsonl")
  try [
    #"{"timestamp":"2026-06-17T00:02:00.000Z","type":"session_meta","payload":{"meta":{"id":"\#(sessionId)","timestamp":"2026-06-17T00:02:00.000Z","cwd":"/tmp/sqlite-project","cli_version":"1.0.0","source":"cli","model_provider":"anthropic"}}}"#,
    #"{"timestamp":"2026-06-17T00:02:01.000Z","type":"event_msg","payload":{"type":"UserMessage","message":"sqlite hello"}}"#,
  ].joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
  let sql = """
  CREATE TABLE threads (
    id TEXT,
    rollout_path TEXT,
    created_at TEXT,
    updated_at TEXT,
    source TEXT,
    model_provider TEXT,
    cwd TEXT,
    cli_version TEXT,
    title TEXT,
    first_user_message TEXT,
    archived_at TEXT,
    git_sha TEXT,
    git_branch TEXT,
    git_origin_url TEXT
  );
  INSERT INTO threads VALUES (
    '\(sessionId)',
    '\(rollout.path)',
    '2026-06-17T00:02:00.000Z',
    '2026-06-17T00:03:00.000Z',
    'cli',
    'anthropic',
    '/tmp/sqlite-project',
    '1.0.0',
    'SQLite session',
    'sqlite hello',
    '',
    '',
    '',
    ''
  );
  """
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
  process.arguments = [state.path, sql]
  process.standardOutput = Pipe()
  process.standardError = Pipe()
  try process.run()
  process.waitUntilExit()
  XCTAssertEqual(process.terminationStatus, 0)
}

private func writeClaudeCredentials(home: URL, expiresAt: Date) throws {
  let expiresMs = Int(expiresAt.timeIntervalSince1970 * 1000)
  try """
  {
    "claudeAiOauth": {
      "accessToken": "access",
      "refreshToken": "refresh",
      "expiresAt": \(expiresMs),
      "scopes": ["user:inference"],
      "subscriptionType": "pro",
      "rateLimitTier": "standard"
    }
  }
  """.write(to: home.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
}

private func writeLegacyClaudeProjectSession(home: URL, projectPath: String, sessionId: String) throws {
  let encodedProjectPath = projectPath.replacingOccurrences(of: "/", with: "-")
  let projectDir = home.appendingPathComponent("projects/\(encodedProjectPath)", isDirectory: true)
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
  let session = projectDir.appendingPathComponent("\(sessionId).jsonl")
  let lines = [
    #"{"type":"summary","timestamp":"2026-06-17T00:00:00.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","version":"1.0.0","summary":"Legacy title"}"#,
    #"{"type":"user","timestamp":"2026-06-17T00:00:01.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","message":{"role":"user","content":"hello legacy"}}"#,
    #"{"type":"assistant","timestamp":"2026-06-17T00:00:02.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","message":{"role":"assistant","content":[{"type":"text","text":"legacy response"}]}}"#,
  ]
  try lines.joined(separator: "\n").write(to: session, atomically: true, encoding: .utf8)
}

private func writeLegacyClaudeProjectSessionWithoutCwd(home: URL, encodedProjectPath: String, sessionId: String) throws {
  let projectDir = home.appendingPathComponent("projects/\(encodedProjectPath)", isDirectory: true)
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
  let session = projectDir.appendingPathComponent("\(sessionId).jsonl")
  let lines = [
    #"{"type":"user","timestamp":"2026-06-17T00:00:01.000Z","sessionId":"\#(sessionId)","message":{"role":"user","content":"relative legacy"}}"#,
  ]
  try lines.joined(separator: "\n").write(to: session, atomically: true, encoding: .utf8)
}

private func jsonObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}

private func jsonArray(_ value: JSONValue?) -> [JSONValue]? {
  guard case let .array(array) = value else {
    return nil
  }
  return array
}

private func jsonString(_ value: JSONValue?) -> String? {
  guard case let .string(string) = value else {
    return nil
  }
  return string
}

private func tokenFileContainsLegacyTimestamp(_ text: String, key: String) -> Bool {
  let pattern = #""\#(key)"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z""#
  return text.range(of: pattern, options: .regularExpression) != nil
}

private final class LockedErrorCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }

  func count() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private extension Array where Element == String {
  func containsSubsequence(_ subsequence: [String]) -> Bool {
    guard !subsequence.isEmpty, count >= subsequence.count else {
      return false
    }
    for index in 0...(count - subsequence.count) where Array(self[index..<(index + subsequence.count)]) == subsequence {
      return true
    }
    return false
  }
}
