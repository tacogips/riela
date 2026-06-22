import Foundation
import XCTest

final class PersonaMemoryScriptTests: XCTestCase {
  func testMikaFallbackHandsOffToRinaForAutonomousChat() throws {
    let output = try runPersonaMemory(
      personaId: "mika",
      personaName: "Mika Trend",
      envelopeJSON: makeEnvelope()
    )
    let payload = try payload(from: output)

    XCTAssertEqual(payload["handoff_rina"] as? Bool, true)
    XCTAssertEqual(payload["handoff_yui"] as? Bool, false)
    XCTAssertEqual(payload["handoff_mika"] as? Bool, false)
    let replyText = try XCTUnwrap(payload["replyText"] as? String)
    XCTAssertTrue(replyText.contains("@Rina"), replyText)
    XCTAssertFalse(replyText.contains("少し詰まった"), replyText)
  }

  func testRinaHandsBackToYuiBeforeAutonomousLimit() throws {
    let output = try runPersonaMemory(
      personaId: "rina",
      personaName: "Rina Cursor",
      envelopeJSON: makeEnvelope(latestOutputsJSON: #"""
      [
        {
          "payload": {
            "replyAs": "mika",
            "replyText": "その話題いいね。@Rina はどう思う？",
            "autonomousTurns": 2
          }
        },
        {
          "payload": {
            "replyAs": "rina",
            "replyText": "了解。これは少し構造を見たい話題。@Mika の見方も分かる。"
          }
        }
      ]
      """#)
    )
    let payload = try payload(from: output)

    XCTAssertEqual(payload["autonomousTurns"] as? Int, 3)
    XCTAssertEqual(payload["handoff_yui"] as? Bool, true)
    XCTAssertEqual(payload["handoff_mika"] as? Bool, false)
    XCTAssertEqual(payload["handoff_rina"] as? Bool, false)
  }

  func testRinaClosesFinalAutonomousTurnWithoutDanglingMention() throws {
    let output = try runPersonaMemory(
      personaId: "rina",
      personaName: "Rina Cursor",
      envelopeJSON: makeEnvelope(latestOutputsJSON: #"""
      [
        {
          "payload": {
            "replyAs": "mika",
            "replyText": "もう少しだけ続けよ。@Rina はどう？",
            "autonomousTurns": 5
          }
        },
        {
          "payload": {
            "replyAs": "rina",
            "replyText": "雑談モード了解。Discord のスレッド運用は通知設計が重要。@Yui はどう見る？"
          }
        }
      ]
      """#)
    )
    let payload = try payload(from: output)
    let replyText = try XCTUnwrap(payload["replyText"] as? String)

    XCTAssertEqual(payload["autonomousTurns"] as? Int, 6)
    XCTAssertEqual(payload["handoff_yui"] as? Bool, false)
    XCTAssertEqual(payload["handoff_mika"] as? Bool, false)
    XCTAssertEqual(payload["handoff_rina"] as? Bool, false)
    XCTAssertFalse(replyText.contains("@Yui"), replyText)
    XCTAssertTrue(replyText.contains("ここで一度区切る。"), replyText)
  }

  private func runPersonaMemory(
    personaId: String,
    personaName: String,
    envelopeJSON: String
  ) throws -> [String: Any] {
    let root = repositoryRoot()
    let script = root.appendingPathComponent("examples/shared/scripts/persona_memory.py")
    let inputData = Data(envelopeJSON.utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", script.path, "write"]
    process.currentDirectoryURL = root
    var environment = ProcessInfo.processInfo.environment
    environment["RIELA_TRIO_MEMORY_PERSONA_ID"] = personaId
    environment["RIELA_TRIO_MEMORY_PERSONA_NAME"] = personaName
    process.environment = environment

    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error

    try process.run()
    input.fileHandleForWriting.write(inputData)
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = error.fileHandleForReading.readDataToEndOfFile()
    let stderrText = String(data: stderr, encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, stderrText)
    let object = try JSONSerialization.jsonObject(with: stdout)
    return try XCTUnwrap(object as? [String: Any])
  }

  private func makeEnvelope(latestOutputsJSON: String = "[]") -> String {
    let memoryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-persona-memory-tests-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: memoryRoot)
    }
    let request = "Yui、MikaとRinaでしばらく自然に雑談して。"
    return #"""
    {
      "variables": {
        "workflowInput": {
          "request": "\#(request)",
          "memoryRoot": "\#(memoryRoot.path)"
        },
        "humanInput": {
          "request": "\#(request)",
          "conversationId": "test-conversation"
        },
        "event": {
          "conversation": {"id": "test-conversation"},
          "input": {"text": "\#(request)"}
        }
      },
      "input": {
        "request": "\#(request)",
        "latestOutputs": \#(latestOutputsJSON)
      }
    }
    """#
  }

  private func payload(from output: [String: Any]) throws -> [String: Any] {
    try XCTUnwrap(output["payload"] as? [String: Any])
  }

  private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }
}
