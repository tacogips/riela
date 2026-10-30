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

  func testMultipartSTTAcceptsExactDecimalTwentyFiveMegabyteLimit() async throws {
    let root = try makeTestDirectory("stt-size-limit")
    let audio = root.appendingPathComponent("audio.mp3")
    XCTAssertTrue(FileManager.default.createFile(atPath: audio.path, contents: Data()))
    let file = try FileHandle(forWritingTo: audio)
    try file.truncate(atOffset: 25_000_000)
    try file.close()
    let service = MediaPipelineService(
      runner: FoundationLocalProcessRunner(), workingDirectory: root,
      http: { _ in
        .init(status: 200, body: Data("{\"text\":\"recognized speech\"}".utf8), retryAfter: nil)
      })
    let options = MediaPipelineSTTOptions(
      model: "gpt-4o-transcribe", language: nil, prompt: nil, maxAttempts: 1)

    let transcript = try await service.transcribeChunk(
      audio, options: options, apiKey: "secret-value", baseURL: "https://api.example.test",
      deadline: nil, timeoutSeconds: 9)
    XCTAssertEqual(transcript, "recognized speech")
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

    let audio = root.appendingPathComponent("audio.mp3")
    try Data([1, 2, 3]).write(to: audio)
    let retrying = RetryableMediaPipelineHTTPStub(failures: 1)
    let retryService = MediaPipelineService(
      runner: FoundationLocalProcessRunner(), workingDirectory: root,
      http: { request in try await retrying.send(request) })
    let options = MediaPipelineSTTOptions(model: "model", language: nil, prompt: nil, maxAttempts: 2)
    let transcript = try await retryService.transcribeChunk(
      audio, options: options, apiKey: "api-secret", baseURL: "https://api.example.test",
      deadline: nil, timeoutSeconds: 2)
    XCTAssertEqual(transcript, "recognized speech")
    let retriedCount = await retrying.count
    XCTAssertEqual(retriedCount, 2)

    let failing = RetryableMediaPipelineHTTPStub(failures: 4)
    let giveUpService = MediaPipelineService(
      runner: FoundationLocalProcessRunner(), workingDirectory: root,
      http: { request in try await failing.send(request) })
    do {
      _ = try await giveUpService.transcribeChunk(
        audio, options: options, apiKey: "api-secret", baseURL: "https://api.example.test",
        deadline: nil, timeoutSeconds: 2)
      XCTFail("expected retries to stop at maxAttempts")
    } catch {
      XCTAssertFalse(String(describing: error).contains("api-secret"))
    }
    let failedCount = await failing.count
    XCTAssertEqual(failedCount, 2)

    let httpFailureService = MediaPipelineService(
      runner: FoundationLocalProcessRunner(), workingDirectory: root,
      http: { _ in
        .init(status: 401, body: Data("api-secret must not be shown".utf8), retryAfter: nil)
      })
    do {
      _ = try await httpFailureService.transcribeChunk(
        audio, options: options, apiKey: "api-secret", baseURL: "https://api.example.test",
        deadline: nil, timeoutSeconds: 2)
      XCTFail("expected HTTP failure")
    } catch {
      XCTAssertFalse(String(describing: error).contains("api-secret"))
      XCTAssertTrue(String(describing: error).contains("HTTP 401"))
    }
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
  init(failures: Int) { self.failures = failures }
  func send(_ request: URLRequest) throws -> MediaPipelineHTTPResponse {
    count += 1
    if count <= failures { throw MediaPipelineTestError.unexpectedHTTP }
    return .init(status: 200, body: Data("{\"text\":\"recognized speech\"}".utf8), retryAfter: nil)
  }
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
