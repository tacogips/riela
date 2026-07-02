import XCTest
import RielaMemory
@testable import RielaCLI

final class CommandParsingTests: XCTestCase {
  func testParsesTopLevelHelp() throws {
    XCTAssertEqual(try RielaArgumentParser().parse(["--help"]), .help)
    XCTAssertEqual(try RielaArgumentParser().parse(["-h"]), .help)
  }

  func testParsesPackageHelp() throws {
    XCTAssertEqual(try RielaArgumentParser().parse(["package"]), .packageHelp(.package))
    XCTAssertEqual(try RielaArgumentParser().parse(["package", "--help"]), .packageHelp(.package))
    XCTAssertEqual(try RielaArgumentParser().parse(["package", "-h"]), .packageHelp(.package))
    XCTAssertEqual(try RielaArgumentParser().parse(["package", "help"]), .packageHelp(.package))
    XCTAssertEqual(try RielaArgumentParser().parse(["workflow", "package"]), .packageHelp(.workflowPackage))
    XCTAssertEqual(try RielaArgumentParser().parse(["workflow", "package", "--help"]), .packageHelp(.workflowPackage))
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

  func testRejectsReservedMaxConcurrencyOption() {
    XCTAssertThrowsError(try RielaArgumentParser().parse([
      "workflow", "run", "demo", "--max-concurrency", "4"
    ])) { error in
      XCTAssertEqual(
        (error as? CLIUsageError)?.message,
        "--max-concurrency is reserved for fanout execution and is not supported yet"
      )
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
}
