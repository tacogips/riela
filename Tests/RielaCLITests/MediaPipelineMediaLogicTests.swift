import Foundation
import RielaAdapters
import RielaCore
import XCTest

@testable import RielaCLI

final class MediaPipelineMediaLogicTests: XCTestCase {
  func testYouTubeNormalizationAndPrivateHostRejection() throws {
    let normalized = try XCTUnwrap(
      MediaPipelineOptions.normalizedURL(
        "https://m.youtube.com/watch?feature=share&si=x&v=abc&t=482s&pp=y"))
    XCTAssertEqual(normalized.absoluteString, "https://www.youtube.com/watch?v=abc")
    XCTAssertTrue(MediaPipelineOptions.isSafeURL(normalized))
    for raw in [
      "http://localhost/a", "http://127.2.3.4/a", "http://10.0.0.1/a", "http://192.168.1.1/a",
      "http://[::1]/a", "http://[fd00::1]/a"
    ] {
      XCTAssertFalse(
        MediaPipelineOptions.normalizedURL(raw).map(MediaPipelineOptions.isSafeURL) ?? true, raw)
    }
    XCTAssertTrue(MediaPipelineOptions.host("media.example.com", matches: "example.com"))
    XCTAssertFalse(MediaPipelineOptions.host("example.com.attacker.test", matches: "example.com"))
  }

  func testDifferenceHashAndDedupeUse256Bits() throws {
    let flat = Array(repeating: UInt8(10), count: 272)
    let changed = (0..<272).map { $0.isMultiple(of: 2) ? UInt8(10) : UInt8(20) }
    let first = try XCTUnwrap(MediaPipelineMediaLogic.differenceHash(flat))
    let same = try XCTUnwrap(MediaPipelineMediaLogic.differenceHash(flat))
    let second = try XCTUnwrap(MediaPipelineMediaLogic.differenceHash(changed))
    XCTAssertEqual(first.count, 4)
    XCTAssertEqual(MediaPipelineMediaLogic.difference(first, same), 0)
    XCTAssertGreaterThan(MediaPipelineMediaLogic.difference(first, second), 0.15)
    XCTAssertEqual(
      MediaPipelineMediaLogic.keptFrameIndices(hashes: [first, same, second], threshold: 0.15),
      [0, 2])
  }

  func testSilenceBoundaryChoiceRemainderMergeAndCarryForward() {
    let silences = MediaPipelineMediaLogic.silences(
      stderr: "silence_start: 29.0\nsilence_end: 31.0\nsilence_start: 59.0\nsilence_end: 61.0")
    XCTAssertEqual(silences.count, 2)
    let batches = MediaPipelineMediaLogic.batches(duration: 65, target: 30, silences: silences)
    XCTAssertEqual(batches, [.init(start: 0, end: 30), .init(start: 30, end: 65)])
    XCTAssertEqual(
      MediaPipelineMediaLogic.silences(stderr: "silence_start: -0.0213\nsilence_end: 1.25"),
      [.init(start: -0.0213, end: 1.25)])
    let frames = [
      MediaFrame(time: 1, path: "/tmp/a.jpg"), MediaFrame(time: 34, path: "/tmp/b.jpg")
    ]
    let assigned = MediaPipelineMediaLogic.framesByBatch(
      frames,
      batches: [.init(start: 0, end: 30), .init(start: 30, end: 33), .init(start: 33, end: 40)],
      carryForward: true)
    XCTAssertEqual(assigned[1].map(\.1), [true])
    XCTAssertEqual(assigned[2].map(\.1), [false])
  }

  func testProcessEnvironmentDenoLookupAndRedactedStderrTail() async throws {
    let root = try makeTestDirectory("process")
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let deno = bin.appendingPathComponent("deno")
    try Data([0]).write(to: deno)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deno.path)
    let runner = CapturingMediaPipelineRunner()
    let service = MediaPipelineService(
      runner: runner, workingDirectory: root,
      http: { _ in throw MediaPipelineTestError.unexpectedHTTP },
      resolverEnvironment: ["PATH": bin.path])
    XCTAssertEqual(
      service.ytDlpArguments(["--no-playlist"]),
      ["--ignore-config", "--js-runtimes", "deno:\(deno.path)", "--no-playlist"])
    XCTAssertEqual(
      service.ytDlpArguments(["--no-playlist"], deno: nil), ["--ignore-config", "--no-playlist"])
    _ = try await service.run(URL(fileURLWithPath: "/bin/true"), [], stage: "frames", deadline: nil)
    let configuration = await runner.configuration
    XCTAssertEqual(configuration?.environment["PATH"], service.resolvedSearchPath)
    XCTAssertTrue(service.resolvedSearchPath.contains("/usr/bin"))

    let tool = bin.appendingPathComponent("yt-dlp")
    try Data([0]).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let failing = MediaPipelineService(
      runner: FixedResultMediaPipelineRunner(
        result:
          .init(
            stdout: "", stderr: String(repeating: "x", count: 520) + " Bearer hidden-token",
            terminationStatus: 1)),
      workingDirectory: root, http: { _ in throw MediaPipelineTestError.unexpectedHTTP },
      resolverEnvironment: ["PATH": bin.path])
    XCTAssertEqual(try failing.executable(nil, name: "yt-dlp", stage: "metadata").path, tool.path)
    do {
      _ = try await failing.run(tool, [], stage: "download", deadline: nil)
      XCTFail("expected process failure")
    } catch {
      XCTAssertFalse(String(describing: error).contains("hidden-token"))
      XCTAssertTrue(String(describing: error).contains("[REDACTED]"))
    }
  }

  func testMultipartSTTRetriesAndNormalizesBaseURL() async throws {
    let root = try makeTestDirectory("stt")
    let audio = root.appendingPathComponent("audio.mp3")
    try Data([1, 2, 3, 4]).write(to: audio)
    let stub = MediaPipelineHTTPStub()
    let service = MediaPipelineService(
      runner: FoundationLocalProcessRunner(), workingDirectory: root,
      http: { request in try await stub.send(request) })
    let options = MediaPipelineSTTOptions(
      model: "gpt-4o-transcribe", language: "ja", prompt: "vocabulary", maxAttempts: 2)
    let text = try await service.transcribeChunk(
      audio, options: options, apiKey: "secret-value", baseURL: "https://api.example.test/v1/",
      deadline: nil, timeoutSeconds: 9)
    XCTAssertEqual(text, "recognized speech")
    let requests = await stub.requests
    XCTAssertEqual(requests.count, 2)
    let multipart = try XCTUnwrap(
      requests.last?.httpBody.flatMap { String(data: $0, encoding: .utf8) })
    for field in [
      "name=\"model\"", "name=\"file\"", "name=\"response_format\"", "name=\"language\"",
      "name=\"prompt\"", "gpt-4o-transcribe", "audio/mpeg", "vocabulary"
    ] {
      XCTAssertTrue(multipart.contains(field), "missing multipart field \(field)")
    }
    XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-value")
    XCTAssertEqual(
      requests.last?.url?.absoluteString, "https://api.example.test/v1/audio/transcriptions")
    XCTAssertEqual(requests.last?.timeoutInterval, 9)
  }
}

extension MediaPipelineMediaLogicTests {
  fileprivate func makeTestDirectory(_ name: String) throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(
        "tmp/media-pipeline-tests/\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}

private actor CapturingMediaPipelineRunner: LocalProcessRunning {
  private(set) var configuration: LocalProcessConfiguration?
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws
    -> LocalProcessResult {
    self.configuration = configuration
    return .init(stdout: "", stderr: "", terminationStatus: 0)
  }
}

private struct FixedResultMediaPipelineRunner: LocalProcessRunning {
  let result: LocalProcessResult
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws
    -> LocalProcessResult { result }
}

private actor MediaPipelineHTTPStub {
  private(set) var requests: [URLRequest] = []
  private var count = 0
  func send(_ request: URLRequest) throws -> MediaPipelineHTTPResponse {
    requests.append(request)
    count += 1
    if count == 1 { return .init(status: 429, body: Data("secret-value".utf8), retryAfter: 0) }
    return .init(status: 200, body: Data("{\"text\":\"recognized speech\"}".utf8), retryAfter: nil)
  }
}

private enum MediaPipelineTestError: Error { case unexpectedHTTP }
