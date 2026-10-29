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
    let changed = try await execute(base.merging(["format": .string("best")]) { _, new in new })
    XCTAssertEqual(mediaDownloadFields(changed)?["cached"], .bool(false))
    let calls = await runner.calls
    XCTAssertEqual(calls, 5, "metadata runs each time; download runs for both cache misses")
    let downloaded = root.appendingPathComponent(".riela/artifacts/download/video.mp4")
    XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.path))
  }

  func testMediaDownloadFailureNamesStageAndRedactsStderr() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-media-download-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = MediaDownloadProcessFixture(failDownload: true)
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
    }
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
}

private func mediaSpeechInput(config: JSONObject, baseURL: Bool = false) -> WorkflowAddonExecutionInput {
  var environment: JSONObject = [
    "OPENAI_API_KEY": .object(["fromEnv": .string("OPENAI_API_KEY"), "required": .bool(true)])
  ]
  if baseURL { environment["OPENAI_BASE_URL"] = .object(["fromEnv": .string("OPENAI_BASE_URL")]) }
  return WorkflowAddonExecutionInput(
    workflowId: "media-test", stepId: "speech", nodeId: "speech",
    addon: .init(
      name: "riela/speech-to-text", version: "1", config: config, env: environment), variables: [:])
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
  private let failDownload: Bool

  init(failDownload: Bool = false) {
    self.failDownload = failDownload
  }

  func run(
    configuration: LocalProcessConfiguration, stdin: String, deadline: Date?
  ) async throws -> LocalProcessResult {
    calls += 1
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
              "path": .string(clip.path), "segmentSeconds": .integer(30),
              "outputDir": .string(".riela/artifacts/audio")
            ])
          ]), variables: [:]), context: .init())
    let audioFields = audioSegmentsFields(audioOutput)
    XCTAssertEqual(audioFields?["status"], .string("completed"))
    let cachedAudio = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "media-compose", stepId: "audio", nodeId: "audio",
        addon: .init(
          name: "riela/audio-segments", version: "1",
          config: [
            "options": .object([
              "path": .string(clip.path), "segmentSeconds": .integer(30),
              "outputDir": .string(".riela/artifacts/audio")
            ])
          ]), variables: [:]), context: .init())
    XCTAssertEqual(audioSegmentsFields(cachedAudio)?["cached"], .bool(true))
    guard case .array(let audioSegments)? = audioFields?["segments"], audioSegments.count == 3,
      case .object(let firstAudio)? = audioSegments.first,
      let firstAudioPath = firstAudio["path"]?.stringValue,
      case .object(let secondAudio)? = audioSegments.last,
      let secondAudioPath = secondAudio["path"]?.stringValue
    else {
      return XCTFail("expected two audio segments")
    }
    let frameSegments: [JSONValue] = [
      .object([
        "index": .integer(0), "startSeconds": .number(0), "endSeconds": .number(5),
        "path": .string(firstAudioPath)
      ]),
      .object([
        "index": .integer(1), "startSeconds": .number(5), "endSeconds": .number(20),
        "path": .string(firstAudioPath)
      ]),
      .object([
        "index": .integer(2), "startSeconds": .number(20), "endSeconds": .number(40),
        "path": .string(firstAudioPath)
      ]),
      .object([
        "index": .integer(3), "startSeconds": .number(40), "endSeconds": .number(70),
        "path": .string(secondAudioPath)
      ])
    ]
    let framesOutput = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "media-compose", stepId: "frames", nodeId: "frames",
        addon: .init(
          name: "riela/video-frames", version: "1",
          config: [
            "options": .object([
              "path": .string(clip.path), "intervalSeconds": .integer(30),
              "segments": .array(frameSegments), "outputDir": .string(".riela/artifacts/frames")
            ])
          ]), variables: [:]), context: .init())
    guard let videoFields = videoFramesFields(framesOutput),
      case .array(let flatFrames)? = videoFields["frames"],
      case .array(let attachedSegments)? = videoFields["segments"], attachedSegments.count == 4
    else { return XCTFail("expected sampled frames and segment attachments") }
    XCTAssertFalse(
      flatFrames.contains {
        if case .object(let fields) = $0 {
          return fields["kind"] != nil || fields["mediaType"] != nil || fields["imagePaths"] != nil
        }
        return false
      })
    XCTAssertEqual(segmentCarried(attachedSegments[1]), true)
    XCTAssertEqual(segmentCarried(attachedSegments[3]), true)
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
              "path": .string(clip.path), "intervalSeconds": .integer(30),
              "segments": .array(frameSegments), "outputDir": .string(".riela/artifacts/frames")
            ])
          ]), variables: [:]), context: .init())
    XCTAssertEqual(videoFramesFields(cachedFrames)?["cached"], .bool(true))

    for item in audioSegments {
      guard case .object(let fields) = item, let path = fields["path"]?.stringValue else {
        return XCTFail("invalid audio segment")
      }
      let speech = try await resolver.execute(
        mediaSpeechInput(config: ["options": .object(["path": .string(path)])], baseURL: true),
        context: .init())
      XCTAssertEqual(speechToTextFields(speech)?["text"], .string("fixture transcript"))
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
