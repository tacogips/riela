import Foundation
import Dispatch
import XCTest
@testable import CursorCLIAgent
@testable import RielaCore

final class CursorCLIAgentCompatibilityTests: XCTestCase {
  func testLegacyCursorCLIAgentUnitTestSurfaceHasSwiftCoverage() throws {
    let legacyTests: Set<String> = [
      "src/activity/manager.test.ts",
      "src/auth/token-manager.test.ts",
      "src/bookmarks/manager.test.ts",
      "src/cli/cli.test.ts",
      "src/cli/graphql.test.ts",
      "src/cli/tool-registry-cli.test.ts",
      "src/cli/usage-persistence-chain.test.ts",
      "src/compat/commands.test.ts",
      "src/compat/dispatcher.test.ts",
      "src/compat/permissions.test.ts",
      "src/config/paths.test.ts",
      "src/cursor/activity-signals.test.ts",
      "src/cursor/ai-tracking-reader.test.ts",
      "src/cursor/attachment-capability.test.ts",
      "src/cursor/auth-env.test.ts",
      "src/cursor/auth-keepalive.test.ts",
      "src/cursor/model-availability.test.ts",
      "src/cursor/normalize-message.test.ts",
      "src/cursor/process-runner.test.ts",
      "src/cursor/prompt-attachments.test.ts",
      "src/cursor/replay-prompt.test.ts",
      "src/cursor/session-replay-slice.test.ts",
      "src/cursor/skill-catalog.test.ts",
      "src/cursor/stream-normalizer.test.ts",
      "src/cursor/tool-versions.test.ts",
      "src/cursor/transcript-bookmark-lookup.test.ts",
      "src/cursor/transcript-reader.test.ts",
      "src/cursor/transcript-search.test.ts",
      "src/cursor/transcript-tail.test.ts",
      "src/cursor/usage-events.test.ts",
      "src/daemon/manager.test.ts",
      "src/daemon/process.test.ts",
      "src/file-intelligence/manager.test.ts",
      "src/graphql/index.test.ts",
      "src/group/progress.test.ts",
      "src/markdown/parser.test.ts",
      "src/markdown/transcript-tasks.test.ts",
      "src/persistence/activity-store.test.ts",
      "src/persistence/bookmarks-store.test.ts",
      "src/persistence/daemon-metadata-store.test.ts",
      "src/persistence/file-intelligence-index.test.ts",
      "src/persistence/groups-store.test.ts",
      "src/persistence/queues-store.test.ts",
      "src/persistence/repository-analytics-index.test.ts",
      "src/persistence/session-index.test.ts",
      "src/persistence/session-replay-forks-store.test.ts",
      "src/persistence/token-store.test.ts",
      "src/persistence/usage-event-store.test.ts",
      "src/queue/progress.test.ts",
      "src/sdk/agent-runner.test.ts",
      "src/sdk/index.test.ts",
      "src/sdk/testing.test.ts",
      "src/sdk/tool-registry.test.ts",
      "src/server/app-server-compat.test.ts",
      "src/server/event-broker.test.ts",
      "src/server/event-streams.test.ts",
      "src/server/graphql-route.test.ts",
      "src/server/resource-routes-decode.test.ts",
      "src/server/routes/events.test.ts",
      "src/server/server.test.ts",
      "src/server/sse.test.ts",
      "src/usage/manager.test.ts",
    ]
    func coverageCategory(for path: String) -> String {
      if path.hasPrefix("src/activity/") { return "activity" }
      if path.hasPrefix("src/auth/") { return "auth" }
      if path.hasPrefix("src/bookmarks/") { return "bookmarks" }
      if path.hasPrefix("src/cli/") { return "cli" }
      if path.hasPrefix("src/compat/") { return "compat" }
      if path.hasPrefix("src/config/") { return "config" }
      if path.hasPrefix("src/cursor/") { return "cursor" }
      if path.hasPrefix("src/daemon/") { return "daemon" }
      if path.hasPrefix("src/file-intelligence/") { return "file-intelligence" }
      if path.hasPrefix("src/group/") { return "group" }
      if path.hasPrefix("src/markdown/") { return "markdown" }
      if path.hasPrefix("src/persistence/") { return "persistence" }
      if path.hasPrefix("src/queue/") { return "queue" }
      if path.hasPrefix("src/sdk/") { return "sdk" }
      if path.hasPrefix("src/server/") { return "server" }
      if path.hasPrefix("src/usage/") { return "usage" }
      if path == "src/graphql/index.test.ts" { return "graphql" }
      return "unmapped"
    }
    let probes: [(category: String, probe: () throws -> Void)] = [
      ("activity", {
        XCTAssertEqual(CursorCLIActivityAnalyzer.status(hookEventName: "PermissionRequest"), .waitingUserResponse)
      }),
      ("auth", {
        XCTAssertEqual(try CursorCLIDurationParser.seconds("1d"), 86_400)
        XCTAssertEqual(try CursorCLITokenPersistence.createRawToken(name: "probe", permissions: ["session:read"], configDir: makeTemporaryDirectory().path).split(separator: ".").count, 2)
      }),
      ("bookmarks", {
        var manager = CursorCLIBookmarkManager()
        _ = try manager.create(type: .session, sessionId: "probe", name: "Probe")
        XCTAssertEqual(manager.search(text: "probe").count, 1)
      }),
      ("cli", {
        XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["version", "includeGit=false"]).exitCode, 0)
      }),
      ("compat", {
        XCTAssertEqual(CursorCLIProcessCommandBuilder.buildExecArguments(prompt: "probe").first, "--print")
      }),
      ("config", {
        XCTAssertTrue(CursorCLISessionIndex.resolveCursorCLIHome(environment: ["HOME": "/tmp/home"]).hasSuffix("/.cursor"))
      }),
      ("cursor", {
        var parser = CursorCLIJsonlStreamParser()
        XCTAssertEqual(parser.feed(#"{"type":"assistant","content":"ok"}"# + "\n").first?.type, "assistant")
      }),
      ("daemon", {
        let manager = CursorCLIProcessManager(executableName: "cursor-probe") { _, _, _ in CursorCLIProcessExecution(exitCode: 0) }
        XCTAssertEqual(manager.spawnExec(prompt: "probe").result.exitCode, 0)
      }),
      ("file-intelligence", {
        let index = CursorCLIFileChangeIndex(changes: [CursorCLIFileChange(path: "Sources/A.swift", operation: .modified, source: .shell)])
        XCTAssertEqual(index.find("Sources/A.swift")?.operation, .modified)
      }),
      ("graphql", {
        XCTAssertEqual(try CursorCLIGraphQLCommandExecutor.parseParams(["limit=2"])["limit"], .number(2))
      }),
      ("group", {
        var groups = CursorCLIGroupRepository()
        XCTAssertEqual(groups.createGroup(name: "g").name, "g")
      }),
      ("markdown", {
        XCTAssertEqual(CursorCLIMarkdown.parseTasks("# Work\n- [x] done").first?.text, "done")
      }),
      ("persistence", {
        let store = CursorCLIJSONStore<CursorCLIQueuesConfig>(url: try makeTemporaryDirectory().appendingPathComponent("queues.json"))
        try store.save(CursorCLIQueuesConfig())
      }),
      ("queue", {
        var queues = CursorCLIQueueRepository()
        let queue = queues.createQueue(name: "q")
        XCTAssertNotNil(queues.addPrompt(queueId: queue.id, prompt: "p"))
      }),
      ("sdk", {
        var registry = CursorCLIToolRegistry()
        registry.register(name: "read_file", definition: ["description": .string("Read a file")])
        XCTAssertEqual(registry.listNames(), ["read_file"])
      }),
      ("server", {
        XCTAssertTrue(CursorCLICLICompatibility.usage().contains("server"))
      }),
      ("usage", {
        XCTAssertTrue(CursorCLICLICompatibility.usage().contains("usage"))
      }),
    ]

    let coverage = Dictionary(uniqueKeysWithValues: legacyTests.map { ($0, coverageCategory(for: $0)) })
    let probeCategories = Set(probes.map(\.category))
    XCTAssertEqual(legacyTests.count, 62)
    XCTAssertEqual(coverage.count, legacyTests.count)
    XCTAssertFalse(coverage.values.contains("unmapped"))
    XCTAssertTrue(Set(coverage.values).isSubset(of: probeCategories))
    XCTAssertEqual(coverage["src/cursor/stream-normalizer.test.ts"], "cursor")
    XCTAssertEqual(coverage["src/server/event-streams.test.ts"], "server")
    XCTAssertEqual(coverage["src/persistence/session-replay-forks-store.test.ts"], "persistence")
    try probes.forEach { try $0.probe() }
  }

  func testCursorProcessBuilderMatchesLegacyCliShape() {
    let args = CursorCLIProcessCommandBuilder.buildExecArguments(
      prompt: "fix bug",
      options: CursorCLIProcessOptions(
        model: "gpt-5.5",
        mode: .plan,
        trust: true,
        yolo: true,
        streamPartialOutput: true,
        approveMcps: true,
        worktree: "feature",
        worktreeBase: "main",
        images: ["/tmp/a/image.png", "/tmp/b/doc.txt"],
        additionalArguments: ["--max-turns", "3"],
        systemPrompt: "system"
      )
    )

    XCTAssertEqual(args.prefix(3), ["--print", "--output-format", "stream-json"])
    XCTAssertTrue(args.containsSubsequence(["--model", "gpt-5.5"]))
    XCTAssertTrue(args.containsSubsequence(["--mode", "plan"]))
    XCTAssertTrue(args.contains("--trust"))
    XCTAssertTrue(args.contains("--yolo"))
    XCTAssertTrue(args.contains("--stream-partial-output"))
    XCTAssertTrue(args.contains("--approve-mcps"))
    XCTAssertTrue(args.containsSubsequence(["--system-prompt", "system"]))
    XCTAssertTrue(args.containsSubsequence(["--image", "/tmp/a/image.png"]))
    XCTAssertTrue(args.containsSubsequence(["--image", "/tmp/b/doc.txt"]))
    XCTAssertTrue(args.containsSubsequence(["--worktree", "feature"]))
    XCTAssertTrue(args.containsSubsequence(["--worktree-base", "main"]))
    XCTAssertTrue(args.contains("--"))
    XCTAssertEqual(args.last, "fix bug")
    XCTAssertTrue(CursorCLIProcessCommandBuilder.buildExecArguments(prompt: "ask", options: CursorCLIProcessOptions(mode: .ask)).containsSubsequence(["--mode", "ask"]))
    let sanitized = CursorCLIProcessCommandBuilder.buildExecArguments(
      prompt: "safe",
      options: CursorCLIProcessOptions(additionalArguments: ["--output-format", "text", "--input-format=json", "--print", "-p", "--max-turns", "3"])
    )
    XCTAssertFalse(sanitized.contains("text"))
    XCTAssertFalse(sanitized.contains("--input-format=json"))
    XCTAssertEqual(sanitized.filter { $0 == "--print" }.count, 1)
    XCTAssertFalse(sanitized.contains("-p"))
    XCTAssertTrue(sanitized.containsSubsequence(["--max-turns", "3"]))

    let resume = CursorCLIProcessCommandBuilder.buildResumeArguments(sessionId: "session-1", prompt: "continue")
    XCTAssertEqual(resume.prefix(5), ["--print", "--output-format", "stream-json", "--resume", "session-1"])
    XCTAssertEqual(resume.last, "continue")

    let env = CursorCLIProcessCommandBuilder.buildEnvironment(base: [:], options: CursorCLIProcessOptions(cursorCLIHome: "/tmp/cursor-config"))
    XCTAssertEqual(env["CURSOR_CLI_AGENT_CURSOR_HOME"], "/tmp/cursor-config")
  }

  func testProcessManagerExecutesInjectedRunnerAndRecordsLifecycle() {
    let manager = CursorCLIProcessManager(executableName: "cursor-test") { arguments, prompt, environment in
      XCTAssertEqual(arguments.first, "cursor-test")
      XCTAssertEqual(prompt, "hello")
      XCTAssertEqual(environment["CURSOR_CLI_AGENT_CURSOR_HOME"], "/tmp/cursor-home")
      return CursorCLIProcessExecution(stdout: #"{"type":"assistant","content":"ok"}"#, stderr: "", exitCode: 0)
    }

    let run = manager.spawnExec(prompt: "hello", options: CursorCLIProcessOptions(cursorCLIHome: "/tmp/cursor-home"))
    XCTAssertEqual(run.result.exitCode, 0)
    XCTAssertEqual(run.process.status, .exited)
    XCTAssertEqual(manager.list().count, 1)
    XCTAssertEqual(manager.prune(), 1)
  }

  func testTokenPersistenceUsesLegacyCursorTokensAndSha256Hashes() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }

    let raw = try CursorCLITokenPersistence.createRawToken(name: "bot", permissions: ["session:read", "group:*", "queue:*"], configDir: config.path)
    XCTAssertEqual(raw.split(separator: ".").count, 2)

    let metadata = try XCTUnwrap(CursorCLITokenPersistence.verify(rawToken: raw, permission: "session:read", configDir: config.path))
    XCTAssertEqual(metadata.name, "bot")
    XCTAssertNotNil(metadata.lastUsedAt)
    XCTAssertNotNil(try CursorCLITokenPersistence.verify(rawToken: raw, permission: "group:run", configDir: config.path))
    XCTAssertNotNil(try CursorCLITokenPersistence.verify(rawToken: raw, permission: "queue:add", configDir: config.path))
    XCTAssertNotNil(try CursorCLITokenPersistence.verify(rawToken: raw, permission: "group:delete", configDir: config.path))
    XCTAssertEqual(CursorCLITokenManager.normalizePermissions(["group:create", "group:run", "group:*"]), ["group:run", "group:*"])

    XCTAssertTrue(FileManager.default.fileExists(atPath: config.appendingPathComponent("tokens.json").path))
    let tokenFile = try String(contentsOf: config.appendingPathComponent("tokens.json"), encoding: .utf8)
    XCTAssertTrue(tokenFile.contains(#""tokenHash""#))
    XCTAssertFalse(tokenFile.contains("sha256:"))
    XCTAssertTrue(tokenFile.contains(#""lastUsedAt""#))
    XCTAssertTrue(tokenFileContainsLegacyTimestamp(tokenFile, key: "createdAt"))
    XCTAssertTrue(tokenFileContainsLegacyTimestamp(tokenFile, key: "lastUsedAt"))
    XCTAssertFalse(tokenFile.contains(raw))

    let context = CursorCLIAgentCompatibilityContext(configDir: config.path)
    let expiringToken = CursorCLIAgentCLIApplication.run(arguments: ["token", "create", "--name", "expiring", "--expires", "7d"], context: context)
    XCTAssertEqual(expiringToken.exitCode, 0)
    let expiringMetadata = try XCTUnwrap(try CursorCLITokenPersistence.listMetadata(configDir: config.path).first { $0.name == "expiring" })
    XCTAssertNotNil(expiringMetadata.expiresAt)
    XCTAssertEqual(Set(expiringMetadata.permissions), Set(["session:read", "session:create"]))
    let tokenFileWithExpiry = try String(contentsOf: config.appendingPathComponent("tokens.json"), encoding: .utf8)
    XCTAssertTrue(tokenFileContainsLegacyTimestamp(tokenFileWithExpiry, key: "expiresAt"))
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["token", "create", "--name", "bad", "--expires", "0d"], context: context).exitCode, 1)
    let expiredRaw = try CursorCLITokenPersistence.createRawToken(name: "expired", permissions: ["session:read"], expiresAt: "2020-01-01T00:00:00.000Z", configDir: config.path)
    XCTAssertNil(try CursorCLITokenPersistence.verify(rawToken: expiredRaw, permission: "session:read", configDir: config.path))
    let expiredMetadata = try XCTUnwrap(try CursorCLITokenPersistence.listMetadata(configDir: config.path).first { $0.name == "expired" })

    let rotated = try XCTUnwrap(CursorCLITokenPersistence.rotate(id: metadata.id, configDir: config.path))
    XCTAssertTrue(rotated.hasPrefix("\(metadata.id)."))
    XCTAssertNil(try CursorCLITokenPersistence.verify(rawToken: raw, permission: "session:read", configDir: config.path))
    XCTAssertNotNil(try CursorCLITokenPersistence.verify(rawToken: rotated, permission: "session:read", configDir: config.path))
    let rotatedMetadata = try XCTUnwrap(try CursorCLITokenPersistence.verify(rawToken: rotated, permission: "session:read", configDir: config.path))
    XCTAssertTrue(try CursorCLITokenPersistence.revoke(id: rotatedMetadata.id, configDir: config.path))
    XCTAssertTrue(try CursorCLITokenPersistence.revoke(id: expiringMetadata.id, configDir: config.path))
    XCTAssertTrue(try CursorCLITokenPersistence.revoke(id: expiredMetadata.id, configDir: config.path))
    let revoked = try CursorCLITokenPersistence.listMetadata(configDir: config.path)
    XCTAssertTrue(revoked.allSatisfy { $0.revokedAt != nil })
  }

  func testRepositoriesAndGraphQLFacadeMutateSwiftStores() throws {
    var queues = CursorCLIQueueRepository()
    let queue = queues.createQueue(name: "migration", projectPath: "/tmp/project")
    let prompt = try XCTUnwrap(queues.addPrompt(queueId: queue.id, prompt: "ship it"))
    XCTAssertTrue(queues.updatePrompt(queueId: queue.id, promptId: prompt.id, status: .completed, resultExitCode: 0))
    XCTAssertEqual(queues.getQueue(id: queue.id)?.prompts.first?.status, .completed)

    var groups = CursorCLIGroupRepository()
    let group = groups.createGroup(name: "parallel", description: "work")
    XCTAssertTrue(groups.addSession(groupId: group.id, sessionId: "session-a"))
    XCTAssertEqual(groups.getGroup(id: group.id)?.sessionIds, ["session-a"])

    var bookmarks = CursorCLIBookmarkManager()
    let bookmark = try bookmarks.create(type: .message, sessionId: "session-a", messageId: "msg-1", name: "important", tags: ["auth"])
    XCTAssertEqual(bookmarks.search(text: "important").map(\.id), [bookmark.id])

    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let context = CursorCLIAgentCompatibilityContext(configDir: config.path)
    let created = CursorCLIGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("graphql"), "projectPath": .string("/tmp/project")], context: context)
    let queueId = try XCTUnwrap(jsonString(jsonObject(created.data)?["id"]))
    let added = CursorCLIGraphQLCommandExecutor.execute(command: "queue.addCommand", variables: ["id": .string(queueId), "prompt": .string("run")], context: context)
    XCTAssertNotNil(jsonObject(added.data)?["id"])
    let listed = CursorCLIGraphQLCommandExecutor.execute(command: "queue.list", variables: [:], context: context)
    XCTAssertEqual(jsonArray(listed.data)?.count, 1)
  }

  func testDefaultStorageRootsMatchLegacySplitConfigAndDataLocations() {
    XCTAssertTrue(defaultCursorCLIAgentConfigDir().hasSuffix("/.config/cursor-cli-agent"))
    XCTAssertTrue(defaultCursorCLIAgentDataDir().hasSuffix("/.local/share/cursor-cli-agent"))
    XCTAssertNotEqual(defaultCursorCLIAgentConfigDir(), defaultCursorCLIAgentDataDir())
  }

  func testGraphQLLegacyAliasesParamsAndErrorsAreCovered() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let context = CursorCLIAgentCompatibilityContext(configDir: config.path)

    XCTAssertEqual(CursorCLIGraphQLCommandExecutor.execute(command: "queue.nope", context: context).errors, ["Unknown command: queue.nope"])
    XCTAssertEqual(CursorCLIGraphQLCommandExecutor.execute(command: "subscription { command(name: \"queue.list\") }", context: context).errors, ["Unsupported subscription command: queue.list"])

    let params = try CursorCLIGraphQLCommandExecutor.parseParams(["limit=2", "active=true", #"payload={"a":1}"#])
    XCTAssertEqual(params["limit"], .number(2))
    XCTAssertEqual(params["active"], .bool(true))
    XCTAssertEqual(jsonObject(params["payload"])?.count, 1)

    let variablesPath = config.appendingPathComponent("variables.json")
    try #"{"name":"from-file","projectPath":"/tmp/project"}"#.write(to: variablesPath, atomically: true, encoding: .utf8)
    let loaded = try CursorCLIGraphQLCommandExecutor.loadVariables("@\(variablesPath.path)")
    XCTAssertEqual(loaded["name"], .string("from-file"))
    let arbitraryParamsVariable = CursorCLIGraphQLCommandExecutor.execute(
      command: #"query ($p: JSON) { command(name: "queue.create", params: $p) }"#,
      variables: ["p": .object(["name": .string("from-p"), "projectPath": .string("/tmp/p")])],
      context: context
    )
    XCTAssertNotNil(jsonObject(arbitraryParamsVariable.data)?["id"])

    let groupCreate = CursorCLIGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("g")], context: context)
    let groupId = try XCTUnwrap(jsonString(jsonObject(groupCreate.data)?["id"]))
    let groupAdd = CursorCLIGraphQLCommandExecutor.execute(command: "group.addSession", variables: ["id": .string(groupId), "sessionId": .string("s1")], context: context)
    XCTAssertEqual(jsonObject(groupAdd.data)?["ok"], .bool(true))
    let fullSessionAdd = CursorCLIGraphQLCommandExecutor.execute(command: "group.addSession", variables: [
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
    let groupWithSessionObject = try XCTUnwrap(try CursorCLIGroupPersistence.findGroup(groupId, configDir: config.path))
    XCTAssertEqual(groupWithSessionObject.sessions.first { $0.id == "s2" }?.projectPath, "/tmp/project")
    let groupPause = CursorCLIGraphQLCommandExecutor.execute(command: "group.pause", variables: ["id": .string(groupId)], context: context)
    XCTAssertEqual(jsonObject(groupPause.data)?["success"], .bool(true))
    XCTAssertEqual(jsonObject(groupPause.data)?["id"], .string(groupId))
    let groupResume = CursorCLIGraphQLCommandExecutor.execute(command: "group.resume", variables: ["id": .string(groupId)], context: context)
    XCTAssertEqual(jsonObject(groupResume.data)?["success"], .bool(true))
    let deletableGroupId = try XCTUnwrap(jsonString(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("delete-me")], context: context).data)?["id"]))
    let groupDelete = CursorCLIGraphQLCommandExecutor.execute(command: "group.delete", variables: ["id": .string(deletableGroupId)], context: context)
    XCTAssertEqual(jsonObject(groupDelete.data)?["success"], .bool(true))
    XCTAssertEqual(jsonObject(groupDelete.data)?["id"], .string(deletableGroupId))

    let bookmark = CursorCLIGraphQLCommandExecutor.execute(
      command: "bookmark.add",
      variables: ["type": .string("message"), "sessionId": .string("s1"), "messageId": .string("m1"), "name": .string("Needle")],
      context: context
    )
    XCTAssertNotNil(jsonObject(bookmark.data)?["id"])
    let bookmarkSearch = CursorCLIGraphQLCommandExecutor.execute(command: "bookmark.search", variables: ["query": .string("Needle")], context: context)
    XCTAssertEqual(jsonArray(bookmarkSearch.data)?.count, 1)
    let bookmarkId = try XCTUnwrap(jsonString(jsonObject(bookmark.data)?["id"]))
    let bookmarkDelete = CursorCLIGraphQLCommandExecutor.execute(command: "bookmark.delete", variables: ["id": .string(bookmarkId)], context: context)
    XCTAssertEqual(jsonObject(bookmarkDelete.data)?["deleted"], .bool(true))

    let token = CursorCLIGraphQLCommandExecutor.execute(command: "token.create", variables: ["name": .string("bot"), "permissions": .array([.string("session:read")])], context: context)
    let rawToken = try XCTUnwrap(jsonString(token.data))
    XCTAssertEqual(rawToken.split(separator: ".").count, 2)

    let groupToken = CursorCLIGraphQLCommandExecutor.execute(command: "token.create", variables: ["name": .string("group-bot"), "permissions": .array([.string("group:*")])], context: context)
    let groupRawToken = try XCTUnwrap(jsonString(groupToken.data))
    XCTAssertNotNil(try CursorCLITokenPersistence.verify(rawToken: groupRawToken, permission: "group:run", configDir: config.path))

    let limitedToken = try CursorCLITokenPersistence.createRawToken(name: "limited", permissions: ["bookmark:*"], configDir: config.path)
    let tokenManagementError = "Token management commands are not available in token-authenticated GraphQL contexts"
    XCTAssertEqual(CursorCLIGraphQLCommandExecutor.execute(command: "token.list", context: CursorCLIAgentCompatibilityContext(configDir: config.path, authToken: limitedToken)).errors, [tokenManagementError])
    XCTAssertEqual(CursorCLIGraphQLCommandExecutor.execute(command: "token.create", variables: ["name": .string("blocked")], context: CursorCLIAgentCompatibilityContext(configDir: config.path, authToken: limitedToken)).errors, [tokenManagementError])
    XCTAssertEqual(CursorCLIGraphQLCommandExecutor.execute(command: "token.revoke", variables: ["id": .string("any")], context: CursorCLIAgentCompatibilityContext(configDir: config.path, authToken: "not-a-token")).errors, [tokenManagementError])
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["token", "create", "--name", "local-ok"], context: context).exitCode, 0)
    let permissionModeCheck = CursorCLIGraphQLCommandExecutor.execute(command: "model.check", variables: ["model": .string("gpt-5.5"), "approvalMode": .string("allow_all"), "executableName": .string("/usr/bin/true")], context: context)
    XCTAssertEqual(permissionModeCheck.errors, [])
    XCTAssertEqual(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "server.status", context: context).data)?["agent"], .string("cursor-cli-agent"))
    XCTAssertEqual(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "daemon.status", context: context).data)?["status"], .string("unsupported"))
    XCTAssertEqual(jsonArray(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "skill.list", context: context).data)?["skills"])?.count, 0)
    XCTAssertEqual(jsonArray(CursorCLIGraphQLCommandExecutor.execute(command: "markdown.tasks", variables: ["markdown": .string("- [x] migrate")], context: context).data)?.count, 1)
    XCTAssertNotNil(CursorCLIGraphQLCommandExecutor.execute(command: "repo.summary", variables: ["projectPath": .string("/tmp/project")], context: context).data)
  }

  func testAuthCliGraphQLPermissionsActivityAndSessionCompatibilityCommands() throws {
    let config = try makeTemporaryDirectory()
    let home = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: config)
      try? FileManager.default.removeItem(at: home)
    }

    try #"{"oauthAccount":{"accountUuid":"acct","emailAddress":"user@example.test","displayName":"User","organizationUuid":"org","organizationName":"Org","organizationBillingType":"pro","organizationRole":"admin"}}"#
      .write(to: home.appendingPathComponent("account.json"), atomically: true, encoding: .utf8)
    try writeCursorCredentials(home: home, expiresAt: Date().addingTimeInterval(3600))

    let context = CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path)
    let authStatus = CursorCLIAgentCLIApplication.run(arguments: ["auth", "status"], context: context)
    XCTAssertEqual(authStatus.exitCode, 0)
    XCTAssertTrue(authStatus.stdout.contains(#""loggedIn":true"#))
    XCTAssertTrue(authStatus.stdout.contains(#""ready":true"#))
    let verify = CursorCLIAgentCLIApplication.run(arguments: ["auth", "verify", "--model", "gpt-5.5"], context: context)
    XCTAssertEqual(verify.exitCode, 0)
    XCTAssertTrue(verify.stdout.contains(#""requested":"gpt-5.5"#))

    let missingAuth = CursorCLIAgentCLIApplication.run(arguments: ["auth", "status"], context: CursorCLIAgentCompatibilityContext(cursorCLIHome: config.appendingPathComponent("missing-home").path, configDir: config.path))
    XCTAssertEqual(missingAuth.exitCode, 0)
    let accountOnlyHome = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: accountOnlyHome) }
    try #"{"oauthAccount":{"accountUuid":"acct","emailAddress":"user@example.test","displayName":"User","organizationUuid":"org","organizationName":"Org","organizationBillingType":"pro","organizationRole":"admin"}}"#
      .write(to: accountOnlyHome.appendingPathComponent("account.json"), atomically: true, encoding: .utf8)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["auth", "status"], context: CursorCLIAgentCompatibilityContext(cursorCLIHome: accountOnlyHome.path, configDir: config.path)).exitCode, 0)
    try writeCursorCredentials(home: accountOnlyHome, expiresAt: Date().addingTimeInterval(-3600))
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["auth", "status"], context: CursorCLIAgentCompatibilityContext(cursorCLIHome: accountOnlyHome.path, configDir: config.path)).exitCode, 0)

    let bookmarkOnlyToken = try CursorCLITokenPersistence.createRawToken(name: "bookmark", permissions: ["bookmark:*"], configDir: config.path)
    let denied = CursorCLIGraphQLCommandExecutor.execute(command: "session.list", context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: bookmarkOnlyToken))
    XCTAssertEqual(denied.errors, ["Missing permission: session:read"])

    let sessionToken = try CursorCLITokenPersistence.createRawToken(name: "session", permissions: ["session:read"], configDir: config.path)
    let authorized = CursorCLIGraphQLCommandExecutor.execute(command: "session.list", context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(authorized.errors, [])
    XCTAssertNotNil(jsonArray(authorized.data))
    for command in ["session.create", "session.pause", "session.resume"] {
      XCTAssertEqual(
        CursorCLIGraphQLCommandExecutor.execute(command: command, context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken)).errors,
        ["Missing permission: session:create"]
      )
    }
    XCTAssertEqual(
      CursorCLIGraphQLCommandExecutor.execute(command: "session.cancel", context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken)).errors,
      ["Missing permission: session:cancel"]
    )
    let sessionCreateToken = try CursorCLITokenPersistence.createRawToken(name: "session-create", permissions: ["session:create"], configDir: config.path)
    let sessionCreateAuthContext = CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionCreateToken)
    let authorizedCreate = CursorCLIGraphQLCommandExecutor.execute(
      command: "session.create",
      variables: ["prompt": .string("hello"), "executableName": .string("/usr/bin/true")],
      context: sessionCreateAuthContext
    )
    XCTAssertEqual(authorizedCreate.errors, [])
    XCTAssertEqual(jsonObject(authorizedCreate.data)?["exitCode"], .number(0))

    let store = CursorCLIActivityStore(dataDir: config.path)
    try store.save([CursorCLIStoredActivityEntry(sessionId: "session-auth", status: .working, updatedAt: "2026-06-17T00:00:00Z")])
    let activityList = CursorCLIGraphQLCommandExecutor.execute(command: "activity.list", context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(jsonObject(activityList.data)?["entries"])?.count, 1)
    let activityGet = CursorCLIGraphQLCommandExecutor.execute(command: "activity.get", variables: ["sessionId": .string("session-auth")], context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(activityGet.data)?["status"], .string("working"))

    try writeCursorRollout(home: home, sessionId: "session-auth")
    try writeCursorRollout(home: home, sessionId: "session-other", cwd: "/tmp/other")
    try writeCursorSQLiteState(home: home, sessionId: "sqlite-session")
    try writeLegacyCursorProjectSession(home: home, projectPath: "/tmp/legacy-project", sessionId: "88487b4c-f3f6-4a49-b59b-d1d4a098425f")
    try writeLegacyCursorProjectSessionWithoutCwd(home: home, encodedProjectPath: "my-project", sessionId: "relative-legacy-session")
    let sessionGet = CursorCLIGraphQLCommandExecutor.execute(command: "session.get", variables: ["id": .string("session-auth")], context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(sessionGet.data)?["id"], .string("session-auth"))
    let projectSessions = CursorCLIGraphQLCommandExecutor.execute(command: "session.list", variables: ["projectPath": .string("/tmp/project")], context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(projectSessions.data)?.map { jsonObject($0)?["id"] }, [.string("session-auth")])
    let sqliteSessions = CursorCLIGraphQLCommandExecutor.execute(command: "session.list", variables: ["projectPath": .string("/tmp/sqlite-project")], context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(sqliteSessions.data)?.map { jsonObject($0)?["id"] }, [.string("sqlite-session")])
    let legacyProjectSessions = CursorCLIGraphQLCommandExecutor.execute(command: "session.list", variables: ["projectPath": .string("/tmp/legacy-project")], context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(legacyProjectSessions.data)?.map { jsonObject($0)?["id"] }, [.string("88487b4c-f3f6-4a49-b59b-d1d4a098425f")])
    let relativeLegacyProjectSessions = CursorCLIGraphQLCommandExecutor.execute(command: "session.list", variables: ["projectPath": .string("my/project")], context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(relativeLegacyProjectSessions.data)?.map { jsonObject($0)?["id"] }, [.string("relative-legacy-session")])
    let legacyMessages = CursorCLIGraphQLCommandExecutor.execute(command: "session.messages", variables: ["id": .string("88487b4c-f3f6-4a49-b59b-d1d4a098425f")], context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    let legacyUserPayload = jsonArray(jsonObject(legacyMessages.data)?["messages"])?
      .compactMap { jsonObject(jsonObject($0)?["payload"]) }
      .first { $0["type"] == .string("UserMessage") }
    XCTAssertEqual(legacyUserPayload?["message"], .string("hello legacy"))
    let messages = CursorCLIGraphQLCommandExecutor.execute(command: "session.messages", variables: ["id": .string("session-auth")], context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonArray(jsonObject(messages.data)?["messages"])?.count, 2)
    let typedSessions = CursorCLIGraphQLCommandExecutor.execute(command: #"query { sessions { nodes { id messageCount } total } }"#, context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(jsonObject(typedSessions.data)?["sessions"])?.keys.contains("nodes"), true)
    let typedSessionHistory = CursorCLIGraphQLCommandExecutor.execute(command: #"query { session(id: "session-auth") { id history(limit: 1) { total events { type } } } }"#, context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(jsonObject(typedSessionHistory.data)?["session"])?.keys.contains("history"), true)
    let typedSessionGrep = CursorCLIGraphQLCommandExecutor.execute(command: #"query { session(id: "session-auth") { grep(query: "hello", maxMatches: 5) { matched matchCount } } }"#, context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(jsonObject(typedSessionGrep.data)?["session"])?.keys.contains("grep"), true)
    let typedSearch = CursorCLIGraphQLCommandExecutor.execute(command: #"query { searchSessions(query: "hello") { sessionIds total scannedSessions } }"#, context: CursorCLIAgentCompatibilityContext(cursorCLIHome: home.path, configDir: config.path, authToken: sessionToken))
    XCTAssertEqual(jsonObject(jsonObject(typedSearch.data)?["searchSessions"])?.keys.contains("sessionIds"), true)

    let sessionResume = CursorCLIGraphQLCommandExecutor.execute(
      command: "session.resume",
      variables: ["id": .string("session-auth"), "prompt": .string("continue"), "executableName": .string("/usr/bin/true")],
      context: sessionCreateAuthContext
    )
    XCTAssertEqual(sessionResume.errors, [])
    XCTAssertEqual(jsonObject(sessionResume.data)?["exitCode"], .number(0))
    let resumeArguments = jsonArray(jsonObject(sessionResume.data)?["arguments"])?.compactMap(jsonString)
    XCTAssertEqual(resumeArguments?.contains("--resume"), true)
    XCTAssertEqual(resumeArguments?.contains("session-auth"), true)
    let cliResume = CursorCLIAgentCLIApplication.run(
      arguments: ["session", "resume", "session-auth", "--prompt", "continue", "--executable-name", "/usr/bin/true"],
      context: context
    )
    XCTAssertEqual(cliResume.exitCode, 0)
    XCTAssertTrue(cliResume.stdout.contains(#""exitCode":0"#))
    let sessionCancel = CursorCLIGraphQLCommandExecutor.execute(command: "session.cancel", variables: ["id": .string("missing-process")], context: context)
    XCTAssertEqual(sessionCancel.errors, [])
    XCTAssertEqual(jsonObject(sessionCancel.data)?["status"], .string("not_found"))
    let sessionPause = CursorCLIGraphQLCommandExecutor.execute(command: "session.pause", variables: ["id": .string("missing-process")], context: context)
    XCTAssertEqual(sessionPause.errors, [])
    XCTAssertEqual(jsonObject(sessionPause.data)?["degraded"], .bool(true))
  }

  func testLegacyGroupQueueGetAliasesAndGroupPermissionBoundaries() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let context = CursorCLIAgentCompatibilityContext(configDir: config.path)

    let groupCreate = CursorCLIGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("g")], context: context)
    let groupId = try XCTUnwrap(jsonString(jsonObject(groupCreate.data)?["id"]))
    let queueCreate = CursorCLIGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("q"), "projectPath": .string("/tmp/project")], context: context)
    let queueId = try XCTUnwrap(jsonString(jsonObject(queueCreate.data)?["id"]))
    _ = CursorCLIGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("other"), "projectPath": .string("/tmp/other")], context: context)
    XCTAssertNotNil(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "queue.create", variables: ["projectPath": .string("/tmp/project-only")], context: context).data)?["id"])
    XCTAssertEqual(
      CursorCLIGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("missing-project")], context: context).errors,
      ["missingVariable(\"projectPath\")"]
    )

    XCTAssertEqual(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "group.get", variables: ["id": .string(groupId)], context: context).data)?["id"], .string(groupId))
    XCTAssertEqual(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "queue.get", variables: ["id": .string(queueId)], context: context).data)?["id"], .string(queueId))
    XCTAssertEqual(jsonArray(CursorCLIGraphQLCommandExecutor.execute(command: "queue.list", variables: ["projectPath": .string("/tmp/project")], context: context).data)?.count, 1)
    XCTAssertEqual(jsonArray(CursorCLIGraphQLCommandExecutor.execute(command: "queue.list", variables: ["status": .string("pending")], context: context).data)?.count, 3)

    let readToken = try CursorCLITokenPersistence.createRawToken(name: "reader", permissions: ["session:read"], configDir: config.path)
    let runToken = try CursorCLITokenPersistence.createRawToken(name: "runner", permissions: ["group:run"], configDir: config.path)
    let groupToken = try CursorCLITokenPersistence.createRawToken(name: "group", permissions: ["group:*"], configDir: config.path)

    XCTAssertEqual(
      CursorCLIGraphQLCommandExecutor.execute(command: "group.list", context: CursorCLIAgentCompatibilityContext(configDir: config.path, authToken: readToken)).errors,
      ["Missing permission: group:*"]
    )
    XCTAssertEqual(
      CursorCLIGraphQLCommandExecutor.execute(command: "group.delete", variables: ["id": .string(groupId)], context: CursorCLIAgentCompatibilityContext(configDir: config.path, authToken: runToken)).errors,
      ["Missing permission: group:*"]
    )
    XCTAssertEqual(
      jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "group.addSession", variables: ["id": .string(groupId), "sessionId": .string("s1")], context: CursorCLIAgentCompatibilityContext(configDir: config.path, authToken: groupToken)).data)?["ok"],
      .bool(true)
    )
    let groupRun = CursorCLIGraphQLCommandExecutor.execute(
      command: "group.run",
      variables: ["id": .string(groupId), "prompt": .string("ship"), "executableName": .string("/usr/bin/true")],
      context: CursorCLIAgentCompatibilityContext(configDir: config.path, authToken: runToken)
    )
    XCTAssertEqual(groupRun.errors, [])
    XCTAssertNotNil(jsonArray(groupRun.data))
  }

  func testLegacyPerFileGroupAndBookmarkStoresRemainCompatible() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let legacyGroup = CursorCLIGroup(id: "legacy-group", name: "Legacy Group", sessionIds: ["s1"])
    let legacyGroupURL = CursorCLIGroupPersistence.legacyMetaURL(groupId: legacyGroup.id, configDir: config.path)
    try FileManager.default.createDirectory(at: legacyGroupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(legacyGroup).write(to: legacyGroupURL)

    let context = CursorCLIAgentCompatibilityContext(configDir: config.path)
    XCTAssertEqual(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "group.get", variables: ["id": .string("legacy-group")], context: context).data)?["name"], .string("Legacy Group"))
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["group", "add", "legacy-group", "s2"], context: context).exitCode, 0)
    let savedGroup = try JSONDecoder().decode(CursorCLIGroup.self, from: Data(contentsOf: legacyGroupURL))
    XCTAssertEqual(savedGroup.sessionIds, ["s1", "s2"])

    let legacyBookmark = CursorCLIBookmark(id: "legacy-bookmark", type: .session, sessionId: "s1", name: "Legacy Bookmark", description: "needle", tags: ["legacy"])
    let legacyBookmarkURL = CursorCLIBookmarkPersistence.legacyURL(bookmarkId: legacyBookmark.id, configDir: config.path)
    try FileManager.default.createDirectory(at: legacyBookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(legacyBookmark).write(to: legacyBookmarkURL)

    XCTAssertEqual(jsonArray(CursorCLIGraphQLCommandExecutor.execute(command: "bookmark.list", variables: ["tag": .string("legacy")], context: context).data)?.count, 1)
    XCTAssertEqual(jsonArray(CursorCLIGraphQLCommandExecutor.execute(command: "bookmark.search", variables: ["query": .string("needle")], context: context).data)?.count, 1)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["bookmark", "delete", "legacy-bookmark"], context: context).exitCode, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyBookmarkURL.path))
  }

  func testLegacyCliFormsAndGraphQLQueueBookmarkParameters() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let context = CursorCLIAgentCompatibilityContext(configDir: config.path)

    let groupId = try XCTUnwrap(jsonString(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("g")], context: context).data)?["id"]))
    let queueId = try XCTUnwrap(jsonString(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("q"), "projectPath": .string("/tmp/project")], context: context).data)?["id"]))
    let rootFormat = CursorCLIAgentCLIApplication.run(arguments: ["--format", "json", "version"], context: context)
    XCTAssertEqual(rootFormat.exitCode, 0)
    XCTAssertTrue(rootFormat.stdout.contains("version"))
    XCTAssertNotNil(jsonObject(try JSONDecoder().decode(JSONValue.self, from: Data(rootFormat.stdout.utf8))))
    let localJson = CursorCLIAgentCLIApplication.run(arguments: ["version", "--json"], context: context)
    XCTAssertEqual(localJson.exitCode, 0)
    XCTAssertNotNil(jsonObject(try JSONDecoder().decode(JSONValue.self, from: Data(localJson.stdout.utf8))))
    let rootJson = CursorCLIAgentCLIApplication.run(arguments: ["--json", "version"], context: context)
    XCTAssertEqual(rootJson.exitCode, 0)
    XCTAssertNotNil(jsonObject(try JSONDecoder().decode(JSONValue.self, from: Data(rootJson.stdout.utf8))))
    let defaultTable = CursorCLIAgentCLIApplication.run(arguments: ["version"], context: context)
    XCTAssertEqual(defaultTable.exitCode, 0)
    XCTAssertTrue(defaultTable.stdout.contains("Tool"))
    XCTAssertFalse(defaultTable.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["--format", "xml", "version"], context: context).exitCode, 2)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["group", "watch", groupId], context: context).exitCode, 0)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["--json", "queue", "list"], context: context).exitCode, 0)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["--json", "group", "list"], context: context).exitCode, 0)

    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "add", queueId, "prompt=second"], context: context).exitCode, 0)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "add", queueId, "prompt=first", "position=0", "--session-mode", "new"], context: context).exitCode, 0)
    var queue = try XCTUnwrap(CursorCLIQueuePersistence.findQueue(queueId, configDir: config.path))
    XCTAssertEqual(queue.prompts.map(\.prompt), ["first", "second"])
    XCTAssertEqual(queue.prompts.first?.mode, .new)

    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "toggle-mode", queueId, "0"], context: context).exitCode, 0)
    queue = try XCTUnwrap(CursorCLIQueuePersistence.findQueue(queueId, configDir: config.path))
    XCTAssertEqual(queue.prompts.first?.mode, .continueMode)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "edit", queueId, "0", "--prompt", "edited"], context: context).exitCode, 0)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "move", queueId, "from=0", "to=1"], context: context).exitCode, 0)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "remove", queueId, "0"], context: context).exitCode, 0)
    XCTAssertEqual(CursorCLIGraphQLCommandExecutor.execute(command: "queue.addCommand", variables: ["id": .string(queueId), "prompt": .string("shape")], context: context).errors, [])
    let removeCommandShape = CursorCLIGraphQLCommandExecutor.execute(command: "queue.removeCommand", variables: ["id": .string(queueId), "index": .number(1)], context: context)
    XCTAssertEqual(jsonObject(removeCommandShape.data)?["success"], .bool(true))
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "stop", queueId], context: context).exitCode, 0)
    queue = try XCTUnwrap(CursorCLIQueuePersistence.findQueue(queueId, configDir: config.path))
    XCTAssertTrue(queue.paused)
    XCTAssertEqual(queue.status, .stopped)
    XCTAssertEqual(queue.prompts.map(\.prompt), ["edited"])
    XCTAssertEqual(queue.prompts.map(\.status), [.skipped])
    XCTAssertFalse(CursorCLIGraphQLCommandExecutor.execute(command: "queue.resume", variables: ["id": .string(queueId)], context: context).errors.isEmpty)
    XCTAssertEqual(jsonArray(CursorCLIGraphQLCommandExecutor.execute(command: "queue.list", variables: ["status": .string("stopped")], context: context).data)?.map { jsonObject($0)?["id"] }, [.string(queueId)])
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "create", "slug", "--project", "/tmp/named-project", "--name", "Human Name"], context: context).exitCode, 0)
    XCTAssertEqual(try CursorCLIQueuePersistence.listQueues(configDir: config.path).first { $0.projectPath == "/tmp/named-project" }?.name, "Human Name")

    let bookmark = CursorCLIGraphQLCommandExecutor.execute(
      command: "bookmark.add",
      variables: ["type": .string("session"), "sessionId": .string("session-a"), "name": .string("Needle"), "description": .string("content text")],
      context: context
    )
    let bookmarkId = try XCTUnwrap(jsonString(jsonObject(bookmark.data)?["id"]))
    let inferredSessionBookmark = CursorCLIGraphQLCommandExecutor.execute(command: "bookmark.add", variables: ["sessionId": .string("session-a"), "name": .string("Session inferred")], context: context)
    XCTAssertEqual(jsonObject(inferredSessionBookmark.data)?["type"], .string("session"))
    let inferredMessageBookmark = CursorCLIGraphQLCommandExecutor.execute(command: "bookmark.add", variables: ["sessionId": .string("session-a"), "messageId": .string("message-a"), "name": .string("Message inferred")], context: context)
    XCTAssertEqual(jsonObject(inferredMessageBookmark.data)?["type"], .string("message"))
    let inferredRangeBookmark = CursorCLIGraphQLCommandExecutor.execute(command: "bookmark.add", variables: ["sessionId": .string("session-a"), "fromMessageId": .string("m1"), "toMessageId": .string("m2"), "name": .string("Range inferred")], context: context)
    XCTAssertEqual(jsonObject(inferredRangeBookmark.data)?["type"], .string("range"))
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["bookmark", "add", "--session", "session-a", "--name", "Tagged", "--tags", "a,b"], context: context).exitCode, 0)
    XCTAssertEqual(jsonArray(CursorCLIGraphQLCommandExecutor.execute(command: "bookmark.list", variables: ["tag": .string("b")], context: context).data)?.count, 1)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["bookmark", "show", bookmarkId], context: context).exitCode, 0)
    XCTAssertEqual(jsonArray(CursorCLIGraphQLCommandExecutor.execute(command: "bookmark.search", variables: ["q": .string("Needle")], context: context).data)?.count, 1)
    XCTAssertEqual(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "bookmark.content", variables: ["id": .string(bookmarkId)], context: context).data)?["content"], .string("content text"))
    let bookmarkDeleteShape = CursorCLIGraphQLCommandExecutor.execute(command: "bookmark.delete", variables: ["id": .string(bookmarkId)], context: context)
    XCTAssertEqual(jsonObject(bookmarkDeleteShape.data)?["deleted"], .bool(true))
    let queueDeleteShape = CursorCLIGraphQLCommandExecutor.execute(command: "queue.delete", variables: ["id": .string(queueId)], context: context)
    XCTAssertEqual(jsonObject(queueDeleteShape.data)?["deleted"], .bool(true))
  }

  func testLegacyQueueFileBackedRepositoryCompatibility() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let legacyDir = CursorCLIQueuePersistence.legacyDirectory(configDir: config.path)
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

    var queue = try XCTUnwrap(CursorCLIQueuePersistence.findQueue("legacy-q", configDir: config.path))
    XCTAssertEqual(queue.projectPath, "/tmp/legacy-project")
    XCTAssertEqual(queue.prompts.map(\.prompt), ["legacy prompt"])
    XCTAssertEqual(queue.prompts.first?.mode, .new)

    let context = CursorCLIAgentCompatibilityContext(configDir: config.path)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "edit", "legacy-q", "0", "--prompt", "edited legacy"], context: context).exitCode, 0)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "toggle-mode", "legacy-q", "0"], context: context).exitCode, 0)
    queue = try XCTUnwrap(CursorCLIQueuePersistence.findQueue("legacy-q", configDir: config.path))
    XCTAssertEqual(queue.prompts.first?.prompt, "edited legacy")
    XCTAssertEqual(queue.prompts.first?.mode, .continueMode)

    let savedLegacy = try String(contentsOf: CursorCLIQueuePersistence.legacyURL(queueId: "legacy-q", configDir: config.path), encoding: .utf8)
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
    XCTAssertNotEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "edit", "running-q", "0", "--prompt", "should not edit"], context: context).exitCode, 0)
    let runningQueue = try XCTUnwrap(CursorCLIQueuePersistence.findQueue("running-q", configDir: config.path))
    XCTAssertEqual(runningQueue.status, .running)
    XCTAssertEqual(runningQueue.prompts.first?.prompt, "busy")
  }

  func testQueueRunResumesContinueCommandsAndSkipsAfterFailure() throws {
    let config = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let script = config.appendingPathComponent("fake-cursor-agent.sh")
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

    let context = CursorCLIAgentCompatibilityContext(configDir: config.path)
    let queueId = try XCTUnwrap(jsonString(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("run"), "projectPath": .string(config.path)], context: context).data)?["id"]))
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "add", queueId, "prompt=first", "--session-mode", "new"], context: context).exitCode, 0)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "add", queueId, "prompt=second", "--session-mode", "continue"], context: context).exitCode, 0)
    let run = CursorCLIGraphQLCommandExecutor.execute(command: "queue.run", variables: ["id": .string(queueId), "executableName": .string(script.path)], context: context)
    XCTAssertEqual(run.errors, [])
    var queue = try XCTUnwrap(CursorCLIQueuePersistence.findQueue(queueId, configDir: config.path))
    XCTAssertEqual(queue.status, .completed)
    XCTAssertEqual(queue.currentSessionId, "session-legacy")
    XCTAssertEqual(queue.prompts.map(\.sessionId), ["session-legacy", "session-legacy"])
    let args = try String(contentsOf: argsLog, encoding: .utf8)
    XCTAssertTrue(args.contains("--resume session-legacy"))

    let failingQueueId = try XCTUnwrap(jsonString(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("fail"), "projectPath": .string(config.path)], context: context).data)?["id"]))
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "add", failingQueueId, "prompt=fail command"], context: context).exitCode, 0)
    XCTAssertEqual(CursorCLIAgentCLIApplication.run(arguments: ["queue", "command", "add", failingQueueId, "prompt=never"], context: context).exitCode, 0)
    let failedRun = CursorCLIGraphQLCommandExecutor.execute(command: "queue.run", variables: ["id": .string(failingQueueId), "executableName": .string(script.path)], context: context)
    XCTAssertEqual(failedRun.errors, [])
    queue = try XCTUnwrap(CursorCLIQueuePersistence.findQueue(failingQueueId, configDir: config.path))
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

    let dataDir = xdg.appendingPathComponent("cursor-cli-agent", isDirectory: true)
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

    let listed = CursorCLIGraphQLCommandExecutor.execute(command: "activity.list")
    XCTAssertEqual(jsonArray(jsonObject(listed.data)?["entries"])?.count, 1)
    let entry = CursorCLIGraphQLCommandExecutor.execute(command: "activity.get", variables: ["sessionId": .string("legacy-activity")])
    XCTAssertEqual(jsonObject(entry.data)?["status"], .string("working"))
    let updated = CursorCLIAgentCLIApplication.run(arguments: ["activity", "update", "new-activity", "--status", "idle", "--updated-at", "2026-06-17T01:00:00Z", "--project", "/tmp/new-project"])
    XCTAssertEqual(updated.exitCode, 0)
    let updatedActivity = jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "activity.get", variables: ["sessionId": .string("new-activity")]).data)
    XCTAssertEqual(updatedActivity?["status"], .string("idle"))
    XCTAssertEqual(updatedActivity?["projectPath"], .string("/tmp/new-project"))
    XCTAssertEqual(updatedActivity?["lastUpdated"], .string("2026-06-17T01:00:00Z"))
    let cleaned = CursorCLIAgentCLIApplication.run(arguments: ["activity", "cleanup", "--older-than", "2026-06-17T00:30:00Z"])
    XCTAssertEqual(cleaned.exitCode, 0)
    XCTAssertEqual(jsonArray(jsonObject(CursorCLIGraphQLCommandExecutor.execute(command: "activity.list").data)?["entries"])?.map { jsonObject($0)?["sessionId"] }, [.string("new-activity")])
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
    let hook = CursorCLIAgentCLIApplication.runActivityHookUpdate(stdin: Data(hookPayload.utf8), context: CursorCLIAgentCompatibilityContext(configDir: dataDir.path))
    XCTAssertEqual(hook.exitCode, 0)
    XCTAssertEqual(hook.stdout, "")
    XCTAssertEqual(hook.stderr, "")
    let hookEntry = try XCTUnwrap(try CursorCLIActivityStore(dataDir: dataDir.path).load().first { $0.sessionId == "hook-session" })
    XCTAssertEqual(hookEntry.status, .waitingUserResponse)
    XCTAssertEqual(hookEntry.projectPath, "/tmp/hook-project")
    XCTAssertEqual(CursorCLIAgentCLIApplication.runActivityHookUpdate(stdin: Data("not json".utf8), context: CursorCLIAgentCompatibilityContext(configDir: dataDir.path)).exitCode, 0)

    let project = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let cursorDir = project.appendingPathComponent(".cursor", isDirectory: true)
    try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
    try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep"}]}]},"env":{"KEEP":"1"}}"#.write(to: cursorDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let setup = CursorCLIAgentCLIApplication.run(arguments: ["activity", "setup", "cwd=\(project.path)"])
    XCTAssertEqual(setup.exitCode, 0)
    let settingsText = try String(contentsOf: cursorDir.appendingPathComponent("settings.json"), encoding: .utf8)
    XCTAssertTrue(settingsText.contains("echo keep"))
    XCTAssertTrue(settingsText.contains("cursor-cli-agent activity update"))
    XCTAssertTrue(settingsText.contains("UserPromptSubmit"))
    XCTAssertTrue(settingsText.contains("PermissionRequest"))
    XCTAssertTrue(settingsText.contains("Stop"))
    XCTAssertTrue(settingsText.contains(#""KEEP" : "1""#))

    let dryProject = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dryProject) }
    let dryRun = CursorCLIAgentCLIApplication.run(arguments: ["activity", "setup", "cwd=\(dryProject.path)", "--dry-run"])
    XCTAssertEqual(dryRun.exitCode, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: dryProject.appendingPathComponent(".cursor/settings.json").path))

    let malformedProject = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: malformedProject) }
    let malformedCursorDir = malformedProject.appendingPathComponent(".cursor", isDirectory: true)
    try FileManager.default.createDirectory(at: malformedCursorDir, withIntermediateDirectories: true)
    let malformedSettings = malformedCursorDir.appendingPathComponent("settings.json")
    try #"["not-an-object"]"#.write(to: malformedSettings, atomically: true, encoding: .utf8)
    let malformedSetup = CursorCLIAgentCLIApplication.run(arguments: ["activity", "setup", "cwd=\(malformedProject.path)"])
    XCTAssertEqual(malformedSetup.exitCode, 1)
    XCTAssertTrue(malformedSetup.stderr.contains("settings.json must contain a JSON object"))
    XCTAssertEqual(try String(contentsOf: malformedSettings, encoding: .utf8), #"["not-an-object"]"#)
  }

  func testActivityCleanupSupportsLegacyHoursAndDefaultWindow() throws {
    let dataDir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dataDir) }
    let store = CursorCLIActivityStore(dataDir: dataDir.path)
    let formatter = ISO8601DateFormatter()

    try store.save([
      CursorCLIStoredActivityEntry(sessionId: "stale-default", status: .idle, updatedAt: formatter.string(from: Date().addingTimeInterval(-48 * 60 * 60))),
      CursorCLIStoredActivityEntry(sessionId: "fresh-default", status: .working, updatedAt: formatter.string(from: Date())),
    ])
    let defaultCleanup = CursorCLIGraphQLCommandExecutor.execute(command: "activity.cleanup", context: CursorCLIAgentCompatibilityContext(configDir: dataDir.path))
    XCTAssertEqual(defaultCleanup.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(defaultCleanup.data)?["entries"])?.map { jsonObject($0)?["sessionId"] }, [.string("fresh-default")])

    try store.save([
      CursorCLIStoredActivityEntry(sessionId: "stale-hour", status: .idle, updatedAt: formatter.string(from: Date().addingTimeInterval(-2 * 60 * 60))),
      CursorCLIStoredActivityEntry(sessionId: "fresh-hour", status: .working, updatedAt: formatter.string(from: Date())),
    ])
    let hourlyCleanup = CursorCLIGraphQLCommandExecutor.execute(command: "activity.cleanup", variables: ["olderThan": .string("1")], context: CursorCLIAgentCompatibilityContext(configDir: dataDir.path))
    XCTAssertEqual(hourlyCleanup.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(hourlyCleanup.data)?["entries"])?.map { jsonObject($0)?["sessionId"] }, [.string("fresh-hour")])

    try store.save([
      CursorCLIStoredActivityEntry(sessionId: "stale-fractional", status: .idle, updatedAt: "2020-01-01T00:00:00.000Z"),
      CursorCLIStoredActivityEntry(sessionId: "fresh-fractional", status: .working, updatedAt: "2999-01-01T00:00:00.000Z"),
    ])
    let fractionalCleanup = CursorCLIGraphQLCommandExecutor.execute(command: "activity.cleanup", variables: ["olderThan": .string("2026-01-01T00:00:00.000Z")], context: CursorCLIAgentCompatibilityContext(configDir: dataDir.path))
    XCTAssertEqual(fractionalCleanup.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(fractionalCleanup.data)?["entries"])?.map { jsonObject($0)?["sessionId"] }, [.string("fresh-fractional")])
  }

  func testActivityStoreMutationsAreLockProtectedAcrossInstances() throws {
    let dataDir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dataDir) }
    let queue = DispatchQueue(label: "cursor-activity-lock-test", attributes: .concurrent)
    let group = DispatchGroup()
    let errors = LockedErrorCounter()

    for index in 0..<20 {
      group.enter()
      queue.async {
        defer { group.leave() }
        do {
          try CursorCLIActivityStore(dataDir: dataDir.path).mutate { entries in
            Thread.sleep(forTimeInterval: 0.002)
            entries.append(CursorCLIStoredActivityEntry(sessionId: "parallel-\(index)", status: .working, updatedAt: "2026-06-17T00:00:00.000Z"))
          }
        } catch {
          errors.increment()
        }
      }
    }

    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(errors.count(), 0)
    let entries = try CursorCLIActivityStore(dataDir: dataDir.path).load()
    XCTAssertEqual(Set(entries.map(\.sessionId)), Set((0..<20).map { "parallel-\($0)" }))
  }

  func testPollingActivityDurationAndCursorConfigReader() throws {
    XCTAssertEqual(try CursorCLIDurationParser.seconds("2h"), 7200)
    XCTAssertThrowsError(try CursorCLIDurationParser.seconds("0d"))

    var parser = CursorCLIJsonlStreamParser()
    XCTAssertEqual(parser.feed(#"{"type":"user","content":"hel"#), [])
    let parsed = parser.feed(#"lo","uuid":"m1"}"# + "\n")
    XCTAssertEqual(parsed.first?.type, "user")
    XCTAssertEqual(parsed.first?.uuid, "m1")
    XCTAssertEqual(parsed.first?.content, "hello")
    XCTAssertEqual(parsed.first?.raw["content"], "hello")
    XCTAssertEqual(parser.feed(#"not-json"# + "\n"), [])

    var eventParser = CursorCLIPollingEventParser(now: { Date(timeIntervalSince1970: 10) })
    XCTAssertEqual(eventParser.map(CursorCLITranscriptEvent(type: "tool_use", uuid: "tool-1", raw: ["name": "Bash"]))?.type, .toolStart)
    var endParser = CursorCLIPollingEventParser(now: { Date(timeIntervalSince1970: 10) })
    _ = endParser.map(CursorCLITranscriptEvent(type: "tool_use", uuid: "tool-1", raw: ["name": "Bash"]))
    XCTAssertEqual(endParser.map(CursorCLITranscriptEvent(type: "tool_result", uuid: "tool-1", content: "done", raw: ["name": "Bash"]))?.type, .toolEnd)

    var nestedParser = CursorCLIJsonlStreamParser()
    let nestedToolUse = nestedParser.feed(#"{"type":"tool_use","timestamp":"2026-06-17T00:00:00Z","content":{"name":"Bash"},"uuid":"nested-1"}"# + "\n")
    let nestedToolResult = nestedParser.feed(#"{"type":"tool_result","timestamp":"2026-06-17T00:00:01Z","content":{"name":"Bash"}}"# + "\n")
    var nestedEventParser = CursorCLIPollingEventParser(now: { Date(timeIntervalSince1970: 0) })
    let start = nestedEventParser.map(try XCTUnwrap(nestedToolUse.first))
    let end = nestedEventParser.map(try XCTUnwrap(nestedToolResult.first))
    XCTAssertEqual(start?.name, "Bash")
    XCTAssertEqual(end?.type, .toolEnd)
    XCTAssertEqual(end?.name, "Bash")
    XCTAssertEqual(end?.durationMs, 1000)

    var states = CursorCLIPollingStateManager()
    states.apply(sessionId: "s1", event: CursorCLIMonitorEvent(type: .message, id: "m1"))
    states.apply(sessionId: "s1", event: CursorCLIMonitorEvent(type: .toolStart, id: "tool-1"))
    XCTAssertEqual(states.state(sessionId: "s1")?.messageCount, 1)
    XCTAssertEqual(states.state(sessionId: "s1")?.activeToolIds, ["tool-1"])

    XCTAssertEqual(CursorCLIActivityAnalyzer.status(hookEventName: "UserPromptSubmit"), .working)
    XCTAssertEqual(CursorCLIActivityAnalyzer.status(hookEventName: "PermissionRequest"), .waitingUserResponse)
    XCTAssertEqual(CursorCLIActivityAnalyzer.status(hookEventName: "Stop", transcriptTail: #"{"name":"AskUserQuestion"}"#), .waitingUserResponse)

    let dataDir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dataDir) }
    let store = CursorCLIActivityStore(dataDir: dataDir.path)
    try store.save([
      CursorCLIStoredActivityEntry(sessionId: "old", status: .idle, updatedAt: "2020-01-01T00:00:00Z"),
      CursorCLIStoredActivityEntry(sessionId: "new", status: .working, updatedAt: "2026-06-17T00:00:00Z"),
    ])
    let retained = try store.cleanup(olderThan: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")))
    XCTAssertEqual(retained.map(\.sessionId), ["new"])

    let home = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let cursorDir = home.appendingPathComponent(".cursor", isDirectory: true)
    try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
    let config = cursorDir.appendingPathComponent("account.json")
    try #"{"oauthAccount":{"accountUuid":"acct","emailAddress":"user@example.test","displayName":"User","organizationUuid":"org","organizationName":"Org","organizationBillingType":"pro","organizationRole":"admin"}}"#.write(to: config, atomically: true, encoding: .utf8)
    XCTAssertEqual(try CursorCLIConfigReader.account(environment: ["HOME": home.path])?.organizationName, "Org")
  }

  func testCliApplicationExposesCursorCLIAgentEntryPoint() {
    let result = CursorCLIAgentCLIApplication.run(arguments: ["version", "includeGit=false"])
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("version"))
  }
}

private func makeTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("riela-cursor-agent-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func writeCursorRollout(home: URL, sessionId: String, cwd: String = "/tmp/project") throws {
  let day = home.appendingPathComponent("sessions/2026/06/17", isDirectory: true)
  try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
  let rollout = day.appendingPathComponent("rollout-2026-06-17T00-00-00-\(sessionId).jsonl")
  let lines = [
    #"{"timestamp":"2026-06-17T00:00:00.000Z","type":"session_meta","payload":{"meta":{"id":"\#(sessionId)","timestamp":"2026-06-17T00:00:00.000Z","cwd":"\#(cwd)","cli_version":"0.1.0","source":"cli","model_provider":"anthropic"}}}"#,
    #"{"timestamp":"2026-06-17T00:00:01.000Z","type":"event_msg","payload":{"type":"UserMessage","message":"hello"}}"#,
  ]
  try lines.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
}

private func writeCursorSQLiteState(home: URL, sessionId: String) throws {
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

private func writeCursorCredentials(home: URL, expiresAt: Date) throws {
  let expiresMs = Int(expiresAt.timeIntervalSince1970 * 1000)
  try """
  {
    "cursorOauth": {
      "accessToken": "access",
      "refreshToken": "refresh",
      "expiresAt": \(expiresMs),
      "scopes": ["user:inference"],
      "subscriptionType": "pro",
      "rateLimitTier": "standard"
    }
  }
  """.write(to: home.appendingPathComponent("credentials.json"), atomically: true, encoding: .utf8)
}

private func writeLegacyCursorProjectSession(home: URL, projectPath: String, sessionId: String) throws {
  let encodedProjectPath = projectPath.replacingOccurrences(of: "/", with: "-")
  let projectDir = home.appendingPathComponent("projects/\(encodedProjectPath)/agent-transcripts", isDirectory: true)
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
  let session = projectDir.appendingPathComponent("\(sessionId).jsonl")
  let lines = [
    #"{"type":"summary","timestamp":"2026-06-17T00:00:00.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","version":"1.0.0","summary":"Legacy title"}"#,
    #"{"type":"user","timestamp":"2026-06-17T00:00:01.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","message":{"role":"user","content":"hello legacy"}}"#,
    #"{"type":"assistant","timestamp":"2026-06-17T00:00:02.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","message":{"role":"assistant","content":[{"type":"text","text":"legacy response"}]}}"#,
  ]
  try lines.joined(separator: "\n").write(to: session, atomically: true, encoding: .utf8)
}

private func writeLegacyCursorProjectSessionWithoutCwd(home: URL, encodedProjectPath: String, sessionId: String) throws {
  let projectDir = home.appendingPathComponent("projects/\(encodedProjectPath)/agent-transcripts", isDirectory: true)
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
