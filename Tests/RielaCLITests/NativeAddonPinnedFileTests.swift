import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class NativeAddonPinnedFileTests: XCTestCase {
  func testPinnedDescriptorSurvivesPathReplacement() throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-pinned-replacement")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let replacement = root.appendingPathComponent("other")
    try "original".write(to: source, atomically: true, encoding: .utf8)
    try "other".write(to: replacement, atomically: true, encoding: .utf8)
    let pinned = try NativeAddonPinnedFile(path: source.path)
    try FileManager.default.removeItem(at: source)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: replacement)
    XCTAssertEqual(try pinned.text(), "original")
    XCTAssertThrowsError(try NativeAddonPinnedFile(path: source.path))
  }

  func testConfigSnapshotIsUnaffectedBySubsequentWrites() throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-config-snapshot")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("config.toml")
    try "original".write(to: source, atomically: true, encoding: .utf8)
    let pinned = try NativeAddonPinnedFile(path: source.path)
    let snapshot = try pinned.snapshotDescriptorPath()
    try "changed".write(to: source, atomically: false, encoding: .utf8)
    XCTAssertEqual(try String(contentsOfFile: snapshot, encoding: .utf8), "original")
  }

  func testQueryAndVariablesFilesBecomeBoundedInlineArguments() throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-inline-inputs")
    defer { try? FileManager.default.removeItem(at: root) }
    try "query { note { id } }".write(to: root.appendingPathComponent("query.graphql"), atomically: true, encoding: .utf8)
    try #"{"id":"n1"}"#.write(to: root.appendingPathComponent("vars.json"), atomically: true, encoding: .utf8)
    let paths = NativeAddonWorkspacePaths(workingDirectory: root, mounts: [])
    try paths.withNativeArguments(["graphql", "--query-file", "query.graphql", "--variables-file", "vars.json"]) { arguments in
      XCTAssertEqual(arguments, ["graphql", "--query", "query { note { id } }", "--variables", #"{"id":"n1"}"#])
    }
  }

  func testOutputDirectoryDescriptorSurvivesReplacementAndTranslatesGuestPath() throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-pinned-output")
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("output")
    let moved = root.appendingPathComponent("moved")
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let paths = NativeAddonWorkspacePaths(workingDirectory: root, mounts: [.init(source: output.path, target: "/tmp/download", readOnly: false)])
    let result = try NativeAddonPinnedDirectory.StagingContext.$root.withValue(root.deletingLastPathComponent()) {
      try paths.withGatewayArguments(["file", "download", "--key", "k", "--output-dir", "/tmp/download"]) { arguments in
      try FileManager.default.moveItem(at: output, to: moved)
      try FileManager.default.createSymbolicLink(at: output, withDestinationURL: outside)
      let destination = arguments[5] + "/body.txt"
      try Data("body".utf8).write(to: URL(fileURLWithPath: destination), options: .withoutOverwriting)
      return .init(stdout: #"{"files":[{"path":"\#(destination)"}]}"#, stderr: "")
    }
    }
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
    guard case let .object(object) = decoded, case let .array(files)? = object["files"],
          case let .object(file)? = files.first else { return XCTFail("missing translated output") }
    XCTAssertEqual(file["path"], .string("/tmp/download/body.txt"))
    XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("body.txt"), encoding: .utf8), "body")
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("body.txt").path))
  }
}
