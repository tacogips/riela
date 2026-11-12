import Foundation
import RielaAdapters
import RielaCore
import XCTest

@testable import RielaCLI

final class MediaPipelineMediaLogicTests: XCTestCase {
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

  func testProcessEnvironmentLookupAndRedactedStderrTail() async throws {
    let root = try makeTestDirectory("process")
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let runner = CapturingMediaPipelineRunner()
    let service = MediaPipelineService(
      runner: runner, workingDirectory: root,
      http: { _ in throw MediaPipelineTestError.unexpectedHTTP },
      resolverEnvironment: [
        "PATH": bin.path, "HOME": "/resolver/home", "XDG_CACHE_HOME": "/resolver/cache",
        "DENO_DIR": "/resolver/deno"
      ])
    _ = try await service.run(URL(fileURLWithPath: "/bin/true"), [], stage: "frames", deadline: nil)
    let configuration = await runner.configuration
    XCTAssertEqual(configuration?.environment["PATH"], service.resolvedSearchPath)
    XCTAssertEqual(configuration?.environment["HOME"], "/resolver/home")
    XCTAssertEqual(configuration?.environment["XDG_CACHE_HOME"], "/resolver/cache")
    XCTAssertNil(configuration?.environment["DENO_DIR"])
    XCTAssertTrue(service.resolvedSearchPath.contains("/usr/bin"))

    let tool = bin.appendingPathComponent("ffmpeg")
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
    XCTAssertEqual(try failing.executable(nil, name: "ffmpeg", stage: "frames").path, tool.path)
    do {
      _ = try await failing.run(tool, [], stage: "download", deadline: nil)
      XCTFail("expected process failure")
    } catch {
      XCTAssertFalse(String(describing: error).contains("hidden-token"))
      XCTAssertTrue(String(describing: error).contains("[REDACTED]"))
    }
  }

  func testMultipartSTTAcceptsExactDecimalTwentyFiveMegabyteLimit() throws {
    let root = try makeTestDirectory("stt-size-limit")
    let audio = root.appendingPathComponent("audio.mp3")
    XCTAssertTrue(FileManager.default.createFile(atPath: audio.path, contents: Data()))
    let file = try FileHandle(forWritingTo: audio)
    try file.truncate(atOffset: 25_000_000)
    XCTAssertEqual(try SpeechAudioUpload.read(audio).count, 25_000_000)
    try file.truncate(atOffset: 25_000_001)
    try file.close()
    XCTAssertThrowsError(try SpeechAudioUpload.read(audio)) { error in
      XCTAssertTrue(String(describing: error).contains("25 MB"))
    }
  }

  func testProcessTimeoutIsPreservedAndNetworkRetryStopsAtMaximumAttempts() async throws {
    let root = try makeTestDirectory("timeout-retry")
    let timeoutService = MediaPipelineService(
      runner: ThrowingMediaPipelineRunner(error: AdapterExecutionError(.timeout, "deadline")),
      workingDirectory: root, http: { _ in throw MediaPipelineTestError.unexpectedHTTP })
    do {
      _ = try await timeoutService.run(URL(fileURLWithPath: "/bin/ffmpeg"), [], stage: "audio", deadline: nil)
      XCTFail("expected process timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertEqual(error.message, "deadline")
    }
    let cancellationService = MediaPipelineService(
      runner: ThrowingMediaPipelineRunner(error: CancellationError()),
      workingDirectory: root, http: { _ in throw MediaPipelineTestError.unexpectedHTTP })
    do {
      _ = try await cancellationService.run(URL(fileURLWithPath: "/bin/ffmpeg"), [], stage: "audio", deadline: nil)
      XCTFail("expected cancellation")
    } catch is CancellationError {
      // Cancellation should cross the process boundary unchanged.
    }

    let request = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.test")))
    let retrying = RetryableMediaPipelineHTTPStub(failures: 1, status: 429)
    let retryService = MediaPipelineService(
      runner: FoundationLocalProcessRunner(), workingDirectory: root,
      http: { request in try await retrying.send(request) })
    let response = try await retryService.sendClassified(
      request, maxAttempts: 2, label: "stt", deadline: nil)
    XCTAssertEqual(String(data: response, encoding: .utf8), "recognized speech")
    let retriedCount = await retrying.count
    XCTAssertEqual(retriedCount, 2)

    let failing = RetryableMediaPipelineHTTPStub(failures: 4)
    let giveUpService = MediaPipelineService(
      runner: FoundationLocalProcessRunner(), workingDirectory: root,
      http: { request in try await failing.send(request) })
    do {
      _ = try await giveUpService.sendClassified(request, maxAttempts: 2, label: "stt", deadline: nil)
      XCTFail("expected retries to stop at maxAttempts")
    } catch let error as SpeechProviderFailure {
      XCTAssertEqual(error.failureClass, .transportError)
    }
    let failedCount = await failing.count
    XCTAssertEqual(failedCount, 2)

    let unauthorized = RetryableMediaPipelineHTTPStub(failures: 4, status: 401)
    let httpFailureService = MediaPipelineService(
      runner: FoundationLocalProcessRunner(), workingDirectory: root,
      http: { request in try await unauthorized.send(request) })
    do {
      _ = try await httpFailureService.sendClassified(request, maxAttempts: 2, label: "stt", deadline: nil)
      XCTFail("expected HTTP failure")
    } catch let error as SpeechProviderFailure {
      XCTAssertEqual(error.failureClass, .rejected)
      XCTAssertEqual(error.httpStatus, 401)
      XCTAssertFalse(error.message.contains("api-secret"))
    }
    let unauthorizedCount = await unauthorized.count
    XCTAssertEqual(unauthorizedCount, 1)
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

private struct ThrowingMediaPipelineRunner: LocalProcessRunning {
  let error: Error
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws
    -> LocalProcessResult { throw error }
}

private actor RetryableMediaPipelineHTTPStub {
  private(set) var count = 0
  private let failures: Int
  private let status: Int?
  init(failures: Int, status: Int? = nil) {
    self.failures = failures
    self.status = status
  }
  func send(_ request: URLRequest) throws -> MediaPipelineHTTPResponse {
    count += 1
    if count <= failures {
      guard let status else { throw MediaPipelineTestError.unexpectedHTTP }
      return .init(status: status, body: Data("api-secret must not be shown".utf8), retryAfter: 0)
    }
    return .init(status: 200, body: Data("recognized speech".utf8), retryAfter: nil)
  }
}

private enum MediaPipelineTestError: Error { case unexpectedHTTP }
