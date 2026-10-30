import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class VideoPipelineYtDlpPackageTests: XCTestCase {
  func testInstallAndMockWorkflow() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let source = root.appendingPathComponent("examples/video-pipeline-yt-dlp")
    let temp = root.appendingPathComponent("tmp/yt-dlp-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let home = temp.appendingPathComponent("home")
    let project = temp.appendingPathComponent("project")
    let other = temp.appendingPathComponent("other")
    for directory in [home, project, other] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try await CLIRuntimeEnvironment.$overrides.withValue([
      "HOME": home.path, "RIELA_WORKFLOW_HOME": home.appendingPathComponent(".riela").path
    ]) {
      let app = RielaCLIApplication()
      let validate = await app.run(["package", "validate", source.path, "--output", "json"])
      XCTAssertEqual(validate.exitCode, .success, validate.stdout + validate.stderr)
      for (directory, scope) in [(project, "project"), (other, "user")] {
        let install = await app.run(["package", "install", "video-pipeline-yt-dlp", "--source", source.path,
          "--scope", scope, "--working-dir", directory.path, "--output", "json"])
        XCTAssertEqual(install.exitCode, .success, install.stdout + install.stderr)
        let installedRoot = (scope == "project" ? directory : home)
          .appendingPathComponent(".riela/packages/video-pipeline-yt-dlp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedRoot.appendingPathComponent("riela-package.json").path))
        let checked = await app.run(["workflow", "validate", "video-pipeline-yt-dlp", "--working-dir",
          directory.path, "--output", "json"])
        XCTAssertEqual(checked.exitCode, .success, checked.stdout + checked.stderr)
        XCTAssertFalse(checked.stdout.contains("unresolvedAddonExecutable"))
      }

      let scenario = project.appendingPathComponent(
        ".riela/packages/video-pipeline-yt-dlp/workflow/mock-scenario.json")
      let run = await app.run(["workflow", "run", "video-pipeline-yt-dlp", "--working-dir", project.path,
        "--mock-scenario", scenario.path, "--session-store", temp.appendingPathComponent("sessions").path,
        "--output", "json"])
      XCTAssertEqual(run.exitCode, .success, run.stdout + run.stderr)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let result = try decoder.decode(WorkflowRunResult.self, from: Data(run.stdout.utf8))
      let audio = try XCTUnwrap(result.session.executions.first { $0.stepId == "audio" })
      guard case .object(let input)? = audio.inputSnapshot?["resolvedInputPayload"] else {
        return XCTFail("Missing audio input")
      }
      XCTAssertEqual(input["mediaDownload"], .object([
        "status": .string("downloaded"), "path": .string("/tmp/riela-fixture/video.mp4")
      ]))
    }
    let nodeHome = temp.appendingPathComponent("node-home")
    try FileManager.default.createDirectory(at: nodeHome, withIntermediateDirectories: true)
    try await CLIRuntimeEnvironment.$overrides.withValue([
      "HOME": nodeHome.path, "RIELA_WORKFLOW_HOME": nodeHome.appendingPathComponent(".riela").path
    ]) {
      let result = await RielaCLIApplication().run(["node", "install", "video-pipeline-yt-dlp", "--source",
        source.path, "--scope", "user", "--working-dir", other.path, "--output", "json"])
      XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
      XCTAssertTrue(FileManager.default.fileExists(atPath: nodeHome.appendingPathComponent(
        ".riela/addons/media/yt-dlp-download/1/riela-package.json").path))
    }
  }

  func testScriptRejectsPrivateAndUnsupportedOptions() throws {
    let python = Process()
    python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    python.arguments = ["python3", "--version"]
    python.standardOutput = Pipe()
    python.standardError = Pipe()
    try python.run()
    python.waitUntilExit()
    guard python.terminationStatus == 0 else { throw XCTSkip("python3 unavailable") }
    let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("examples/video-pipeline-yt-dlp/addons/yt-dlp-download/yt-dlp-download")
    let temp = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/yt-dlp-script-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let bin = temp.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let copy = temp.appendingPathComponent("script")
    try FileManager.default.copyItem(at: script, to: copy)
    let fake = """
    #!/bin/sh
    echo "$*" >> "$ARGS"
    for arg in "$@"; do
      if [ "$arg" = "-O" ]; then
        case "$FAKE_MODE" in
          live) echo '{"duration":10,"live_status":"is_live"}' ;;
          long) echo '{"duration":8000}' ;;
          *) echo '{"id":"abc","title":"test","duration":10}' ;;
        esac
        exit 0
      fi
    done
    echo download >> "$CALLS"
    while [ "$1" != "-o" ]; do shift; done
    path=$(dirname "$2")/video.mp4
    touch "$path"
    echo "$path"
    """
    for (name, content) in [("yt-dlp", fake), ("ffmpeg", "#!/bin/sh\nexit 0\n"), ("deno", "#!/bin/sh\nexit 0\n")] {
      let file = bin.appendingPathComponent(name)
      try content.write(to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    func invoke(_ options: [String: Any], mode: String = "") throws -> ScriptResult {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["python3", copy.path]
      process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1",
        "RIELA_ARTIFACT_DIR": temp.appendingPathComponent("artifacts").path,
        "CALLS": temp.appendingPathComponent("calls").path, "FAKE_MODE": mode,
        "ARGS": temp.appendingPathComponent("args").path]
      let input = Pipe()
      let output = Pipe()
      process.standardInput = input
      process.standardOutput = output
      let errors = Pipe()
      process.standardError = errors
      try process.run()
      let data = try JSONSerialization.data(withJSONObject: ["nodePayload": ["config": ["options": options]]])
      input.fileHandleForWriting.write(data + Data("\n".utf8))
      try input.fileHandleForWriting.close()
      process.waitUntilExit()
      let stderr = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      return ScriptResult(
        status: process.terminationStatus, stdout: output.fileHandleForReading.readDataToEndOfFile(), stderr: stderr)
    }
    let valid: [String: Any] = ["url": "https://example.com/video"]
    let first = try invoke(valid)
    XCTAssertEqual(first.status, 0)
    XCTAssertEqual(try XCTUnwrap(String(data: first.stdout, encoding: .utf8)).split(separator: "\n").count, 1)
    let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: first.stdout) as? [String: [String: Any]])
    let media = try XCTUnwrap(firstJSON["mediaDownload"])
    let path = try XCTUnwrap(media["path"] as? String)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    XCTAssertTrue(path.hasPrefix(temp.appendingPathComponent("artifacts/media-download").path + "/"))
    XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent.count, 24)
    XCTAssertEqual(media["cached"] as? Bool, false)
    let second = try invoke(valid)
    XCTAssertEqual(second.status, 0)
    let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: second.stdout) as? [String: [String: Any]])
    XCTAssertEqual(secondJSON["mediaDownload"]?["cached"] as? Bool, true)
    let calls = try String(contentsOf: temp.appendingPathComponent("calls"), encoding: .utf8)
    XCTAssertEqual(calls.split(separator: "\n").count, 1)
    let invocations = try String(contentsOf: temp.appendingPathComponent("args"), encoding: .utf8)
      .split(separator: "\n")
    XCTAssertEqual(invocations.count, 2)
    let cacheDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
      .appendingPathComponent(".yt-dlp-cache").path
    for invocation in invocations {
      XCTAssertTrue(invocation.hasPrefix(
        "--ignore-config --js-runtimes deno:\(bin.appendingPathComponent("deno").path) --cache-dir \(cacheDirectory) "),
        String(invocation))
    }
    for (mode, reason) in [("live", "metadata: live streams are forbidden"),
      ("long", "metadata: invalid or excessive duration")] {
      let result = try invoke(["url": "https://example.com/\(mode)"], mode: mode)
      XCTAssertEqual(result.status, 1)
      XCTAssertTrue(result.stdout.isEmpty)
      XCTAssertEqual(result.stderr, "yt-dlp-download: \(reason)\n")
    }
    for options in [["url": "http://127.0.0.1/x"], ["url": "http://10.0.0.1/x"], ["url": "http://localhost/x"],
      ["url": "https://example.com/x", "ytDlpPath": "/tmp/tool"]] {
      let result = try invoke(options)
      XCTAssertEqual(result.status, 1)
      XCTAssertTrue(result.stdout.isEmpty)
      XCTAssertTrue(result.stderr.hasPrefix("yt-dlp-download: "), result.stderr)
      XCTAssertFalse(result.stderr.contains("http"), result.stderr)
    }
    let failing = try invoke(["url": "https://user:secret@example.com/x"])
    XCTAssertEqual(failing.stderr, "yt-dlp-download: url: invalid URL\n")
  }
}

private struct ScriptResult {
  var status: Int32
  var stdout: Data
  var stderr: String
}
