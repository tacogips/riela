import Foundation
import RielaAdapters
import RielaCore
@testable import RielaServer
import XCTest

@testable import RielaCLI

final class MediaPipelineAddonTests: XCTestCase {
  func testMediaPipelineUnexpectedErrorKeepsRedactedDiagnostic() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-diagnostic-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = WorkflowAddonExecutionInput(
      workflowId: "media-diagnostic", stepId: "audio", nodeId: "audio",
      addon: .init(name: "riela/audio-segments", version: "1", config: [
        "options": .object(["path": .string("fixture.mp4")])
      ]), variables: [:])
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ["OPENAI_API_KEY": "secret-api-token"], workingDirectory: root)
    let pipeline = MediaPipelineContext(resolver: resolver, stage: "audio-segments")

    do {
      _ = try await pipeline.finish(input, .init()) { _, _ in
        throw NSError(domain: "fixture", code: 7, userInfo: [
          NSLocalizedDescriptionKey: "ffmpeg failed after receiving secret-api-token; Bearer abc123"
        ])
      }
      XCTFail("unexpected media pipeline errors should be surfaced")
    } catch let error as AdapterExecutionError {
      XCTAssertTrue(error.message.contains("audio-segments processing failed: ffmpeg failed"), error.message)
      XCTAssertTrue(error.message.contains("[REDACTED]"), error.message)
      XCTAssertFalse(error.message.contains("secret-api-token"), error.message)
      XCTAssertFalse(error.message.contains("abc123"), error.message)
    }
  }

  func testMediaPipelineRedactionRemovesCredentials() {
    let environment = ["OPENAI_API_KEY": "env-secret-value", "PATH": "/usr/bin"]
    let redact = { MediaPipelineRedaction.redact($0, environment: environment) }
    XCTAssertEqual(
      redact("GET https://user:pass@example.com/v1/x?sig=abc&token=def#frag failed"),
      "GET https://example.com/v1/x failed")
    XCTAssertEqual(redact("Authorization: Basic dXNlcjpwYXNz"), "Authorization: [REDACTED]")
    XCTAssertEqual(redact("header Basic dXNlcjpwYXNz end"), "header Basic [REDACTED] end")
    XCTAssertEqual(redact("using Bearer abc.def-123"), "using Bearer [REDACTED]")
    XCTAssertEqual(redact("key sk-proj_ABCDEFGH1234 rejected"), "key [REDACTED] rejected")
    XCTAssertEqual(redact("OPENAI_API_KEY=plain123 set"), "OPENAI_API_KEY=[REDACTED] set")
    XCTAssertEqual(redact("sent env-secret-value upstream"), "sent [REDACTED] upstream")
    XCTAssertEqual(redact("ffmpeg: /usr/bin/ffmpeg exited"), "ffmpeg: /usr/bin/ffmpeg exited")
  }

  func testMediaPipelineStageErrorIsRedacted() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-stage-redaction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = WorkflowAddonExecutionInput(
      workflowId: "media-redaction", stepId: "stt", nodeId: "stt",
      addon: .init(name: "riela/speech-to-text", version: "1", config: [
        "options": .object(["path": .string("a.mp3")])
      ]), variables: [:])
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ["OPENAI_API_KEY": "secret-api-token"], workingDirectory: root)
    let pipeline = MediaPipelineContext(resolver: resolver, stage: "speech-to-text")
    do {
      _ = try await pipeline.finish(input, .init()) { _, _ in
        throw MediaPipelineError.stage(
          "stt", "POST https://u:p@api.example.com/v1/audio?key=q secret-api-token Bearer zzz")
      }
      XCTFail("stage errors should be surfaced")
    } catch let error as AdapterExecutionError {
      XCTAssertTrue(error.message.contains("https://api.example.com/v1/audio"), error.message)
      for leaked in ["u:p@", "key=q", "secret-api-token", "zzz"] {
        XCTAssertFalse(error.message.contains(leaked), error.message)
      }
    }
  }

  func testAudioSegmentsVideoFramesSpeechToTextRejectMissingRequiredOptions() async throws {
    let options: [(String, String)] = [
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

  func testAudioSegmentsVideoFramesSpeechToTextAreRegistered() {
    let names = Set(BuiltinStatefulAddonRegistry.registrations.map(\.name))
    XCTAssertTrue(
      names.isSuperset(of: ["riela/audio-segments", "riela/video-frames", "riela/speech-to-text"]))
    XCTAssertFalse(names.contains("riela/video-transcribe"))
    XCTAssertFalse(names.contains("riela/media-download"))
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

  func testSpeechToTextBlankLanguageLetsProviderDetectIt() async throws {
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
    let output = try await resolver.execute(
      mediaSpeechInput(config: ["options": .object(["path": .string(audio.path), "language": .string(" ")])]),
      context: .init())
    XCTAssertEqual(speechToTextFields(output)?["language"], .null)
    let bodies = await transport.bodies
    XCTAssertEqual(bodies.count, 1)
    XCTAssertFalse(bodies[0].contains("name=\"language\""))
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
    let audioOnlyFramesDir = root.appendingPathComponent("audio-only-frames", isDirectory: true)
    let audioOnlyFramesInput = WorkflowAddonExecutionInput(
      workflowId: "media", stepId: "frames", nodeId: "frames",
      addon: .init(name: "riela/video-frames", version: "1", config: ["options": .object([
        "path": .string(media.path), "outputDir": .string(audioOnlyFramesDir.path),
        "ffprobePath": .string("/mock/ffprobe"), "ffmpegPath": .string("/mock/ffmpeg")
      ])]), variables: [:])
    let zeroFrames = try await audioOnlyResolver.execute(audioOnlyFramesInput, context: .init())
    guard let zeroFields = videoFramesFields(zeroFrames),
      case .integer(0)? = zeroFields["sampled"], case .array(let frames)? = zeroFields["frames"]
    else { return XCTFail("audio-only input should produce zero sampled frames") }
    XCTAssertTrue(frames.isEmpty)
    XCTAssertEqual(zeroFields["sourcePath"], .string(media.standardizedFileURL.path))
    try stripVideoFramesSourcePath(
      manifest: audioOnlyFramesDir.appendingPathComponent("video-frames-manifest.json"))
    let replayed = try await audioOnlyResolver.execute(audioOnlyFramesInput, context: .init())
    XCTAssertEqual(videoFramesFields(replayed)?["cached"], .bool(true))
    XCTAssertEqual(
      videoFramesFields(replayed)?["sourcePath"], .string(media.standardizedFileURL.path),
      "a cache replay of a manifest without sourcePath must still return it")

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
  private(set) var bodies: [String] = []
  func send(_ request: URLRequest) -> MediaPipelineHTTPResponse {
    count += 1
    timeouts.append(request.timeoutInterval)
    bodies.append(request.httpBody.flatMap { String(bytes: $0, encoding: .utf8) } ?? "")
    XCTAssertEqual(request.httpMethod, "POST")
    return .init(status: 200, body: Data("{\"text\":\"fixture transcript\"}".utf8), retryAfter: nil)
  }
}

private actor MediaPipelineRequestCounter {
  private(set) var count = 0
  func increment() { count += 1 }
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
    let artifactRoot = root.appendingPathComponent("artifact-store", isDirectory: true)
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ["OPENAI_API_KEY": "fake-key", "OPENAI_BASE_URL": baseURL],
      workingDirectory: root, containerProcessRunner: runner, artifactRootURL: artifactRoot)
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
        artifactRoot.appendingPathComponent("audio-segments/").path) == true)
    XCTAssertTrue(
      audioFields?["outputDir"]?.stringValue?.hasPrefix(
        artifactRoot.appendingPathComponent("audio-segments/").path) == true)
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
    let frameOutputDirectory = root.appendingPathComponent(".riela/artifacts/frames", isDirectory: true)
    try FileManager.default.createDirectory(at: frameOutputDirectory, withIntermediateDirectories: true)
    let staleFrame = frameOutputDirectory.appendingPathComponent("frame_9999.jpg")
    try Data("stale".utf8).write(to: staleFrame)
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
    XCTAssertFalse(FileManager.default.fileExists(atPath: staleFrame.path))
    XCTAssertEqual(videoFramesFields(framesOutput)?["sourcePath"], .string(clip.standardizedFileURL.path))
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
    XCTAssertEqual(videoFramesFields(cachedFrames)?["sourcePath"], .string(clip.standardizedFileURL.path))

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

private func videoFramesFields(_ output: AdapterExecutionOutput) -> JSONObject? {
  guard case .object(let fields)? = output.payload["videoFrames"] else { return nil }
  return fields
}

/// Rewrites a video-frames manifest the way builds before sourcePath existed wrote it.
private func stripVideoFramesSourcePath(manifest: URL) throws {
  var wrapper = try XCTUnwrap(
    JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
  var payload = try XCTUnwrap(wrapper["payload"] as? [String: Any])
  var frames = try XCTUnwrap(payload["videoFrames"] as? [String: Any])
  XCTAssertNotNil(frames.removeValue(forKey: "sourcePath"))
  payload["videoFrames"] = frames
  wrapper["payload"] = payload
  try JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys]).write(to: manifest)
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
  func testMediaStageOutputDirectoryCannotBeWorkingRootOrHome() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-output-safety-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("input.mp4")
    try Data("input".utf8).write(to: media)
    let resolver = BuiltinWorkflowAddonResolver(workingDirectory: root)
    for outputDirectory in [".", NSHomeDirectory()] {
      do {
        _ = try await resolver.execute(
          WorkflowAddonExecutionInput(
            workflowId: "media-output-safety", stepId: "frames", nodeId: "frames",
            addon: .init(name: "riela/video-frames", version: "1", config: [
              "options": .object([
                "path": .string(media.path), "outputDir": .string(outputDirectory)
              ])
            ]), variables: [:]), context: .init())
        XCTFail("unsafe outputDir should be rejected: \(outputDirectory)")
      } catch let error as AdapterExecutionError {
        XCTAssertTrue(error.message.contains("outputDir must not be"), error.message)
      }
    }
  }

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
