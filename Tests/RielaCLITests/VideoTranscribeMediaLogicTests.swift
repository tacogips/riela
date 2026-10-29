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
    for unsafe in ["file:///tmp/a", "http://localhost/a", "http://127.2.3.4/a", "http://10.1.2.3/a", "http://172.16.0.2/a", "http://192.168.1.1/a", "http://169.254.1.1/a", "http://[::1]/a", "http://[fd00::1]/a", "http://[fe80::1]/a"] {
      XCTAssertThrowsError(try VideoTranscribeOptions(["url": .string(unsafe)], workingDirectory: URL(fileURLWithPath: "/tmp")), unsafe)
    }
    XCTAssertThrowsError(try VideoTranscribeOptions(["url": .string("https://example.com"), "allowedHosts": .array([.string("youtube.com")])], workingDirectory: URL(fileURLWithPath: "/tmp")))
    XCTAssertThrowsError(try VideoTranscribeOptions(["path": .string("x"), "batchSeconds": .integer(2)], workingDirectory: URL(fileURLWithPath: "/tmp"))) { error in
      XCTAssertEqual(String(describing: error).contains("batchSeconds"), true)
    }
  }

  func testURLNormalizationRemovesYouTubeTimeParameter() throws {
    let options = try VideoTranscribeOptions(["url": .string("https://m.youtube.com/watch?feature=share&si=xyz&v=8QxKwYOyUaE&t=482s&pp=abc")], workingDirectory: URL(fileURLWithPath: "/tmp"))
    if case let .url(url) = options.source {
      XCTAssertEqual(url.absoluteString, "https://www.youtube.com/watch?v=8QxKwYOyUaE")
      XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "8QxKwYOyUaE")
    } else { XCTFail("expected URL source") }
    XCTAssertEqual(VideoTranscribeOptions.normalizedURL("https://youtu.be/8QxKwYOyUaE?si=share&t=4")?.absoluteString,
      "https://www.youtube.com/watch?v=8QxKwYOyUaE")
    XCTAssertFalse(VideoTranscribeOptions.normalizedURL("https://example.com/?t=4")?.absoluteString.hasSuffix("?") ?? true)
  }

  func testNegativeSilenceStartIsParsed() {
    XCTAssertEqual(VideoTranscribeMediaLogic.silences(stderr: "silence_start: -0.0213\nsilence_end: 1.25"), [.init(start: -0.0213, end: 1.25)])
  }

  func testResolverPathIsUsedAndToolStderrTailIsRedactedAndBounded() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/video-transcribe-tests/resolver", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let tool = bin.appendingPathComponent("yt-dlp")
    try Data([0]).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let service = VideoTranscribeService(runner: FixedResultVideoTranscribeRunner(result:
      .init(stdout: "", stderr: String(repeating: "x", count: 520) + " Bearer hidden-token", terminationStatus: 1)),
      workingDirectory: root, artifactRoot: root, http: { _ in throw VideoTranscribeTestError.unexpectedHTTP },
      resolverEnvironment: ["PATH": bin.path])
    XCTAssertEqual(try service.executable(nil, name: "yt-dlp", stage: "metadata").path, tool.path)
    do {
      _ = try await service.run(tool, [], stage: "download", deadline: nil)
      XCTFail("expected process failure")
    } catch {
      let message = String(describing: error)
      XCTAssertFalse(message.contains("hidden-token"))
      XCTAssertTrue(message.contains("[REDACTED]"))
      XCTAssertLessThanOrEqual(message.count, 600)
    }
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
    XCTAssertEqual(requests.last?.url?.absoluteString, "https://api.example.test/v1/audio/transcriptions")
    XCTAssertEqual(requests.last?.timeoutInterval, 300)
  }

  func testCompletedCacheAvoidsProcessAndHTTP() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/video-transcribe-tests/cache", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let normalizedURL = try XCTUnwrap(VideoTranscribeOptions.normalizedURL("https://www.youtube.com/watch?v=abc&t=12"))
    let options = try VideoTranscribeOptions(["url": .string(normalizedURL.absoluteString)], workingDirectory: root)
    let output = root.appendingPathComponent("video-transcribe", isDirectory: true)
      .appendingPathComponent(webCollectionKey(normalizedURL.absoluteString), isDirectory: true)
    let service = VideoTranscribeService(runner: ThrowingVideoTranscribeRunner(), workingDirectory: root, artifactRoot: root,
      http: { _ in throw VideoTranscribeTestError.unexpectedHTTP })
    let cachedPayload: JSONObject = ["videoTranscribe": .object(["status": .string("completed"), "cached": .bool(false), "batches": .array([])])]
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let transcriptURL = output.appendingPathComponent("transcript.json")
    try JSONEncoder().encode(JSONValue.object(cachedPayload)).write(to: transcriptURL)
    let manifest: [String: Any] = ["status": "completed", "optionsFingerprint": try service.optionsFingerprint(options),
      "payload": try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(cachedPayload)))]
    let manifestData = try JSONSerialization.data(withJSONObject: manifest)
    try manifestData.write(to: output.appendingPathComponent("manifest.json"))
    let result = try await service.collect(options: options, apiKey: "secret", baseURL: "https://example.test", deadline: nil)
    guard case let .object(video)? = result["videoTranscribe"] else { return XCTFail("missing video output") }
    XCTAssertEqual(video["cached"], .bool(true))
  }

  func testCacheFingerprintExcludesOperationalSettingsAndIncludesPrompt() throws {
    let root = URL(fileURLWithPath: "/tmp")
    let runner = ThrowingVideoTranscribeRunner()
    let service = VideoTranscribeService(runner: runner, workingDirectory: root, artifactRoot: root, http: { _ in throw VideoTranscribeTestError.unexpectedHTTP })
    let base = try VideoTranscribeOptions(["path": .string("x"), "sttPrompt": .string("one"), "stt": .object(["concurrency": .integer(1), "maxAttempts": .integer(1)])], workingDirectory: root)
    let operational = try VideoTranscribeOptions([
      "path": .string("x"), "sttPrompt": .string("one"), "maxDurationSeconds": .integer(40),
      "keepMedia": .bool(true), "cache": .bool(false), "ffmpegPath": .string("/fake"),
      "stt": .object(["concurrency": .integer(8), "maxAttempts": .integer(8)])
    ], workingDirectory: root)
    let changedPrompt = try VideoTranscribeOptions(["path": .string("x"), "sttPrompt": .string("two")], workingDirectory: root)
    XCTAssertEqual(try service.optionsFingerprint(base), try service.optionsFingerprint(operational))
    XCTAssertNotEqual(try service.optionsFingerprint(base), try service.optionsFingerprint(changedPrompt))
  }

  func testChunkTranscriptIsReusedOnlyForMatchingCacheKey() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/video-transcribe-tests/chunk-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let chunk = root.appendingPathComponent("0000.mp3")
    try Data([1]).write(to: chunk)
    let transcript = root.appendingPathComponent("0000.json")
    try JSONEncoder().encode(JSONValue.object(["text": .string("cached"), "cacheKey": .string("boundary-and-stt")])).write(to: transcript)
    let options = try VideoTranscribeOptions(["path": .string(chunk.path)], workingDirectory: root)
    let service = VideoTranscribeService(runner: ThrowingVideoTranscribeRunner(), workingDirectory: root, artifactRoot: root,
      http: { _ in throw VideoTranscribeTestError.unexpectedHTTP })
    let reused = try await service.transcribe([chunk], options: options, apiKey: "unused", baseURL: "https://api.example.test",
      directory: root, cacheKeys: ["boundary-and-stt"], deadline: nil)
    XCTAssertEqual(reused, ["cached"])
    do {
      _ = try await service.transcribe([chunk], options: options, apiKey: "unused", baseURL: "https://api.example.test",
        directory: root, cacheKeys: ["changed-boundary"], deadline: nil)
      XCTFail("expected cache mismatch to call the transport")
    } catch { XCTAssertTrue(String(describing: error).contains("request failed")) }
  }

  func testCacheValidationRequiresTranscriptAndEveryFrameFile() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/video-transcribe-tests/cache-files", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcriptURL = root.appendingPathComponent("transcript.json")
    try Data("{}".utf8).write(to: transcriptURL)
    let frameURL = root.appendingPathComponent("frame.jpg")
    let batch: JSONValue = .object(["frames": .array([.object(["path": .string(frameURL.path)])])])
    let payload: JSONObject = ["videoTranscribe": .object(["batches": .array([batch])])]
    let service = VideoTranscribeService(runner: ThrowingVideoTranscribeRunner(), workingDirectory: root, artifactRoot: root,
      http: { _ in throw VideoTranscribeTestError.unexpectedHTTP })
    XCTAssertFalse(service.cacheFilesExist(payload, output: root))
    try Data([1]).write(to: frameURL)
    XCTAssertTrue(service.cacheFilesExist(payload, output: root))
    try FileManager.default.removeItem(at: transcriptURL)
    XCTAssertFalse(service.cacheFilesExist(payload, output: root))
  }

  func testSTTFailureDoesNotLeakAPIKeyAndRetriesNetworkErrors() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/video-transcribe-tests/errors", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let audio = root.appendingPathComponent("audio.mp3"); try Data([1]).write(to: audio)
    let options = try VideoTranscribeOptions(["path": .string(audio.path), "stt": .object(["maxAttempts": .integer(2)])], workingDirectory: root)
    let attempts = NetworkFailureCounter()
    let service = VideoTranscribeService(runner: ThrowingVideoTranscribeRunner(), workingDirectory: root, artifactRoot: root,
      http: { _ in
        await attempts.increment()
        return .init(status: 500, body: Data("secret-value was rejected".utf8), retryAfter: 0)
      })
    do {
      _ = try await service.transcribeChunk(audio, options: options, apiKey: "secret-value", baseURL: "https://api.example.test/v1/", deadline: nil)
      XCTFail("expected exhausted retries")
    } catch {
      XCTAssertFalse(String(describing: error).contains("secret-value"))
      XCTAssertTrue(String(describing: error).contains("HTTP 500"))
    }
    let count = await attempts.count
    XCTAssertEqual(count, 2)
  }

  func testNetworkErrorRetriesThenGivesUpAtMaxAttempts() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/video-transcribe-tests/retries", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let audio = root.appendingPathComponent("audio.mp3"); try Data([1]).write(to: audio)
    let options = try VideoTranscribeOptions(["path": .string(audio.path), "stt": .object(["maxAttempts": .integer(2)])], workingDirectory: root)
    let attempts = NetworkFailureCounter()
    let service = VideoTranscribeService(runner: ThrowingVideoTranscribeRunner(), workingDirectory: root, artifactRoot: root,
      http: { _ in await attempts.increment(); throw VideoTranscribeTestError.unexpectedHTTP })
    do {
      _ = try await service.transcribeChunk(audio, options: options, apiKey: "secret", baseURL: "https://api.example.test", deadline: nil)
      XCTFail("expected exhausted retries")
    } catch { XCTAssertTrue(String(describing: error).contains("request failed")) }
    let count = await attempts.count
    XCTAssertEqual(count, 2)
  }

  func testFFmpegIntegrationBuildsBatchScopedTranscriptImagesWhenAvailable() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/video-transcribe-tests/integration", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: root.appendingPathComponent("output", isDirectory: true))
    guard let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw XCTSkip("ffmpeg is not installed")
    }
    let runner = FoundationLocalProcessRunner()
    let input = root.appendingPathComponent("fixture.mp4")
    let firstVideoFilter = ["color=black:size=320x240:rate=10:duration=30", "drawbox=x=0:y=0:w=40:h=240:color=white:t=fill",
      "drawbox=x=80:y=0:w=40:h=240:color=white:t=fill", "drawbox=x=160:y=0:w=40:h=240:color=white:t=fill",
      "drawbox=x=240:y=0:w=40:h=240:color=white:t=fill"].joined(separator: ",")
    let secondVideoFilter = ["color=black:size=320x240:rate=10:duration=40", "drawbox=x=40:y=0:w=40:h=240:color=white:t=fill",
      "drawbox=x=120:y=0:w=40:h=240:color=white:t=fill", "drawbox=x=200:y=0:w=40:h=240:color=white:t=fill",
      "drawbox=x=280:y=0:w=40:h=240:color=white:t=fill"].joined(separator: ",")
    let generated = try await runner.run(configuration: .init(executableURL: URL(fileURLWithPath: ffmpegPath), arguments: [
      "-y", "-f", "lavfi", "-i", firstVideoFilter, "-f", "lavfi", "-i", secondVideoFilter, "-f", "lavfi", "-i",
      "sine=frequency=440:sample_rate=44100:duration=70", "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]",
      "-map", "[v]", "-map", "2:a", "-t", "70", "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", input.path
    ], workingDirectoryURL: root, stdoutCaptureByteLimit: 1_000_000, stderrCaptureByteLimit: 1_000_000), stdin: "", deadline: nil)
    XCTAssertEqual(generated.terminationStatus, 0, generated.stderr)
    let options = try VideoTranscribeOptions(["path": .string(input.path), "outputDir": .string(root.appendingPathComponent("output").path),
      "frameIntervalSeconds": .integer(30), "frameDedupeThreshold": .number(0.15), "batchSeconds": .integer(30),
      "stt": .object(["maxAttempts": .integer(1)])], workingDirectory: root)
    let service = VideoTranscribeService(runner: runner, workingDirectory: root, artifactRoot: root,
      http: { _ in .init(status: 200, body: Data("{\"text\":\"fixture transcript\"}".utf8), retryAfter: nil) })
    let payload = try await service.collect(options: options, apiKey: "test-secret", baseURL: "https://example.test", deadline: nil)
    guard case let .object(video)? = payload["videoTranscribe"], case let .array(batches)? = video["batches"] else {
      return XCTFail("invalid video-transcribe output shape")
    }
    XCTAssertEqual(video["status"], .string("completed"))
    XCTAssertEqual(video["durationSeconds"], .number(70))
    guard case let .object(frameSummary)? = video["frames"] else { return XCTFail("missing frame summary") }
    XCTAssertEqual(frameSummary["kept"], .integer(2))
    XCTAssertEqual(batches.count, 3)
    XCTAssertNil(payload["frames"])
    for item in batches {
      guard case let .object(batch) = item else { return XCTFail("batch was not an object") }
      XCTAssertEqual(batch["transcript"], .string("fixture transcript"))
      XCTAssertNotNil(batch["imagePaths"])
    }
    guard case let .object(firstBatch) = batches[0], case let .array(firstFrames)? = firstBatch["frames"],
      case let .object(firstFrame)? = firstFrames.first,
      case let .object(secondBatch) = batches[1], case let .array(secondFrames)? = secondBatch["frames"],
      case let .object(changedFrame)? = secondFrames.first,
      case let .object(lastBatch) = batches[2], case let .array(lastFrames)? = lastBatch["frames"],
      case let .object(carriedFrame)? = lastFrames.first,
      let firstPath = firstFrame["path"]?.stringValue, let secondPath = changedFrame["path"]?.stringValue else { return XCTFail("expected sampled frames and carried frame context") }
    XCTAssertNotEqual(try Data(contentsOf: URL(fileURLWithPath: firstPath)), try Data(contentsOf: URL(fileURLWithPath: secondPath)))
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

private actor NetworkFailureCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

private struct ThrowingVideoTranscribeRunner: LocalProcessRunning {
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    throw VideoTranscribeTestError.unexpectedProcess
  }
}

private struct FixedResultVideoTranscribeRunner: LocalProcessRunning {
  let result: LocalProcessResult
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult { result }
}

private enum VideoTranscribeTestError: Error { case unexpectedHTTP, unexpectedProcess }
