import AgentRuntimeKit
import Foundation
import XCTest

final class AgentOperationalSupportTests: XCTestCase {
  func testJSONFileStoreLoadsDefaultAndSavesSortedPrettyJSON() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("nested/config.json")
    let store = AgentJSONFileStore<Config>(url: url)

    XCTAssertEqual(try store.load(default: Config(name: "default", count: 1)), Config(name: "default", count: 1))
    try store.save(Config(name: "saved", count: 2))

    XCTAssertEqual(try store.load(default: Config(name: "default", count: 1)), Config(name: "saved", count: 2))
    let saved = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(saved.contains("\n"))
    XCTAssertLessThan(
      try XCTUnwrap(saved.range(of: "\"count\"")?.lowerBound),
      try XCTUnwrap(saved.range(of: "\"name\"")?.lowerBound)
    )
  }

  private struct Config: Codable, Equatable, Sendable {
    var name: String
    var count: Int
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).appendingPathComponent("tmp/agent-runtime-kit-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
