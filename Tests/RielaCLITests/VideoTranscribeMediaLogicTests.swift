import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class VideoTranscribeMediaLogicTests: XCTestCase {
  func testOptionsDefaultsAndValidation() throws {
    let options = try VideoTranscribeOptions(["path": .string("clip.mp4")], workingDirectory: URL(fileURLWithPath: "/tmp/work"))
    XCTAssertEqual(options.frameInterval, 10)
    XCTAssertEqual(options.batchSeconds, 180)
    XCTAssertEqual(options.model, "gpt-4o-transcribe")
    if case let .path(url) = options.source { XCTAssertEqual(url.path, "/tmp/work/clip.mp4") } else { XCTFail("expected path source") }
    XCTAssertThrowsError(try VideoTranscribeOptions(["url": .string("https://example.com"), "path": .string("x")], workingDirectory: URL(fileURLWithPath: "/tmp")))
    XCTAssertThrowsError(try VideoTranscribeOptions(["path": .string("x"), "frameIntervalSeconds": .integer(0)], workingDirectory: URL(fileURLWithPath: "/tmp")))
  }

  func testURLNormalizationRemovesYouTubeTimeParameter() throws {
    let options = try VideoTranscribeOptions(["url": .string("https://www.youtube.com/watch?v=8QxKwYOyUaE&t=482s")], workingDirectory: URL(fileURLWithPath: "/tmp"))
    if case let .url(url) = options.source {
      XCTAssertEqual(url.absoluteString, "https://www.youtube.com/watch?v=8QxKwYOyUaE")
      XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "8QxKwYOyUaE")
    } else { XCTFail("expected URL source") }
  }

  func testDifferenceHashAndKeepSelection() throws {
    let flat = Array(repeating: UInt8(10), count: 272)
    let changed = (0..<272).map { $0 % 2 == 0 ? UInt8(10) : UInt8(20) }
    let first = try XCTUnwrap(VideoTranscribeMediaLogic.differenceHash(flat))
    let same = try XCTUnwrap(VideoTranscribeMediaLogic.differenceHash(flat))
    let second = try XCTUnwrap(VideoTranscribeMediaLogic.differenceHash(changed))
    XCTAssertEqual(VideoTranscribeMediaLogic.difference(first, same), 0)
    XCTAssertGreaterThan(VideoTranscribeMediaLogic.difference(first, second), 0.15)
    XCTAssertEqual(VideoTranscribeMediaLogic.keptFrameIndices(hashes: [first, same, second], threshold: 0.15), [0, 2])
  }

  func testSilenceBoundariesRemainderAndFrameCarryForward() {
    let silences = VideoTranscribeMediaLogic.silences(stderr: "silence_start: 29.0\nsilence_end: 31.0\nsilence_start: 59.0\nsilence_end: 61.0")
    XCTAssertEqual(silences.count, 2)
    let batches = VideoTranscribeMediaLogic.batches(duration: 65, target: 30, silences: silences)
    XCTAssertEqual(batches, [.init(start: 0, end: 30), .init(start: 30, end: 65)])
    let frames = [VideoFrame(time: 1, path: "/tmp/a.jpg"), VideoFrame(time: 34, path: "/tmp/b.jpg")]
    let assigned = VideoTranscribeMediaLogic.framesByBatch(frames, batches: [.init(start: 0, end: 30), .init(start: 30, end: 33), .init(start: 33, end: 40)], carryForward: true)
    XCTAssertEqual(assigned[1].map(\.1), [true])
    XCTAssertEqual(assigned[2].map(\.1), [false])
  }

  func testSTTMultipartRetries429AndKeepsCredentialsOutOfErrors() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/video-transcribe-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let audio = root.appendingPathComponent("audio.mp3")
    try Data([1, 2, 3, 4]).write(to: audio)
    let options = try VideoTranscribeOptions(["path": .string(audio.path), "language": .string("ja"),
      "sttPrompt": .string("vocabulary"), "stt": .object(["maxAttempts": .integer(2)])], workingDirectory: root)
    let stub = VideoTranscribeHTTPStub()
    let service = VideoTranscribeService(runner: ThrowingVideoTranscribeRunner(), workingDirectory: root,
      artifactRoot: root, http: { request in try await stub.send(request) })
    let text = try await service.transcribeChunk(audio, options: options, apiKey: "secret-value", baseURL: "https://api.example.test", deadline: nil)
    XCTAssertEqual(text, "recognized speech")
    let requests = await stub.requests
    XCTAssertEqual(requests.count, 2)
    let body = try XCTUnwrap(requests.last?.httpBody)
    let multipart = try XCTUnwrap(String(data: body, encoding: .utf8))
    for field in ["name=\"model\"", "name=\"file\"", "name=\"response_format\"", "name=\"language\"", "name=\"prompt\"", "gpt-4o-transcribe", "audio/mpeg", "vocabulary"] {
      XCTAssertTrue(multipart.contains(field), "missing multipart field \(field)")
    }
    XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-value")
  }

  func testCompletedCacheAvoidsProcessAndHTTP() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/video-transcribe-tests/cache", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let input = root.appendingPathComponent("local.mp4")
    try Data([0]).write(to: input)
    let output = root.appendingPathComponent("output", isDirectory: true)
    let options = try VideoTranscribeOptions(["path": .string(input.path), "outputDir": .string(output.path)], workingDirectory: root)
    let service = VideoTranscribeService(runner: ThrowingVideoTranscribeRunner(), workingDirectory: root, artifactRoot: root,
      http: { _ in throw VideoTranscribeTestError.unexpectedHTTP })
    let cachedPayload: JSONObject = ["videoTranscribe": .object(["status": .string("completed"), "cached": .bool(false)])]
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let manifest: [String: Any] = ["status": "completed", "optionsFingerprint": try service.optionsFingerprint(options),
      "payload": try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(cachedPayload)))]
    let manifestData = try JSONSerialization.data(withJSONObject: manifest)
    try manifestData.write(to: output.appendingPathComponent("manifest.json"))
    let result = try await service.collect(options: options, apiKey: "secret", baseURL: "https://example.test", deadline: nil)
    guard case let .object(video)? = result["videoTranscribe"] else { return XCTFail("missing video output") }
    XCTAssertEqual(video["cached"], .bool(true))
  }

  func testFFmpegIntegrationBuildsBatchScopedTranscriptImagesWhenAvailable() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/video-transcribe-tests/integration", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw XCTSkip("ffmpeg is not installed")
    }
    let runner = FoundationLocalProcessRunner()
    let input = root.appendingPathComponent("fixture.mp4")
    let expression = #"if(between(t\,28\,32)+between(t\,58\,62)\,0\,0.1)"#
    let generated = try await runner.run(configuration: .init(executableURL: URL(fileURLWithPath: ffmpegPath), arguments: [
      "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=30", "-f", "lavfi", "-i",
      "smptebars=size=320x240:rate=10:duration=40", "-f", "lavfi", "-i",
      "aevalsrc=\(expression):s=44100:d=70", "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]",
      "-map", "[v]", "-map", "2:a", "-t", "70", "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", input.path
    ], workingDirectoryURL: root, stdoutCaptureByteLimit: 1_000_000, stderrCaptureByteLimit: 1_000_000), stdin: "", deadline: nil)
    XCTAssertEqual(generated.terminationStatus, 0, generated.stderr)
    let options = try VideoTranscribeOptions(["path": .string(input.path), "outputDir": .string(root.appendingPathComponent("output").path),
      "frameIntervalSeconds": .integer(5), "frameDedupeThreshold": .integer(1), "batchSeconds": .integer(30),
      "stt": .object(["maxAttempts": .integer(1)])], workingDirectory: root)
    let service = VideoTranscribeService(runner: runner, workingDirectory: root, artifactRoot: root,
      http: { _ in .init(status: 200, body: Data("{\"text\":\"fixture transcript\"}".utf8), retryAfter: nil) })
    let payload = try await service.collect(options: options, apiKey: "test-secret", baseURL: "https://example.test", deadline: nil)
    guard case let .object(video)? = payload["videoTranscribe"], case let .array(batches)? = video["batches"] else {
      return XCTFail("invalid video-transcribe output shape")
    }
    XCTAssertEqual(video["status"], .string("completed"))
    XCTAssertEqual(video["durationSeconds"], .number(70))
    XCTAssertEqual(batches.count, 3)
    XCTAssertNil(payload["frames"])
    for item in batches {
      guard case let .object(batch) = item else { return XCTFail("batch was not an object") }
      XCTAssertEqual(batch["transcript"], .string("fixture transcript"))
      XCTAssertNotNil(batch["imagePaths"])
    }
    guard case let .object(secondBatch) = batches[1], case let .array(secondFrames)? = secondBatch["frames"],
      case let .object(carriedFrame)? = secondFrames.first else { return XCTFail("expected carried frame context") }
    XCTAssertEqual(carriedFrame["carried"], .bool(true))
  }
}

private actor VideoTranscribeHTTPStub {
  private(set) var requests: [URLRequest] = []
  private var count = 0

  func send(_ request: URLRequest) throws -> VideoTranscribeHTTPResponse {
    requests.append(request); count += 1
    if count == 1 { return .init(status: 429, body: Data("secret-value".utf8), retryAfter: 0) }
    return .init(status: 200, body: Data("{\"text\":\"recognized speech\"}".utf8), retryAfter: nil)
  }
}

private struct ThrowingVideoTranscribeRunner: LocalProcessRunning {
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    throw VideoTranscribeTestError.unexpectedProcess
  }
}

private enum VideoTranscribeTestError: Error { case unexpectedHTTP, unexpectedProcess }
