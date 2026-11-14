import AgentRuntimeKit
import Foundation
import XCTest

final class AgentRuntimeKitTests: XCTestCase {
  func testOutputBuffersParseCompleteAndTrailingLines() {
    let buffers = AgentProcessOutputBuffers<String> { line in
      line.hasPrefix("event:") ? line : nil
    }

    buffers.appendStdout(Data("event:one\nignored\n".utf8))
    buffers.appendStdout(Data("event:two".utf8))
    buffers.finishStdout()

    XCTAssertEqual(buffers.lines(), ["event:one", "event:two"])
    XCTAssertEqual(String(data: buffers.stdout(), encoding: .utf8), "event:one\nignored\nevent:two")
  }

  func testOutputBuffersDoNotCorruptUTF8SplitAcrossChunks() {
    let buffers = AgentProcessOutputBuffers<String> { line in
      line.hasPrefix("event:") ? line : nil
    }
    let line = Data("event:東京\n".utf8)
    let splitInsideFirstCJKScalar = "event:".utf8.count + 1

    buffers.appendStdout(Data(line.prefix(splitInsideFirstCJKScalar)))
    buffers.appendStdout(Data(line.dropFirst(splitInsideFirstCJKScalar)))
    buffers.finishStdout()

    XCTAssertEqual(buffers.lines(), ["event:東京"])
    XCTAssertFalse(buffers.lines().contains { $0.contains("\u{FFFD}") })
  }

  func testJSONLByteSplitterBoundsNewlineLessStreamsAndKeepsInvalidUTF8Visible() {
    var splitter = AgentJSONLByteLineSplitter(maximumPendingBytes: 5)

    XCTAssertEqual(splitter.feed(Data([0xff, 0xfe, 10])), ["\u{FFFD}\u{FFFD}"])
    XCTAssertEqual(splitter.feed(Data("abcdef".utf8)), ["abcdef"])
    XCTAssertEqual(splitter.pendingByteCount, 0)
  }

  func testNextLineWaitsUntilFinished() {
    let buffers = AgentProcessOutputBuffers<String> { line in line }
    var cursor = 0

    XCTAssertNil(buffers.nextLine(after: &cursor, timeout: 0.001))

    buffers.appendStdout(Data("ready\n".utf8))
    XCTAssertEqual(buffers.nextLine(after: &cursor, timeout: 0.001), "ready")

    buffers.finishStdout()
    XCTAssertNil(buffers.nextLine(after: &cursor, timeout: 0.001))
  }

  func testFailedManagedProcessReturnsFailedExecutionAndClosedBuffers() {
    struct Execution: Equatable {
      var stdout: String
      var stderr: String
      var exitCode: Int32
    }
    let buffers = AgentProcessOutputBuffers<String> { line in line }
    let managed = AgentManagedProcess(
      failedExecution: Execution(stdout: "", stderr: "spawn failed", exitCode: 127),
      outputBuffers: buffers
    ) { stdout, stderr, exitCode in
      Execution(
        stdout: decodeAgentProcessOutput(stdout),
        stderr: decodeAgentProcessOutput(stderr),
        exitCode: exitCode
      )
    }
    var cursor = 0

    XCTAssertEqual(managed.execution(), Execution(stdout: "", stderr: "spawn failed", exitCode: 127))
    XCTAssertNil(buffers.nextLine(after: &cursor, timeout: 0.001))
  }

  func testManagedProcessLauncherRunsProcessWithInitialInput() {
    struct Execution: Equatable {
      var stdout: String
      var stderr: String
      var exitCode: Int32
    }
    let buffers = AgentProcessOutputBuffers<String> { line in line }
    let launched = AgentManagedProcessLauncher.launch(
      commandArguments: ["/bin/sh", "-c", "cat; echo done"],
      environment: ProcessInfo.processInfo.environment,
      cwd: nil,
      prompt: "hello",
      closeInputAfterPrompt: true,
      initialInput: "hello\n",
      makeManaged: { process, input, output, error in
        AgentManagedProcess(
          process: process,
          input: input,
          output: output,
          error: error,
          outputBuffers: buffers
        ) { stdout, stderr, exitCode in
          Execution(
            stdout: decodeAgentProcessOutput(stdout),
            stderr: decodeAgentProcessOutput(stderr),
            exitCode: exitCode
          )
        }
      },
      makeFailedManaged: { error in
        AgentManagedProcess(
          failedExecution: Execution(stdout: "", stderr: error.localizedDescription, exitCode: 127),
          outputBuffers: buffers
        ) { stdout, stderr, exitCode in
          Execution(
            stdout: decodeAgentProcessOutput(stdout),
            stderr: decodeAgentProcessOutput(stderr),
            exitCode: exitCode
          )
        }
      }
    )

    XCTAssertNotNil(launched.systemProcess)
    launched.managed.waitUntilExit()
    XCTAssertEqual(launched.record.status, .running)
    XCTAssertEqual(launched.managed.execution(), Execution(stdout: "hello\ndone\n", stderr: "", exitCode: 0))
    XCTAssertEqual(buffers.lines(), ["hello", "done"])
  }

  func testManagedProcessTerminateEscalatesWhenTermIsIgnored() {
    struct Execution: Equatable {
      var stdout: String
      var stderr: String
      var exitCode: Int32
    }
    let buffers = AgentProcessOutputBuffers<String> { line in line }
    let launched = AgentManagedProcessLauncher.launch(
      commandArguments: ["/bin/sh", "-c", "trap '' TERM; echo ready; while true; do sleep 1; done"],
      environment: ProcessInfo.processInfo.environment,
      cwd: nil,
      prompt: "hello",
      closeInputAfterPrompt: true,
      makeManaged: { process, input, output, error in
        AgentManagedProcess(
          process: process,
          input: input,
          output: output,
          error: error,
          outputBuffers: buffers
        ) { stdout, stderr, exitCode in
          Execution(
            stdout: decodeAgentProcessOutput(stdout),
            stderr: decodeAgentProcessOutput(stderr),
            exitCode: exitCode
          )
        }
      },
      makeFailedManaged: { error in
        AgentManagedProcess(
          failedExecution: Execution(stdout: "", stderr: error.localizedDescription, exitCode: 127),
          outputBuffers: buffers
        ) { stdout, stderr, exitCode in
          Execution(
            stdout: decodeAgentProcessOutput(stdout),
            stderr: decodeAgentProcessOutput(stderr),
            exitCode: exitCode
          )
        }
      }
    )
    XCTAssertNotNil(launched.systemProcess)
    var cursor = 0
    XCTAssertEqual(buffers.nextLine(after: &cursor, timeout: 1), "ready")

    launched.managed.terminate()

    XCTAssertTrue(waitForExit(launched.systemProcess, timeout: 3))
    launched.managed.waitUntilExit()
    XCTAssertNotEqual(launched.managed.execution().exitCode, 0)
  }

  func testManagedProcessLauncherReturnsFailedExecutionWhenSpawnFails() {
    struct Execution: Equatable {
      var stdout: String
      var stderr: String
      var exitCode: Int32
    }
    let buffers = AgentProcessOutputBuffers<String> { line in line }
    let missingWorkingDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let launched = AgentManagedProcessLauncher.launch(
      commandArguments: ["/bin/sh", "-c", "echo unreachable"],
      environment: ProcessInfo.processInfo.environment,
      cwd: missingWorkingDirectory.path,
      prompt: "hello",
      closeInputAfterPrompt: true,
      makeManaged: { process, input, output, error in
        AgentManagedProcess(
          process: process,
          input: input,
          output: output,
          error: error,
          outputBuffers: buffers
        ) { stdout, stderr, exitCode in
          Execution(
            stdout: decodeAgentProcessOutput(stdout),
            stderr: decodeAgentProcessOutput(stderr),
            exitCode: exitCode
          )
        }
      },
      makeFailedManaged: { error in
        AgentManagedProcess(
          failedExecution: Execution(stdout: "", stderr: error.localizedDescription, exitCode: 127),
          outputBuffers: buffers
        ) { stdout, stderr, exitCode in
          Execution(
            stdout: decodeAgentProcessOutput(stdout),
            stderr: decodeAgentProcessOutput(stderr),
            exitCode: exitCode
          )
        }
      }
    )

    XCTAssertNil(launched.systemProcess)
    XCTAssertEqual(launched.record.status, .exited)
    XCTAssertEqual(launched.record.exitCode, 127)
    XCTAssertEqual(launched.managed.execution().exitCode, 127)
  }

  private func waitForExit(_ process: Process?, timeout: TimeInterval) -> Bool {
    guard let process else {
      return true
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    return !process.isRunning
  }
}
