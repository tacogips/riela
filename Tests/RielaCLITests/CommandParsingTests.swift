import Foundation
import XCTest
import RielaMemory
@testable import RielaCLI

final class CommandParsingTests: XCTestCase {
  func testParsesTopLevelHelp() throws {
    XCTAssertEqual(try RielaArgumentParser().parse(["--help"]), .help)
    XCTAssertEqual(try RielaArgumentParser().parse(["-h"]), .help)
    XCTAssertEqual(try RielaArgumentParser().parse(["help"]), .help)
  }

  func testParsesTopLevelVersionThroughArgumentParser() throws {
    XCTAssertEqual(try RielaArgumentParser().parse([]), .version)
    XCTAssertEqual(try RielaArgumentParser().parse(["--version"]), .version)
    XCTAssertEqual(try RielaArgumentParser().parse(["version"]), .version)
  }

  func testArgumentParserRegistersEveryTopLevelClientCommand() {
    XCTAssertEqual(
      Set(RielaClientCommandRouter.configuration.subcommands.map { $0._commandName }),
      Set([
        "workflow", "package", "node", "rrun", "setup", "memory", "note", "instance", "doctor", "gc",
        "session", "loop", "graphql", "gql", "hook", "events", "serve", "call-step", "workflow-call", "version"
      ])
    )
  }

  func testArgumentParserRejectsUnknownTopLevelCommand() {
    XCTAssertThrowsError(try RielaArgumentParser().parse(["unknown-command"])) { error in
      XCTAssertTrue((error as? CLIUsageError)?.message.contains("unknown-command") == true)
    }
  }

  func testParsesGarbageCollectionCommand() throws {
    XCTAssertEqual(
      try RielaArgumentParser().parse([
        "gc", "--retention-days", "30", "--scope", "user", "--dry-run", "--output", "json"
      ]),
      .gc(CLICommandOptions(
        scope: "gc",
        command: "gc",
        arguments: ["--retention-days", "30", "--scope", "user", "--dry-run", "--output", "json"],
        output: .json
      ))
    )
  }

  func testParsesPackageHelp() throws {
    XCTAssertEqual(try RielaArgumentParser().parse(["package"]), .packageHelp(.package))
    XCTAssertEqual(try RielaArgumentParser().parse(["package", "--help"]), .packageHelp(.package))
    XCTAssertEqual(try RielaArgumentParser().parse(["package", "-h"]), .packageHelp(.package))
    XCTAssertEqual(try RielaArgumentParser().parse(["package", "help"]), .packageHelp(.package))
    XCTAssertEqual(try RielaArgumentParser().parse(["package", "install", "--help"]), .packageHelp(.package))
    XCTAssertEqual(try RielaArgumentParser().parse(["workflow", "package"]), .packageHelp(.workflowPackage))
    XCTAssertEqual(try RielaArgumentParser().parse(["workflow", "package", "--help"]), .packageHelp(.workflowPackage))
    XCTAssertEqual(try RielaArgumentParser().parse(["workflow", "package", "search", "-h"]), .packageHelp(.workflowPackage))
    XCTAssertEqual(
      try RielaArgumentParser().parse(["package", "init", "demo", "--package-name", "demo-package"]),
      .package(PackageCommand(kind: .initialize, options: CLICommandOptions(
        scope: "package",
        command: "init",
        target: "demo",
        arguments: ["--package-name", "demo-package"],
        output: .text
      )))
    )
    XCTAssertEqual(
      try RielaArgumentParser().parse(["workflow", "package", "pack", "demo"]),
      .workflow(.package(PackageCommand(kind: .pack, options: CLICommandOptions(
        scope: "workflow package",
        command: "pack",
        target: "demo",
        output: .text
      ))))
    )
  }

  func testParsesPackageInstallLockedMode() throws {
    XCTAssertEqual(
      try RielaArgumentParser().parse([
        "package", "install", "--locked",
        "--working-dir", "/tmp/riela-project",
        "--output", "json"
      ]),
      .package(PackageCommand(kind: .install, options: CLICommandOptions(
        scope: "package",
        command: "install",
        arguments: ["--locked", "--working-dir", "/tmp/riela-project", "--output", "json"],
        output: .json
      )))
    )
    XCTAssertEqual(
      try RielaArgumentParser().parse([
        "package", "install", "demo-addon",
        "--locked",
        "--output", "json"
      ]),
      .package(PackageCommand(kind: .install, options: CLICommandOptions(
        scope: "package",
        command: "install",
        target: "demo-addon",
        arguments: ["--locked", "--output", "json"],
        output: .json
      )))
    )
  }

  func testParsesWorkflowRunHelp() throws {
    XCTAssertEqual(
      try RielaArgumentParser().parse(["workflow", "run", "demo", "--help"]),
      .workflow(.runHelp("demo"))
    )
    XCTAssertEqual(
      try RielaArgumentParser().parse(["workflow", "run", "--help"]),
      .workflow(.runHelp(nil))
    )
  }

  func testParsesRrunAsNodeRunAlias() throws {
    XCTAssertEqual(
      try RielaArgumentParser().parse([
        "rrun", "tacogips/pdf-render",
        "--variables", #"{"pdfPath":"/tmp/report.pdf"}"#,
        "--output", "json"
      ]),
      .node(NodeCommand(kind: .run, options: CLICommandOptions(
        scope: "node",
        command: "run",
        target: "tacogips/pdf-render",
        arguments: ["--variables", #"{"pdfPath":"/tmp/report.pdf"}"#, "--output", "json"],
        output: .json
      )))
    )
  }

  func testParsesNodeList() throws {
    XCTAssertEqual(
      try RielaArgumentParser().parse([
        "node", "list",
        "--scope", "project",
        "--output", "table"
      ]),
      .node(NodeCommand(kind: .list, options: CLICommandOptions(
        scope: "node",
        command: "list",
        arguments: ["--scope", "project", "--output", "table"],
        output: .table
      )))
    )
  }

  func testParsesValidateInspectAndRunOptions() throws {
    let parser = RielaArgumentParser()

    let validate = try parser.parse([
      "workflow", "validate", "demo",
      "--workflow-definition-dir", "./examples",
      "--scope", "project",
      "--output", "json",
      "--executable",
      "--node-patch", #"{"worker":{"model":"gpt-5"}}"#
    ])
    XCTAssertEqual(
      validate,
      .workflow(.validate(WorkflowValidateOptions(
        workflowName: "demo",
        resolution: WorkflowResolutionOptions(
          workflowName: "demo",
          scope: .direct,
          workflowDefinitionDir: "./examples",
          workingDirectory: FileManager.default.currentDirectoryPath
        ),
        output: .json,
        executable: true,
        nodePatch: #"{"worker":{"model":"gpt-5"}}"#
      )))
    )

    let inspect = try parser.parse(["workflow", "inspect", "demo", "--structure"])
    if case let .workflow(.inspect(options)) = inspect {
      XCTAssertTrue(options.structure)
      XCTAssertEqual(options.output, .jsonl)
    } else {
      XCTFail("expected inspect command")
    }

    let usage = try parser.parse([
      "workflow", "usage", "demo",
      "--workflow-definition-dir", "./examples",
      "--output", "json"
    ])
    if case let .workflow(.usage(options)) = usage {
      XCTAssertEqual(options.workflowName, "demo")
      XCTAssertEqual(options.resolution.workflowDefinitionDir, "./examples")
      XCTAssertEqual(options.output, .json)
    } else {
      XCTFail("expected usage command")
    }

    let run = try parser.parse([
      "workflow", "run", "demo",
      "--variables", #"{"topic":"swift"}"#,
      "--mock-scenario", "./scenario.json",
      "--max-steps", "2",
      "--agent-silence-warning-ms", "5000",
      "--agent-silence-monitor-interval-ms", "250",
      "--output", "json"
    ])
    if case let .workflow(.run(options)) = run {
      XCTAssertEqual(options.variables, #"{"topic":"swift"}"#)
      XCTAssertEqual(options.mockScenarioPath, "./scenario.json")
      XCTAssertEqual(options.maxSteps, 2)
      XCTAssertEqual(options.agentSilenceWarningMs, 5000)
      XCTAssertEqual(options.agentSilenceMonitorIntervalMs, 250)
      XCTAssertEqual(options.output, .json)
      XCTAssertFalse(options.autoImprove)
    } else {
      XCTFail("expected run command")
    }

    let runWithSilenceWarningsDisabled = try parser.parse([
      "workflow", "run", "demo",
      "--agent-silence-warning-ms", "0"
    ])
    if case let .workflow(.run(options)) = runWithSilenceWarningsDisabled {
      XCTAssertEqual(options.agentSilenceWarningMs, 0)
    } else {
      XCTFail("expected run command")
    }

    let supervisedRun = try parser.parse([
      "workflow", "run", "demo",
      "--auto-improve",
      "--max-supervised-attempts", "4",
      "--max-workflow-patches", "1",
      "--monitor-interval-ms", "1000",
      "--stall-timeout-ms", "2000",
      "--workflow-mutation-mode", "execution-copy",
      "--nested-supervisor"
    ])
    if case let .workflow(.run(options)) = supervisedRun {
      XCTAssertTrue(options.autoImprove)
      XCTAssertEqual(options.autoImprovePolicy.maxSupervisedAttempts, 4)
      XCTAssertEqual(options.autoImprovePolicy.maxWorkflowPatches, 1)
      XCTAssertEqual(options.autoImprovePolicy.monitorIntervalMs, 1000)
      XCTAssertEqual(options.autoImprovePolicy.stallTimeoutMs, 2000)
      XCTAssertTrue(options.autoImprovePolicy.stallDetectionEnabled)
      XCTAssertEqual(options.autoImprovePolicy.workflowMutationMode, .executionCopy)
      XCTAssertTrue(options.autoImprovePolicy.nestedSuperviser)
    } else {
      XCTFail("expected supervised run command")
    }

    let disabledThenConfigured = try parser.parse([
      "workflow", "run", "demo",
      "--no-auto-improve",
      "--max-workflow-patches", "4"
    ])
    if case let .workflow(.run(options)) = disabledThenConfigured {
      XCTAssertFalse(options.autoImprove)
      XCTAssertEqual(options.autoImprovePolicy.maxWorkflowPatches, 4)
    } else {
      XCTFail("expected disabled run command")
    }

    let configuredThenDisabled = try parser.parse([
      "workflow", "run", "demo",
      "--max-workflow-patches", "4",
      "--no-auto-improve"
    ])
    if case let .workflow(.run(options)) = configuredThenDisabled {
      XCTAssertFalse(options.autoImprove)
      XCTAssertEqual(options.autoImprovePolicy.maxWorkflowPatches, 0)
    } else {
      XCTFail("expected disabled run command")
    }
  }

  func testWorkflowRunVariablesFileHasParityWithVariables() throws {
    let parser = RielaArgumentParser()
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-variables-file-parity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inlineJSON = #"{"workflowInput":{"request":"hello"}}"#
    let variablesFileURL = directory.appendingPathComponent("variables.json")
    try inlineJSON.write(to: variablesFileURL, atomically: true, encoding: .utf8)

    let fileRun = try parser.parse([
      "workflow", "run", "demo",
      "--variables-file", variablesFileURL.path
    ])
    guard case let .workflow(.run(fileOptions)) = fileRun else {
      return XCTFail("expected run command")
    }
    // --variables-file always names a file, so it is passed to JSONReferenceLoader
    // with the `@` file-reference prefix.
    XCTAssertEqual(fileOptions.variables, "@" + variablesFileURL.path)

    // Loader parity: the file reference decodes to the same object as inline JSON.
    let loader = JSONReferenceLoader()
    let fromFile = try loader.object(from: try XCTUnwrap(fileOptions.variables))
    let fromInline = try loader.object(from: inlineJSON)
    XCTAssertEqual(fromFile, fromInline)

    // --variables and --variables-file are mutually exclusive.
    XCTAssertThrowsError(try parser.parse([
      "workflow", "run", "demo",
      "--variables", inlineJSON,
      "--variables-file", variablesFileURL.path
    ]))
  }

  func testParsesLoopInspectionCommands() throws {
    let parser = RielaArgumentParser()
    let status = try parser.parse([
      "loop", "status", "session-1",
      "--session-store", "./sessions",
      "--output", "json"
    ])
    XCTAssertEqual(
      status,
      .loop(LoopCommand(
        kind: .status,
        options: CLICommandOptions(
          scope: "loop",
          command: "status",
          target: "session-1",
          arguments: ["--session-store", "./sessions", "--output", "json"],
          output: .json
        )
      ))
    )

    let evidence = try parser.parse(["loop", "evidence", "session-1", "--output=json"])
    XCTAssertEqual(
      evidence,
      .loop(LoopCommand(
        kind: .evidence,
        options: CLICommandOptions(
          scope: "loop",
          command: "evidence",
          target: "session-1",
          arguments: ["--output=json"],
          output: .json
        )
      ))
    )

    let gates = try parser.parse(["loop", "gates", "session-1"])
    XCTAssertEqual(
      gates,
      .loop(LoopCommand(
        kind: .gates,
        options: CLICommandOptions(scope: "loop", command: "gates", target: "session-1")
      ))
    )
  }

  func testParsesLoopRecoverCommand() throws {
    let command = try RielaArgumentParser().parse([
      "loop", "recover", "session-1",
      "--from-step", "step-1",
      "--session-store", "./sessions",
      "--output", "json"
    ])
    XCTAssertEqual(
      command,
      .loop(LoopCommand(
        kind: .recover,
        options: CLICommandOptions(
          scope: "loop",
          command: "recover",
          target: "session-1",
          arguments: ["--from-step", "step-1", "--session-store", "./sessions", "--output", "json"],
          output: .json
        )
      ))
    )
  }

  func testParsesLoopListAndHistoryCommands() throws {
    let parser = RielaArgumentParser()
    let list = try parser.parse([
      "loop", "list",
      "--workflow", "wf",
      "--status", "active",
      "--gate-decision", "needs_work",
      "--limit", "5",
      "--output", "table"
    ])
    XCTAssertEqual(
      list,
      .loop(LoopCommand(
        kind: .list,
        options: CLICommandOptions(
          scope: "loop",
          command: "list",
          arguments: [
            "--workflow", "wf",
            "--status", "active",
            "--gate-decision", "needs_work",
            "--limit", "5",
            "--output", "table"
          ],
          output: .table
        )
      ))
    )

    let history = try parser.parse(["loop", "history", "wf", "--limit", "3", "--output", "json"])
    XCTAssertEqual(
      history,
      .loop(LoopCommand(
        kind: .history,
        options: CLICommandOptions(
          scope: "loop",
          command: "history",
          target: "wf",
          arguments: ["--limit", "3", "--output", "json"],
          output: .json
        )
      ))
    )
  }

  func testParsesLoopRecoverFromGateCommand() throws {
    let command = try RielaArgumentParser().parse([
      "loop", "recover", "session-1",
      "--from-gate", "implementation-review",
      "--session-store", "./sessions",
      "--output", "json"
    ])
    XCTAssertEqual(
      command,
      .loop(LoopCommand(
        kind: .recover,
        options: CLICommandOptions(
          scope: "loop",
          command: "recover",
          target: "session-1",
          arguments: ["--from-gate", "implementation-review", "--session-store", "./sessions", "--output", "json"],
          output: .json
        )
      ))
    )
  }

  func testRejectsInvalidAutoImprovePolicy() {
    XCTAssertThrowsError(try RielaArgumentParser().parse([
      "workflow", "run", "demo",
      "--auto-improve",
      "--monitor-interval-ms", "5000",
      "--stall-timeout-ms", "4999"
    ])) { error in
      XCTAssertEqual(
        (error as? CLIUsageError)?.message,
        "invalid --auto-improve policy: stallTimeoutMs must be greater than or equal to monitorIntervalMs"
      )
    }
  }

  func testParsesRemoteRunOptions() throws {
    let command = try RielaArgumentParser().parse([
      "workflow", "run", "@scope/scoped-flow", "--endpoint", "http://localhost:4000/graphql",
      "--auth-token", "explicit-token",
      "--auth-token-env", "RIELA_REMOTE_TOKEN",
      "--from-registry"
    ])

    if case let .workflow(.run(options)) = command {
      XCTAssertEqual(options.target, "@scope/scoped-flow")
      XCTAssertEqual(options.endpoint, "http://localhost:4000/graphql")
      XCTAssertEqual(options.authToken, "explicit-token")
      XCTAssertEqual(options.authTokenEnv, "RIELA_REMOTE_TOKEN")
      XCTAssertTrue(options.fromRegistry)
      XCTAssertNil(options.maxConcurrency)
    } else {
      XCTFail("expected workflow run command")
    }
  }

  func testParsesMaxConcurrencyOption() throws {
    let command = try RielaArgumentParser().parse([
      "workflow", "run", "demo", "--max-concurrency", "4"
    ])

    if case let .workflow(.run(options)) = command {
      XCTAssertEqual(options.maxConcurrency, 4)
    } else {
      XCTFail("expected workflow run command")
    }
  }

  func testRejectsEndpointAndRegistryFlagsForValidateAndInspect() {
    XCTAssertThrowsError(try RielaArgumentParser().parse([
      "workflow", "validate", "demo", "--endpoint", "http://localhost:4000/graphql"
    ])) { error in
      XCTAssertEqual(
        (error as? CLIUsageError)?.message,
        "remote workflow validate is not supported by the local CLI runner"
      )
    }

    XCTAssertThrowsError(try RielaArgumentParser().parse([
      "workflow", "inspect", "demo", "--from-registry"
    ])) { error in
      XCTAssertEqual(
        (error as? CLIUsageError)?.message,
        "remote workflow inspect is not supported by the local CLI runner"
      )
    }
  }

  func testServeNoteAPIUsesConfiguredNoteRootAndRegistrationRoute() async throws {
    let noteRoot = try scratchRoot(name: "serve-note-api-\(UUID().uuidString)")
      .appendingPathComponent("note", isDirectory: true)
    let result = await RielaCLIApplication().run([
      "serve", "--note-api",
      "--note-root", noteRoot.path,
      "--host", "127.0.0.1",
      "--port", "9876",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let scoped = try decodeJSON(ScopedParityCommandResult.self, from: result.stdout)
    XCTAssertEqual(scoped.status, "ok")
    XCTAssertTrue(scoped.records.contains("status=200"))
    let bodyRecord = try XCTUnwrap(scoped.records.first { $0.hasPrefix("body=") })
    XCTAssertTrue(bodyRecord.contains("http://127.0.0.1:9876"))
    XCTAssertTrue(bodyRecord.contains(noteRoot.path))
    XCTAssertTrue(bodyRecord.contains("registrationURL"))
    XCTAssertTrue(bodyRecord.contains("/note/register?code="))
  }

  func testParsesDeclaredRielaCommandSurfaceForDeletionGate() throws {
    let parser = RielaArgumentParser()

    XCTAssertEqual(
      try parser.parse(["workflow", "list", "--output", "table"]),
      .workflow(.list(CLICommandOptions(
        scope: "workflow",
        command: "list",
        arguments: ["--output", "table"],
        output: .table
      )))
    )
    XCTAssertEqual(
      try parser.parse(["workflow", "status", "demo", "--output=json"]),
      .workflow(.status(CLICommandOptions(
        scope: "workflow",
        command: "status",
        target: "demo",
        arguments: ["--output=json"],
        output: .json
      )))
    )

    if case let .workflow(.manifestValidate(options)) = try parser.parse([
      "workflow", "manifest", "validate", "riela-package.json", "--output", "json"
    ]) {
      XCTAssertEqual(options.manifestPath, "riela-package.json")
      XCTAssertEqual(options.output, .json)
    } else {
      XCTFail("expected workflow manifest validate command")
    }

    XCTAssertEqual(
      try parser.parse(["workflow", "checkout", "codex-design-and-implement-review-loop", "--scope", "project"]),
      .workflow(.checkout(CLICommandOptions(
        scope: "workflow",
        command: "checkout",
        target: "codex-design-and-implement-review-loop",
        arguments: ["--scope", "project"]
      )))
    )

    XCTAssertEqual(
      try parser.parse(["workflow", "package", "registry", "list", "--output", "json"]),
      .workflow(.package(PackageCommand(kind: .registry, options: CLICommandOptions(
        scope: "workflow package",
        command: "registry",
        target: "list",
        arguments: ["--output", "json"],
        output: .json
      ))))
    )
    XCTAssertEqual(
      try parser.parse(["package", "search", "review", "--output", "table"]),
      .package(PackageCommand(kind: .search, options: CLICommandOptions(
        scope: "package",
        command: "search",
        target: "review",
        arguments: ["--output", "table"],
        output: .table
      )))
    )

    XCTAssertEqual(
      try parser.parse(["session", "progress", "session-1", "--output", "json"]),
      .session(.progress(CLICommandOptions(
        scope: "session",
        command: "progress",
        target: "session-1",
        arguments: ["--output", "json"],
        output: .json
      )))
    )
    XCTAssertEqual(
      try parser.parse(["events", "replay", "source-1", "--event-root", "tmp/events"]),
      .scoped(ScopedCommand(kind: .events, options: CLICommandOptions(
        scope: "events",
        command: "replay",
        target: "source-1",
        arguments: ["--event-root", "tmp/events"]
      )))
    )
    XCTAssertEqual(
      try parser.parse([
        "graphql", "execute",
        "--query", "query Notes { notes { value { noteId } } }",
        "--variables", #"{"limit":1}"#,
        "--note-root", "tmp/note",
        "--operation-name", "Notes",
        "--output", "json"
      ]),
      .scoped(ScopedCommand(kind: .graphql, options: CLICommandOptions(
        scope: "graphql",
        command: "execute",
        arguments: [
          "--query", "query Notes { notes { value { noteId } } }",
          "--variables", #"{"limit":1}"#,
          "--note-root", "tmp/note",
          "--operation-name", "Notes",
          "--output", "json"
        ],
        output: .json
      )))
    )
    XCTAssertEqual(
      try parser.parse(["call-step", "workflow-id", "workflow-run-id", "step-id", "--message-json", #"{"ok":true}"#]),
      .scoped(ScopedCommand(kind: .callStep, options: CLICommandOptions(
        scope: "call-step",
        command: "workflow-id",
        target: "workflow-run-id",
        arguments: ["step-id", "--message-json", #"{"ok":true}"#]
      )))
    )
    XCTAssertEqual(
      try parser.parse(["workflow-call", "workflow-id", "workflow-run-id", "step-id"]),
      .scoped(ScopedCommand(kind: .workflowCall, options: CLICommandOptions(
        scope: "workflow-call",
        command: "workflow-id",
        target: "workflow-run-id",
        arguments: ["step-id"]
      )))
    )
  }

  func testRejectsTableOutputWhereTypeScriptRejectsIt() {
    XCTAssertThrowsError(try RielaArgumentParser().parse([
      "workflow", "run", "demo", "--output", "table"
    ])) { error in
      XCTAssertEqual(
        (error as? CLIUsageError)?.message,
        "`--output table` is only supported for workflow list, workflow status, package search, and package list"
      )
    }
  }

  func testParsesMemoryCommandSurface() throws {
    let parser = RielaArgumentParser()

    XCTAssertEqual(
      try parser.parse([
        "memory", "save", "chat-memory",
        "--workflow-id", "telegram-sdk-trio-chat",
        "--node-id", "save-chat-event-memory",
        "--payload-json", #"{"text":"hello"}"#,
        "--registered-at", "2026-06-20T10:00:00Z",
        "--file", "fixtures/yui.png",
        "--memory-root", "tmp/memory",
        "--output", "json"
      ]),
      .memory(MemoryCommand(
        kind: .save,
        options: MemoryCommandOptions(
          memoryId: "chat-memory",
          workflowId: "telegram-sdk-trio-chat",
          nodeId: "save-chat-event-memory",
          payloadJSON: #"{"text":"hello"}"#,
          registeredAt: "2026-06-20T10:00:00Z",
          filePaths: ["fixtures/yui.png"],
          databaseRoot: "tmp/memory",
          output: .json
        )
      ))
    )

    XCTAssertEqual(
      try parser.parse([
        "memory", "update", "daily-summary",
        "--workflow-id", "telegram-sdk-trio-chat",
        "--record-id", "7",
        "--payload-json", #"{"summary":"updated"}"#,
        "--tag", "date:2026-06-22",
        "--output", "json"
      ]),
      .memory(MemoryCommand(
        kind: .update,
        options: MemoryCommandOptions(
          memoryId: "daily-summary",
          workflowId: "telegram-sdk-trio-chat",
          recordId: 7,
          payloadJSON: #"{"summary":"updated"}"#,
          tags: ["date:2026-06-22"],
          output: .json
        )
      ))
    )

    XCTAssertEqual(
      try parser.parse([
        "memory", "update", "chat-memory",
        "--workflow-id", "telegram-sdk-trio-chat",
        "--record-id", "8",
        "--payload-json", #"{"text":"remove files"}"#,
        "--clear-files"
      ]),
      .memory(MemoryCommand(
        kind: .update,
        options: MemoryCommandOptions(
          memoryId: "chat-memory",
          workflowId: "telegram-sdk-trio-chat",
          recordId: 8,
          payloadJSON: #"{"text":"remove files"}"#,
          clearFiles: true
        )
      ))
    )

    XCTAssertEqual(
      try parser.parse([
        "memory", "search", "chat-memory",
        "--workflow-id", "telegram-sdk-trio-chat",
        "--match", "Yui",
        "-e", "Rina",
        "--tag", "chat",
        "--related-id", "12",
        "--limit", "5",
        "--output=json"
      ]),
      .memory(MemoryCommand(
        kind: .search,
        options: MemoryCommandOptions(
          memoryId: "chat-memory",
          workflowId: "telegram-sdk-trio-chat",
          matchPatterns: ["Yui", "Rina"],
          tags: ["chat"],
          relatedRecordIds: [12],
          limit: 5,
          output: .json
        )
      ))
    )

    XCTAssertEqual(
      try parser.parse([
        "memory", "load", "rina-shared",
        "--all-workflows",
        "--node-id", "rina",
        "--limit", "10"
      ]),
      .memory(MemoryCommand(
        kind: .load,
        options: MemoryCommandOptions(
          memoryId: "rina-shared",
          allWorkflows: true,
          nodeId: "rina",
          limit: 10
        )
      ))
    )

    XCTAssertEqual(
      try parser.parse([
        "memory", "tags", "chat-memory",
        "--memory-root", "tmp/memory",
        "--sort", "value-desc",
        "--limit", "10",
        "--offset", "5"
      ]),
      .memory(MemoryCommand(
        kind: .tags,
        options: MemoryCommandOptions(
          memoryId: "chat-memory",
          sortOrder: .valueDesc,
          limit: 10,
          offset: 5,
          databaseRoot: "tmp/memory"
        )
      ))
    )

    XCTAssertEqual(
      try parser.parse(["memory", "metadata", "chat-memory"]),
      .memory(MemoryCommand(kind: .metadata, options: MemoryCommandOptions(memoryId: "chat-memory")))
    )
  }

  func testDefaultOutputIsJSONLForMachineReadableCommands() throws {
    let parser = RielaArgumentParser()

    if case let .workflow(.run(options)) = try parser.parse(["workflow", "run", "demo"]) {
      XCTAssertEqual(options.output, .jsonl)
    } else {
      XCTFail("expected run command")
    }

    if case let .session(.status(options)) = try parser.parse(["session", "status", "session-1"]) {
      XCTAssertEqual(options.output, .jsonl)
    } else {
      XCTFail("expected session status command")
    }

    if case let .workflow(.list(options)) = try parser.parse(["workflow", "list"]) {
      XCTAssertEqual(options.output, .jsonl)
    } else {
      XCTFail("expected workflow list command")
    }
  }

  func testPackageCommandsDefaultToTextForInteractiveUse() throws {
    let parser = RielaArgumentParser()

    if case let .package(command) = try parser.parse(["package", "validate", "demo.rielapkg"]) {
      XCTAssertEqual(command.options.output, .text)
    } else {
      XCTFail("expected package validate command")
    }

    if case let .package(command) = try parser.parse(["package", "validate", "demo.rielapkg", "--output", "json"]) {
      XCTAssertEqual(command.options.output, .json)
    } else {
      XCTFail("expected package validate command")
    }
  }

  private func scratchRoot(name: String) throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(stdout.utf8))
  }
}
