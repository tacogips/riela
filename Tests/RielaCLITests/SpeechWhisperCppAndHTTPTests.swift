import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class SpeechWhisperCppAndHTTPTests: XCTestCase {
  func testWhisperArgumentsAndFailures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = root.appendingPathComponent("whisper-cli")
    try Data().write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let model = root.appendingPathComponent("model.bin")
    try Data().write(to: model)
    let audio = root.appendingPathComponent("audio.wav")
    let runner = WhisperTestRunner()
    let service = MediaPipelineService(runner: runner, workingDirectory: root, http: { _ in
      .init(status: 200, body: Data(), retryAfter: nil)
    }, resolverEnvironment: ["PATH": root.path])
    let options = WhisperCppOptions(binary: nil, model: "model.bin", threads: nil, extraArgs: [])
    let text = try await service.whisperCppTranscribe(
      audio: audio, options: options, language: nil, timeoutSeconds: 10, deadline: nil)
    XCTAssertEqual(text, "transcript")
    var calls = await runner.calls
    XCTAssertEqual(calls[0].executableURL, binary)
    XCTAssertEqual(calls[0].arguments, ["-m", model.path, "-f", audio.path, "-l", "auto", "-nt", "-np"])
    let custom = WhisperCppOptions(binary: binary.path, model: model.path, threads: 4, extraArgs: ["--best-of", "5"])
    _ = try await service.whisperCppTranscribe(audio: audio, options: custom, language: "ja", timeoutSeconds: 10, deadline: nil)
    calls = await runner.calls
    XCTAssertEqual(calls[1].executableURL, binary)
    XCTAssertEqual(calls[1].arguments, ["-m", model.path, "-f", audio.path, "-l", "ja", "-nt", "-np", "-t", "4", "--best-of", "5"])
    let missing = WhisperCppOptions(binary: binary.path, model: "missing", threads: nil, extraArgs: [])
    do {
      _ = try await service.whisperCppTranscribe(audio: audio, options: missing, language: "", timeoutSeconds: 10, deadline: nil)
      XCTFail("expected unavailable")
    } catch let failure as SpeechProviderFailure { XCTAssertEqual(failure.failureClass, .unavailable) }
    let count = await runner.calls.count
    XCTAssertEqual(count, 2)
    for mode in [WhisperTestRunner.Mode.failed, .timeout] {
      let failing = WhisperTestRunner(mode: mode)
      let subject = MediaPipelineService(runner: failing, workingDirectory: root, http: service.http, resolverEnvironment: ["PATH": root.path])
      do {
        _ = try await subject.whisperCppTranscribe(audio: audio, options: options, language: "", timeoutSeconds: 10, deadline: nil)
        XCTFail("expected failure")
      } catch let failure as SpeechProviderFailure {
        XCTAssertEqual(failure.failureClass, mode == .failed ? .unavailable : .transportError)
        if mode == .failed { XCTAssertTrue(failure.message.contains("status 3")) }
      }
    }
  }

  func testRetryAfterIsPreservedOnlyWhenNonnegative() async throws {
    for (value, expected) in [(7.0, Optional(7.0)), (-1.0, nil)] {
      let service = MediaPipelineService(
        runner: WhisperTestRunner(), workingDirectory: FileManager.default.temporaryDirectory,
        http: { _ in
          .init(status: 429, body: Data(#"{"error":{"code":"rate_limit_exceeded"}}"#.utf8), retryAfter: value)
        })
      let request = RemoteSpeechRequest(
        file: URL(fileURLWithPath: "/audio.wav"), data: Data(), model: nil, language: nil,
        apiKey: "test", baseURL: "https://example.invalid", maxAttempts: 1, timeoutSeconds: 5)
      do {
        _ = try await service.deepgramTranscribe(request, deadline: nil)
        XCTFail("expected failure")
      } catch let failure as SpeechProviderFailure {
        XCTAssertEqual(failure.failureClass, .rateLimited)
        XCTAssertEqual(failure.providerProblem, "rate_limit_exceeded")
        XCTAssertEqual(failure.retryAfter, expected)
      }
    }
  }

  func testClassifiedHTTPProviders() async throws {
    let root = FileManager.default.temporaryDirectory
    let runner = WhisperTestRunner()
    let request = RemoteSpeechRequest(file: root.appendingPathComponent("audio.wav"), data: Data(), model: nil,
      language: nil, apiKey: "test", baseURL: "https://example.invalid", maxAttempts: 3, timeoutSeconds: 5)
    let cases: [HTTPCase] = [
      .init(status: 429, body: #"{"error":{"code":"insufficient_quota"}}"#, expected: .quotaExhausted, count: 1),
       .init(status: 503, body: "{}", expected: .serverError, count: 3),
      .init(status: 402, body: "{}", expected: .quotaExhausted, count: 1)
    ]
    for item in cases {
      let (status, body) = (item.status, item.body)
      let recorder = WhisperHTTPRecorder(status: status, body: body)
      let service = MediaPipelineService(runner: runner, workingDirectory: root, http: { request in await recorder.send(request) })
      do {
        if status == 402 { _ = try await service.elevenLabsTranscribe(request, deadline: nil) } else { _ = try await service.deepgramTranscribe(request, deadline: nil) }
        XCTFail("expected failure")
      } catch let failure as SpeechProviderFailure {
        XCTAssertEqual(failure.failureClass, item.expected)
        XCTAssertEqual(failure.httpStatus, status)
        if status == 429 { XCTAssertEqual(failure.providerProblem, "insufficient_quota") }
      }
      let actual = await recorder.count
      XCTAssertEqual(actual, item.count)
    }
    let recorder = WhisperHTTPRecorder(status: 200, body: #"{"results":[{"alternatives":[{"transcript":"hello"}]}]}"#)
    let service = MediaPipelineService(runner: runner, workingDirectory: root, http: { request in await recorder.send(request) })
    let text = try await service.googleTranscribe(request, deadline: nil)
    XCTAssertEqual(text, "hello")
  }
}

private actor WhisperTestRunner: LocalProcessRunning {
  enum Mode { case success, failed, timeout }
  let mode: Mode
  private(set) var calls: [LocalProcessConfiguration] = []
  init(mode: Mode = .success) { self.mode = mode }
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    calls.append(configuration)
    if mode == .timeout { throw AdapterExecutionError(.timeout, "timeout") }
    return .init(stdout: "  transcript \n", stderr: "boom", terminationStatus: mode == .failed ? 3 : 0)
  }
}

private actor WhisperHTTPRecorder {
  let status: Int
  let body: String
  private(set) var count = 0
  init(status: Int, body: String) { self.status = status; self.body = body }
  func send(_ request: URLRequest) -> MediaPipelineHTTPResponse {
    count += 1
    return .init(status: status, body: Data(body.utf8), retryAfter: 0)
  }
}

private struct HTTPCase {
  let status: Int
  let body: String
  let expected: SpeechFailureClass
  let count: Int
}
