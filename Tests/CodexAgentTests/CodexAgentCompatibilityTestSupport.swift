import Foundation
import XCTest
@testable import CodexAgent
@testable import RielaCore

extension String {
  func appendLine(to url: URL) throws {
    try (self + "\n").appendRaw(to: url)
  }

  func appendRaw(to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer {
      try? handle.close()
    }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(utf8))
  }
}

func makeTemporaryDirectory() throws -> URL {
  let repoTmp = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
  ).appendingPathComponent("tmp/riela-codex-agent-tests", isDirectory: true)
  try FileManager.default.createDirectory(at: repoTmp, withIntermediateDirectories: true)
  let url = repoTmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func writeRollout(
  _ url: URL,
  id: String,
  cwd: String,
  source: String,
  branch: String?,
  message: String,
  modifiedAt: String? = nil
) throws {
  try [
    codexSessionMetaLine(id: id, cwd: cwd, source: source, branch: branch),
    codexEventMessageLine(timestamp: "2025-05-07T17:25:00.000Z", type: "UserMessage", message: message)
  ].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  if let modifiedAt {
    try FileManager.default.setAttributes(
      [.modificationDate: try isoDate(modifiedAt)],
      ofItemAtPath: url.path
    )
  }
}

func codexSessionMetaLine(
  id: String,
  timestamp: String = "2025-05-07T17:24:21.123Z",
  cwd: String,
  source: String = "cli",
  branch: String? = nil,
  includeProvenance: Bool = true
) -> String {
  var meta: JSONObject = [
    "id": .string(id),
    "timestamp": .string(timestamp),
    "cwd": .string(cwd),
    "cli_version": .string("0.1.0"),
    "source": .string(source)
  ]
  if includeProvenance {
    meta["originator"] = .string("codex-cli")
    meta["model_provider"] = .string("openai")
  }
  var payload: JSONObject = ["meta": .object(meta)]
  if let branch {
    payload["git"] = .object([
      "sha": .string("abc123"),
      "branch": .string(branch),
      "origin_url": .string("https://example.test/repo.git")
    ])
  }
  return usageLine(timestamp, "session_meta", .object(payload))
}

func codexEventMessageLine(timestamp: String, type: String, message: String) -> String {
  usageLine(timestamp, "event_msg", .object(["type": .string(type), "message": .string(message)]))
}

func runSQLite(_ path: String, _ sql: String) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
  process.arguments = [path, sql]
  process.standardOutput = Pipe()
  process.standardError = Pipe()
  try process.run()
  process.waitUntilExit()
  XCTAssertEqual(process.terminationStatus, 0)
}

@discardableResult
func writeUsageRollout(sessionsDir: URL, relativePath: String, lines: [String]) throws -> URL {
  let url = sessionsDir.appendingPathComponent(relativePath)
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try writeUsageRollout(url: url, lines: lines)
  return url
}

func writeUsageRollout(url: URL, lines: [String]) throws {
  try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

func usageLine(_ timestamp: String, _ type: String, _ payload: JSONValue) -> String {
  let object = JSONValue.object([
    "timestamp": .string(timestamp),
    "type": .string(type),
    "payload": payload
  ])
  guard
    let data = try? JSONEncoder().encode(object),
    let string = String(data: data, encoding: .utf8)
  else {
    XCTFail("expected usage rollout JSON encoding to succeed")
    return ""
  }
  return string
}

func isoDate(_ value: String) throws -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return try XCTUnwrap(formatter.date(from: value))
}

func jsonObject(_ value: JSONValue?) -> JSONObject? {
  if case let .object(object)? = value {
    return object
  }
  return nil
}

func jsonString(_ value: JSONValue?) -> String? {
  if case let .string(string)? = value {
    return string
  }
  return nil
}

func jsonArray(_ value: JSONValue?) -> [JSONValue]? {
  if case let .array(array)? = value {
    return array
  }
  return nil
}

func jsonNumber(_ value: JSONValue?) -> Double? {
  if case let .number(number)? = value {
    return number
  }
  return nil
}

func createExecutable(directory: URL, name: String, body: String) throws -> URL {
  let url = directory.appendingPathComponent(name)
  try "#!/bin/sh\nset -eu\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  return url
}
