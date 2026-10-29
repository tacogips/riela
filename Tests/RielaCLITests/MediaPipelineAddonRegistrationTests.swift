import Foundation
import RielaAdapters
import RielaCore
@testable import RielaServer
import XCTest

@testable import RielaCLI

final class MediaPipelineAddonTests: XCTestCase {
  func testMediaDownloadWritesOutputAndCachesByOptions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-download-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = MediaDownloadProcessFixture()
    let resolver = BuiltinWorkflowAddonResolver(
      environment: [:], workingDirectory: root, containerProcessRunner: runner)
    let base: JSONObject = [
      "url": .string("https://www.youtube.com/watch?v=fixture&t=482s"),
      "outputDir": .string(".riela/artifacts/download"),
      "ytDlpPath": .string("/mock/yt-dlp"), "ffmpegPath": .string("/mock/ffmpeg")
    ]
    func execute(_ options: JSONObject) async throws -> AdapterExecutionOutput {
      try await resolver.execute(
        WorkflowAddonExecutionInput(
          workflowId: "media-download-test", stepId: "download", nodeId: "download",
          addon: .init(name: "riela/media-download", version: "1", config: ["options": .object(options)]),
          variables: [:]), context: .init())
    }
    let first = try await execute(base)
    XCTAssertEqual(mediaDownloadFields(first)?["status"], .string("downloaded"))
    XCTAssertEqual(mediaDownloadFields(first)?["cached"], .bool(false))
    let second = try await execute(base)
    XCTAssertEqual(mediaDownloadFields(second)?["cached"], .bool(true))
    let nonOutputChange = try await execute(base.merging([
      "maxDurationSeconds": .integer(600), "allowedHosts": .array([.string("youtube.com")]),
      "ytDlpPath": .string("/missing/yt-dlp"), "ffmpegPath": .string("/missing/ffmpeg")
    ]) { _, new in new })
    XCTAssertEqual(mediaDownloadFields(nonOutputChange)?["cached"], .bool(true))
    let changed = try await execute(base.merging(["format": .string("best")]) { _, new in new })
    XCTAssertEqual(mediaDownloadFields(changed)?["cached"], .bool(false))
    let calls = await runner.calls
    XCTAssertEqual(calls, 4, "a cache hit must not invoke yt-dlp")
    let downloaded = root.appendingPathComponent(".riela/artifacts/download/video.mp4")
    XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.path))
    let stale = root.appendingPathComponent(".riela/artifacts/download/video.webm")
    try Data("stale video".utf8).write(to: stale)
    _ = try await execute(base.merging(["format": .string("audio only")]) { _, new in new })
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    let configurations = await runner.configurations
    XCTAssertTrue(configurations.allSatisfy { $0.arguments.contains("--cache-dir") })
    XCTAssertTrue(configurations.allSatisfy { $0.environment["PATH"] != nil })
  }

  func testMediaDownloadFailureNamesStageAndRedactsStderr() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-download-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = MediaDownloadProcessFixture(failDownload: true)
    let manifest = root.appendingPathComponent(".riela/artifacts/download/media-download-manifest.json")
    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old manifest".utf8).write(to: manifest)
    let resolver = BuiltinWorkflowAddonResolver(
      environment: [:], workingDirectory: root, containerProcessRunner: runner)
    do {
      _ = try await resolver.execute(
        WorkflowAddonExecutionInput(
          workflowId: "media-download-test", stepId: "download", nodeId: "download",
          addon: .init(name: "riela/media-download", version: "1", config: ["options": .object([
            "url": .string("https://example.com/video"),
            "outputDir": .string(".riela/artifacts/download"),
            "ytDlpPath": .string("/mock/yt-dlp"), "ffmpegPath": .string("/mock/ffmpeg")
          ])]), variables: [:]), context: .init())
      XCTFail("download process failure should be reported")
    } catch let error as AdapterExecutionError {
      XCTAssertTrue(error.message.contains("media-download download failed"), error.message)
      XCTAssertTrue(error.message.contains("[REDACTED]"), error.message)
      XCTAssertFalse(error.message.contains("secret-token"), error.message)
      XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
    }
  }

  func testMediaDownloadAllowsOriginalShortLinkHostAndUsesURLScopedDefaultFolder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-short-link-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = MediaDownloadProcessFixture()
    let resolver = BuiltinWorkflowAddonResolver(
      environment: [:], workingDirectory: root, containerProcessRunner: runner)
    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "media", stepId: "download", nodeId: "download",
        addon: .init(name: "riela/media-download", version: "1", config: ["options": .object([
          "url": .string("https://youtu.be/fixture"),
          "allowedHosts": .array([.string("youtu.be")]),
          "ytDlpPath": .string("/mock/yt-dlp"), "ffmpegPath": .string("/mock/ffmpeg")
        ])]), variables: [:]), context: .init())
    guard let fields = mediaDownloadFields(output),
      let directory = fields["outputDir"]?.stringValue
    else { return XCTFail("download should accept the allowed original short-link host") }
    XCTAssertTrue(directory.hasPrefix(root.appendingPathComponent(".riela/artifacts/media-download/").path))
    XCTAssertTrue(URL(fileURLWithPath: directory).lastPathComponent.allSatisfy {
      $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
    })
    let processCalls = await runner.calls
    XCTAssertEqual(processCalls, 2)
  }

  func testMediaDownloadAudioSegmentsVideoFramesSpeechToTextRejectMissingRequiredOptions() async throws {
    let options: [(String, String)] = [
      ("riela/media-download", "url"),
      ("riela/audio-segments", "path"),
      ("riela/video-frames", "path"),
      ("riela/speech-to-text", "path")
    ]
    for (name, option) in options {
      let input = WorkflowAddonExecutionInput(
        workflowId: "media", stepId: "stage", nodeId: "stage",
        addon: .init(name: name, version: "1", config: ["options": .object([:])]), variables: [:])
      do {
        _ = try await BuiltinWorkflowAddonResolver(environment: [:])
          .executeStatefulAddonIfSupported(input, context: .init())
        XCTFail("\(name) should require \(option)")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .invalidInput)
        XCTAssertTrue(error.message.contains(option), error.message)
      }
    }
  }

  func testMediaDownloadAudioSegmentsVideoFramesSpeechToTextAreRegistered() {
    let names = Set(BuiltinStatefulAddonRegistry.registrations.map(\.name))
    XCTAssertTrue(
      names.isSuperset(of: [
        "riela/media-download", "riela/audio-segments", "riela/video-frames",
        "riela/speech-to-text"
      ]))
    XCTAssertFalse(names.contains("riela/video-transcribe"))
  }
}

extension MediaPipelineAddonTests {
  func testSpeechToTextUsesTransportAndCachesTranscriptByOptionsAndFileMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-stt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("segment.mp3")
    try Data("fixture audio bytes".utf8).write(to: audio)
    let transport = MediaPipelineHTTPFixture()
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ["OPENAI_API_KEY": "fake-key"], workingDirectory: root,
      mediaPipelineHTTP: { request in await transport.send(request) })
    let config: JSONObject = [
      "options": .object([
        "path": .string(audio.path), "language": .string("ja"), "timeoutSeconds": .integer(12)
      ])
    ]
    let first = try await resolver.execute(mediaSpeechInput(config: config), context: .init())
    XCTAssertEqual(speechToTextFields(first)?["cached"], .bool(false))
    XCTAssertEqual(speechToTextFields(first)?["text"], .string("fixture transcript"))
    let second = try await resolver.execute(mediaSpeechInput(config: config), context: .init())
    XCTAssertEqual(speechToTextFields(second)?["cached"], .bool(true))
    let afterCacheHit = await transport.count
    XCTAssertEqual(afterCacheHit, 1)
    let changed = try await resolver.execute(
      mediaSpeechInput(config: [
        "options": .object([
          "path": .string(audio.path), "language": .string("en"), "timeoutSeconds": .integer(12)
        ])
      ]), context: .init())
    XCTAssertEqual(speechToTextFields(changed)?["cached"], .bool(false))
    let afterOptionChange = await transport.count
    XCTAssertEqual(afterOptionChange, 2)
    let requestTimeouts = await transport.timeouts
    XCTAssertEqual(requestTimeouts, [12, 12])
  }

  func testSpeechToTextNamesUnsupportedProviderOption() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-provider-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("segment.mp3")
    try Data("audio".utf8).write(to: audio)
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ["OPENAI_API_KEY": "fake-key"], workingDirectory: root)
    do {
      _ = try await resolver.execute(
        mediaSpeechInput(config: [
          "options": .object(["path": .string(audio.path), "provider": .string("other")])
        ]), context: .init())
      XCTFail("unsupported providers should fail validation")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("provider"), error.message)
    }
  }

  func testSpeechToTextCacheIgnoresRetrySettingsButIncludesBaseURLAndContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-stt-cache-key-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("segment.mp3")
    try Data("aaaa".utf8).write(to: audio)
    let fixedModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: fixedModificationDate], ofItemAtPath: audio.path)
    let transport = MediaPipelineHTTPFixture()
    func resolver(_ baseURL: String) -> BuiltinWorkflowAddonResolver {
      BuiltinWorkflowAddonResolver(
        environment: ["OPENAI_API_KEY": "fake-key", "OPENAI_BASE_URL": baseURL],
        workingDirectory: root, mediaPipelineHTTP: { request in await transport.send(request) })
    }
    let config: JSONObject = ["options": .object(["path": .string(audio.path), "maxAttempts": .integer(1)])]
    _ = try await resolver("https://one.example.test").execute(mediaSpeechInput(config: config, baseURL: true), context: .init())
    let retryOnly: JSONObject = ["options": .object(["path": .string(audio.path), "maxAttempts": .integer(8), "timeoutSeconds": .integer(12)])]
    let hit = try await resolver("https://one.example.test").execute(mediaSpeechInput(config: retryOnly, baseURL: true), context: .init())
    XCTAssertEqual(speechToTextFields(hit)?["cached"], .bool(true))
    let secondBase = try await resolver("https://two.example.test").execute(mediaSpeechInput(config: config, baseURL: true), context: .init())
    XCTAssertEqual(speechToTextFields(secondBase)?["cached"], .bool(false))
    try Data("bbbb".utf8).write(to: audio)
    try FileManager.default.setAttributes([.modificationDate: fixedModificationDate], ofItemAtPath: audio.path)
    let changedContent = try await resolver("https://one.example.test").execute(mediaSpeechInput(config: config, baseURL: true), context: .init())
    XCTAssertEqual(speechToTextFields(changedContent)?["cached"], .bool(false))
    let count = await transport.count
    XCTAssertEqual(count, 3)
  }

  func testSpeechToTextCacheWriteFailureDoesNotDiscardPaidTranscript() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-stt-write-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("segment.mp3")
    try Data("audio".utf8).write(to: audio)
    try FileManager.default.createDirectory(atPath: audio.path + ".stt.json", withIntermediateDirectories: true)
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ["OPENAI_API_KEY": "fake-key"], workingDirectory: root,
      mediaPipelineHTTP: { _ in
        .init(status: 200, body: Data("{\"text\":\"paid transcript\"}".utf8), retryAfter: nil)
      })
    let output = try await resolver.execute(
      mediaSpeechInput(config: ["options": .object(["path": .string(audio.path)])]), context: .init())
    XCTAssertEqual(speechToTextFields(output)?["text"], .string("paid transcript"))
  }

  func testAudioWithoutStreamAndFrameTimeoutDoNotKeepOldManifests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-manifest-cleanup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("input.mp4")
    try Data("fixture".utf8).write(to: media)
    let audioDir = root.appendingPathComponent("audio", isDirectory: true)
    let audioManifest = audioDir.appendingPathComponent("audio-segments-manifest.json")
    try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: audioManifest)
    let resolver = BuiltinWorkflowAddonResolver(
      workingDirectory: root,
      containerProcessRunner: MediaProbeFixtureRunner(
        probe: #"{"streams":[{"codec_type":"video"}],"format":{"duration":"10"}}"#))
    do {
      _ = try await resolver.execute(
        WorkflowAddonExecutionInput(
          workflowId: "media", stepId: "audio", nodeId: "audio",
          addon: .init(name: "riela/audio-segments", version: "1", config: ["options": .object([
            "path": .string(media.path), "outputDir": .string(audioDir.path),
            "ffprobePath": .string("/mock/ffprobe"), "ffmpegPath": .string("/mock/ffmpeg")
          ])]), variables: [:]), context: .init())
      XCTFail("video without audio must fail")
    } catch let error as AdapterExecutionError {
      XCTAssertTrue(error.message.contains("no audio stream"), error.message)
      XCTAssertFalse(FileManager.default.fileExists(atPath: audioManifest.path))
    }

    let audioOnlyResolver = BuiltinWorkflowAddonResolver(
      workingDirectory: root,
      containerProcessRunner: MediaProbeFixtureRunner(
        probe: #"{"streams":[{"codec_type":"audio"}]}"#))
    let zeroFrames = try await audioOnlyResolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "media", stepId: "frames", nodeId: "frames",
        addon: .init(name: "riela/video-frames", version: "1", config: ["options": .object([
          "path": .string(media.path), "outputDir": .string(root.appendingPathComponent("audio-only-frames").path),
          "ffprobePath": .string("/mock/ffprobe"), "ffmpegPath": .string("/mock/ffmpeg")
        ])]), variables: [:]), context: .init())
    guard let zeroFields = videoFramesFields(zeroFrames),
      case .integer(0)? = zeroFields["sampled"], case .array(let frames)? = zeroFields["frames"]
    else { return XCTFail("audio-only input should produce zero sampled frames") }
    XCTAssertTrue(frames.isEmpty)

    let frameDir = root.appendingPathComponent("frames", isDirectory: true)
    let frameManifest = frameDir.appendingPathComponent("video-frames-manifest.json")
    try FileManager.default.createDirectory(at: frameDir, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: frameManifest)
    let timeoutResolver = BuiltinWorkflowAddonResolver(
      workingDirectory: root,
      containerProcessRunner: MediaProbeFixtureRunner(
        probe: #"{"streams":[{"codec_type":"video"}]}"#, timeoutOnExtraction: true))
    do {
      _ = try await timeoutResolver.execute(
        WorkflowAddonExecutionInput(
          workflowId: "media", stepId: "frames", nodeId: "frames",
          addon: .init(name: "riela/video-frames", version: "1", config: ["options": .object([
            "path": .string(media.path), "outputDir": .string(frameDir.path),
            "ffprobePath": .string("/mock/ffprobe"), "ffmpegPath": .string("/mock/ffmpeg")
          ])]), variables: [:]), context: .init())
      XCTFail("frame extraction timeout must propagate")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertFalse(FileManager.default.fileExists(atPath: frameManifest.path))
    }
  }
}

private func mediaSpeechInput(
  config: JSONObject, baseURL: Bool = false, variables: JSONObject = [:]
) -> WorkflowAddonExecutionInput {
  var environment: JSONObject = [
    "OPENAI_API_KEY": .object(["fromEnv": .string("OPENAI_API_KEY"), "required": .bool(true)])
  ]
  if baseURL { environment["OPENAI_BASE_URL"] = .object(["fromEnv": .string("OPENAI_BASE_URL")]) }
  return WorkflowAddonExecutionInput(
    workflowId: "media-test", stepId: "speech", nodeId: "speech",
    addon: .init(
      name: "riela/speech-to-text", version: "1", config: config, env: environment),
    variables: variables)
}

private func speechToTextFields(_ output: AdapterExecutionOutput) -> JSONObject? {
  guard case .object(let fields)? = output.payload["speechToText"] else { return nil }
  return fields
}

private actor MediaPipelineHTTPFixture {
  private(set) var count = 0
  private(set) var timeouts: [Double] = []
  func send(_ request: URLRequest) -> MediaPipelineHTTPResponse {
    count += 1
    timeouts.append(request.timeoutInterval)
    XCTAssertEqual(request.httpMethod, "POST")
    return .init(status: 200, body: Data("{\"text\":\"fixture transcript\"}".utf8), retryAfter: nil)
  }
}

private actor MediaPipelineRequestCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

private actor MediaDownloadProcessFixture: LocalProcessRunning {
  private(set) var calls = 0
  private(set) var configurations: [LocalProcessConfiguration] = []
  private let failDownload: Bool

  init(failDownload: Bool = false) {
    self.failDownload = failDownload
  }

  func run(
    configuration: LocalProcessConfiguration, stdin: String, deadline: Date?
  ) async throws -> LocalProcessResult {
    calls += 1
    configurations.append(configuration)
    if configuration.arguments.contains("-O") {
      return LocalProcessResult(
        stdout: #"{"id":"fixture","title":"Fixture video","duration":120,"is_live":false}"#,
        stderr: "", terminationStatus: 0)
    }
    if failDownload {
      return LocalProcessResult(
        stdout: "", stderr: "Bearer secret-token sk-12345678901234567890", terminationStatus: 1)
    }
    guard let outputIndex = configuration.arguments.firstIndex(of: "-o"),
      configuration.arguments.indices.contains(outputIndex + 1)
    else { return LocalProcessResult(stdout: "", stderr: "missing output template", terminationStatus: 2) }
    let path = configuration.arguments[outputIndex + 1]
      .replacingOccurrences(of: "%(ext)s", with: "mp4")
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture media".utf8).write(to: URL(fileURLWithPath: path))
    return LocalProcessResult(stdout: path + "\n", stderr: "", terminationStatus: 0)
  }
}

private struct MediaProbeFixtureRunner: LocalProcessRunning {
  let probe: String
  var timeoutOnExtraction = false
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws
    -> LocalProcessResult {
    if configuration.executableURL.path == "/mock/ffprobe" {
      return .init(stdout: probe, stderr: "", terminationStatus: 0)
    }
    if timeoutOnExtraction { throw AdapterExecutionError(.timeout, "fixture timeout") }
    throw MediaProbeFixtureError.unexpectedProcess
  }
}

private enum MediaProbeFixtureError: Error { case unexpectedProcess }

extension MediaPipelineAddonTests {
  func testAudioSegmentsVideoFramesSpeechToTextComposeOverGeneratedClip() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-compose-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    guard
      let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first(
        where: { FileManager.default.isExecutableFile(atPath: $0) })
    else {
      throw XCTSkip("ffmpeg is not installed")
    }
    let runner = FoundationLocalProcessRunner()
    let first = [
      "color=black:size=320x240:rate=10:duration=30",
      "drawbox=x=0:y=0:w=40:h=240:color=white:t=fill"
    ].joined(separator: ",")
    let second = [
      "color=black:size=320x240:rate=10:duration=40",
      "drawbox=x=240:y=0:w=40:h=240:color=white:t=fill"
    ].joined(separator: ",")
    let clip = root.appendingPathComponent("fixture.mp4")
    let generated = try await runner.run(
      configuration: .init(
        executableURL: URL(fileURLWithPath: ffmpeg),
        arguments: [
          "-y", "-f", "lavfi", "-i", first, "-f", "lavfi", "-i", second, "-f", "lavfi", "-i",
          "sine=frequency=440:sample_rate=44100:duration=70",
          "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]", "-map", "2:a", "-t",
          "70", "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", clip.path
        ], workingDirectoryURL: root), stdin: "", deadline: nil)
    XCTAssertEqual(generated.terminationStatus, 0, generated.stderr)

    let requests = MediaPipelineRequestCounter()
    let server = RielaLocalHTTPServer(routeHandler: AnyRielaHTTPRouteHandler { _ in
      await requests.increment()
      return .json(.object(["text": .string("fixture transcript")]))
    })
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let baseURL = "http://127.0.0.1:\(port)"
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ["OPENAI_API_KEY": "fake-key", "OPENAI_BASE_URL": baseURL],
      workingDirectory: root, containerProcessRunner: runner)
    let audioOutput = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "media-compose", stepId: "audio", nodeId: "audio",
        addon: .init(
          name: "riela/audio-segments", version: "1",
          config: [
            "options": .object([
              "path": .string("{{input.mediaDownload.path}}"), "segmentSeconds": .integer(30)
            ])
          ]), variables: [:], resolvedInputPayload: [
            "mediaDownload": .object(["path": .string("fixture.mp4")])
          ]), context: .init())
    let audioFields = audioSegmentsFields(audioOutput)
    XCTAssertEqual(audioFields?["status"], .string("completed"))
    XCTAssertEqual(audioFields?["sourcePath"], .string(clip.standardizedFileURL.path))
    XCTAssertTrue(
      audioFields?["outputDir"]?.stringValue?.hasPrefix(
        root.appendingPathComponent(".riela/artifacts/audio-segments/").path) == true)
    XCTAssertTrue(
      audioFields?["outputDir"]?.stringValue?.hasPrefix(
        root.appendingPathComponent(".riela/artifacts/audio-segments/").path) == true)
    let cachedAudio = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "media-compose", stepId: "audio", nodeId: "audio",
        addon: .init(
          name: "riela/audio-segments", version: "1",
          config: [
            "options": .object([
              "path": .string("{{input.mediaDownload.path}}"), "segmentSeconds": .integer(30)
            ])
          ]), variables: [:], resolvedInputPayload: [
            "mediaDownload": .object(["path": .string("fixture.mp4")])
          ]), context: .init())
    XCTAssertEqual(audioSegmentsFields(cachedAudio)?["cached"], .bool(true))
    guard case .array(let audioSegments)? = audioFields?["segments"], audioSegments.count == 3,
      audioFields?["sourcePath"]?.stringValue != nil
    else {
      return XCTFail("expected three audio segments")
    }
    let framesOutput = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "media-compose", stepId: "frames", nodeId: "frames",
        addon: .init(
          name: "riela/video-frames", version: "1",
          config: [
            "options": .object([
              "path": .string("{{input.audioSegments.sourcePath}}"), "intervalSeconds": .integer(40),
              "segments": .string("{{input.audioSegments.segments}}"), "outputDir": .string(".riela/artifacts/frames")
            ])
          ]), variables: [:], resolvedInputPayload: [
            "audioSegments": .object(try XCTUnwrap(audioFields))
          ]), context: .init())
    guard let videoFields = videoFramesFields(framesOutput),
      case .array(let flatFrames)? = videoFields["frames"],
      case .array(let attachedSegments)? = videoFields["segments"], attachedSegments.count == 3
    else { return XCTFail("expected sampled frames and three audio segment attachments") }
    XCTAssertFalse(
      flatFrames.contains {
        if case .object(let fields) = $0 {
          return fields["kind"] != nil || fields["mediaType"] != nil || fields["imagePaths"] != nil
        }
        return false
      })
    XCTAssertEqual(segmentCarried(attachedSegments[2]), true)
    let firstFrameData = try Data(
      contentsOf: URL(fileURLWithPath: try XCTUnwrap(framePath(attachedSegments[0]))))
    let changedFrameData = try Data(
      contentsOf: URL(fileURLWithPath: try XCTUnwrap(framePath(attachedSegments[2]))))
    XCTAssertNotEqual(firstFrameData, changedFrameData)
    let cachedFrames = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "media-compose", stepId: "frames", nodeId: "frames",
        addon: .init(
          name: "riela/video-frames", version: "1",
          config: [
            "options": .object([
              "path": .string("{{input.audioSegments.sourcePath}}"), "intervalSeconds": .integer(40),
              "segments": .string("{{input.audioSegments.segments}}"), "outputDir": .string(".riela/artifacts/frames")
            ])
          ]), variables: [:], resolvedInputPayload: [
            "audioSegments": .object(try XCTUnwrap(audioFields))
          ]), context: .init())
    XCTAssertEqual(videoFramesFields(cachedFrames)?["cached"], .bool(true))

    for item in attachedSegments {
      guard case .object = item else {
        return XCTFail("invalid audio segment")
      }
      let speech = try await resolver.execute(
        mediaSpeechInput(
          config: ["options": .object(["path": .string("{{segment.path}}")])],
          baseURL: true, variables: ["segment": item]),
        context: .init())
      XCTAssertEqual(speechToTextFields(speech)?["text"], .string("fixture transcript"))
      let prompt = renderPromptTemplate(
        "Transcript: {{speechToText.text}}\nFrames: {{segment.frames}}",
        variables: [
          "speechToText": .object(try XCTUnwrap(speechToTextFields(speech))), "segment": item
        ])
      XCTAssertTrue(prompt.contains("fixture transcript"))
      XCTAssertTrue(prompt.contains("image/jpeg"))
    }
    let requestCount = await requests.count
    XCTAssertEqual(requestCount, 3)
  }
}

private func audioSegmentsFields(_ output: AdapterExecutionOutput) -> JSONObject? {
  guard case .object(let fields)? = output.payload["audioSegments"] else { return nil }
  return fields
}

private func mediaDownloadFields(_ output: AdapterExecutionOutput) -> JSONObject? {
  guard case let .object(fields)? = output.payload["mediaDownload"] else { return nil }
  return fields
}

private func videoFramesFields(_ output: AdapterExecutionOutput) -> JSONObject? {
  guard case .object(let fields)? = output.payload["videoFrames"] else { return nil }
  return fields
}

private func segmentCarried(_ segment: JSONValue) -> Bool {
  guard case .object(let fields) = segment, case .array(let frames)? = fields["frames"],
    case .object(let frame)? = frames.first, case .bool(let carried)? = frame["carried"]
  else { return false }
  return carried
}

private func framePath(_ segment: JSONValue) -> String? {
  guard case .object(let fields) = segment, case .array(let frames)? = fields["frames"],
    case .object(let frame)? = frames.first
  else { return nil }
  return frame["path"]?.stringValue
}

extension MediaPipelineAddonTests {
  func testVideoFramesHandlesNTSCEndOfStreamSamples() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-ntsc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    guard
      let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first(
        where: { FileManager.default.isExecutableFile(atPath: $0) })
    else {
      throw XCTSkip("ffmpeg is not installed")
    }
    let runner = FoundationLocalProcessRunner()
    let clip = root.appendingPathComponent("ntsc.mp4")
    let generated = try await runner.run(
      configuration: .init(
        executableURL: URL(fileURLWithPath: ffmpeg),
        arguments: [
          "-y", "-f", "lavfi", "-i",
          "color=black:size=320x240:rate=30000/1001:duration=10,drawbox=x=0:y=0:w=40:h=240:color=white:t=fill",
          "-f", "lavfi", "-i",
          "color=black:size=320x240:rate=30000/1001:duration=10.02,drawbox=x=240:y=0:w=40:h=240:color=white:t=fill",
          "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=20.02",
          "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]", "-map", "2:a", "-t", "20.02",
          "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", clip.path
        ], workingDirectoryURL: root), stdin: "", deadline: nil)
    XCTAssertEqual(generated.terminationStatus, 0, generated.stderr)
    let resolver = BuiltinWorkflowAddonResolver(
      workingDirectory: root, containerProcessRunner: runner)
    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "ntsc", stepId: "frames", nodeId: "frames",
        addon: .init(
          name: "riela/video-frames", version: "1",
          config: [
            "options": .object([
              "path": .string(clip.path), "intervalSeconds": .integer(10),
              "outputDir": .string(".riela/artifacts/frames")
            ])
          ]), variables: [:]), context: .init())
    guard let fields = videoFramesFields(output), case .array(let frames)? = fields["frames"] else {
      return XCTFail("missing sampled frames")
    }
    guard case .integer(let sampled)? = fields["sampled"] else {
      return XCTFail("missing sampled count")
    }
    XCTAssertGreaterThanOrEqual(sampled, 2)
    XCTAssertGreaterThanOrEqual(frames.count, 2)
    for frame in frames {
      guard case .object(let value) = frame, let path = value["path"]?.stringValue else {
        return XCTFail("frame has no path")
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
  }
}
