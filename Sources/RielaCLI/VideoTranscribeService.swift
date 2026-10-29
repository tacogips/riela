import Foundation
import RielaAdapters
import RielaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct VideoTranscribeHTTPResponse: Sendable { let status: Int; let body: Data; let retryAfter: Double? }
typealias VideoTranscribeHTTP = @Sendable (URLRequest) async throws -> VideoTranscribeHTTPResponse

let videoTranscribeNativeHTTP: VideoTranscribeHTTP = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as? HTTPURLResponse
    return .init(status: http?.statusCode ?? 0, body: data,
      retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
}

struct VideoTranscribeService: Sendable {
  let runner: any LocalProcessRunning
  let workingDirectory: URL
  let artifactRoot: URL
  let http: VideoTranscribeHTTP
  private var fileManager: FileManager { .default }
  private let outputLimit = 8_000_000

  func collect(options: VideoTranscribeOptions, apiKey: String, baseURL: String, deadline: Date?) async throws -> JSONObject {
    let sourceInfo = try await resolveSource(options, deadline: deadline)
    guard sourceInfo.duration <= options.maxDurationSeconds else { throw VideoTranscribeError.stage("metadata", "duration exceeds maxDurationSeconds") }
    let output = options.outputDirectory ?? artifactRoot.appendingPathComponent("video-transcribe", isDirectory: true)
      .appendingPathComponent(sourceInfo.videoID ?? String(webCollectionKey(sourceInfo.identity).prefix(24)), isDirectory: true)
    let absoluteOutput = output.path.hasPrefix("/") ? output.standardizedFileURL : workingDirectory.appendingPathComponent(output.path).standardizedFileURL
    let fingerprint = try optionsFingerprint(options)
    let manifestURL = absoluteOutput.appendingPathComponent("manifest.json")
    if options.cache, let cached = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONSerialization.jsonObject(with: cached) as? [String: Any],
      manifest["status"] as? String == "completed", manifest["optionsFingerprint"] as? String == fingerprint,
      let payload = manifest["payload"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: payload),
      let object = try? JSONDecoder().decode(JSONValue.self, from: data), case let .object(value) = object {
      var payload = value
      if case var .object(video)? = payload["videoTranscribe"] {
        video["cached"] = .bool(true)
        payload["videoTranscribe"] = .object(video)
      }
      return payload
    }
    try fileManager.createDirectory(at: absoluteOutput, withIntermediateDirectories: true)
    let mediaDirectory = absoluteOutput.appendingPathComponent("media", isDirectory: true)
    let chunksDirectory = absoluteOutput.appendingPathComponent("chunks", isDirectory: true)
    let framesDirectory = absoluteOutput.appendingPathComponent("frames", isDirectory: true)
    try [mediaDirectory, chunksDirectory, framesDirectory].forEach { try fileManager.createDirectory(at: $0, withIntermediateDirectories: true) }
    let mediaURL: URL
    if let local = sourceInfo.localPath { mediaURL = local } else { mediaURL = try await download(options, sourceInfo: sourceInfo, mediaDirectory: mediaDirectory, deadline: deadline) }
    let ffmpeg = try executable(options.ffmpegPath, name: "ffmpeg", stage: "audio")
    let ffprobe = try executable(options.ffprobePath, name: "ffprobe", stage: "audio")
    let duration = try await probeDuration(ffprobe, mediaURL: mediaURL, deadline: deadline)
    guard duration <= options.maxDurationSeconds else { throw VideoTranscribeError.stage("metadata", "duration exceeds maxDurationSeconds") }
    let audioURL = absoluteOutput.appendingPathComponent("audio.mp3")
    _ = try await run(ffmpeg, ["-y", "-i", mediaURL.path, "-vn", "-ac", "1", "-ar", "16000", "-b:a", "48k", audioURL.path], stage: "audio", deadline: deadline)
    let silenceResult = try await run(ffmpeg, ["-i", mediaURL.path, "-af", "silencedetect=noise=-35dB:d=0.4", "-f", "null", "-"], stage: "silence", deadline: deadline)
    let batchPlan = VideoTranscribeMediaLogic.batches(duration: duration, target: options.batchSeconds,
      silences: VideoTranscribeMediaLogic.silences(stderr: silenceResult.stderr))
    let chunkURLs = try await makeChunks(ffmpeg: ffmpeg, audioURL: audioURL, batches: batchPlan, directory: chunksDirectory, deadline: deadline)
    let transcripts = try await transcribe(chunkURLs, options: options, apiKey: apiKey, baseURL: baseURL,
      directory: chunksDirectory, deadline: deadline)
    let keptFrames = try await extractFrames(ffmpeg: ffmpeg, mediaURL: mediaURL, options: options, directory: framesDirectory, deadline: deadline)
    let assigned = VideoTranscribeMediaLogic.framesByBatch(keptFrames.frames, batches: batchPlan, carryForward: options.carryForwardFrame)
    var batches: [JSONValue] = []
    for index in batchPlan.indices {
      let frameItems = assigned[index].map { frame, carried in
        JSONValue.object(["timeSeconds": .number(frame.time), "path": .string(frame.path), "kind": .string("image"),
          "mediaType": .string("image/jpeg"), "carried": .bool(carried)])
      }
      batches.append(.object(["index": .integer(Int64(index)), "startSeconds": .number(batchPlan[index].start),
        "endSeconds": .number(batchPlan[index].end), "transcript": .string(transcripts[index]), "frames": .array(frameItems),
        "imagePaths": .array(assigned[index].map { .string($0.0.path) })]))
    }
    let source: JSONObject = ["url": sourceInfo.url.map(JSONValue.string) ?? .null, "videoId": sourceInfo.videoID.map(JSONValue.string) ?? .null,
      "title": .string(sourceInfo.title), "path": sourceInfo.localPath.map { .string($0.path) } ?? .null]
    let sttPayload: JSONObject = ["provider": .string("openai"), "model": .string(options.model),
      "language": options.language.map(JSONValue.string) ?? .null]
    let framePayload: JSONObject = ["intervalSeconds": .number(options.frameInterval),
      "dedupeThreshold": .number(options.frameDedupeThreshold), "sampled": .integer(Int64(keptFrames.sampled)),
      "kept": .integer(Int64(keptFrames.frames.count))]
    let videoPayload: JSONObject = ["status": .string("completed"), "source": .object(source),
      "durationSeconds": .number(duration), "outputDir": .string(absoluteOutput.path),
      "transcriptPath": .string(absoluteOutput.appendingPathComponent("transcript.json").path),
      "stt": .object(sttPayload), "frames": .object(framePayload), "batches": .array(batches), "cached": .bool(false)]
    let payload: JSONObject = ["videoTranscribe": .object(videoPayload)]
    guard try JSONEncoder().encode(JSONValue.object(payload)).count <= outputLimit else {
      throw AdapterExecutionError(.invalidInput, "video-transcribe output exceeds 8 MB")
    }
    let transcriptURL = absoluteOutput.appendingPathComponent("transcript.json")
    try JSONEncoder().encode(JSONValue.object(payload)).write(to: transcriptURL, options: .atomic)
    let manifest: [String: Any] = ["status": "completed", "optionsFingerprint": fingerprint,
      "payload": try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(payload)))]
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
    if !options.keepMedia {
      try? fileManager.removeItem(at: audioURL)
      if sourceInfo.localPath == nil { try? fileManager.removeItem(at: mediaURL) }
      for chunk in chunkURLs { try? fileManager.removeItem(at: chunk) }
    }
    return payload
  }

  func optionsFingerprint(_ options: VideoTranscribeOptions) throws -> String {
    let source: String
    switch options.source {
    case let .url(url): source = url.absoluteString
    case let .path(url): source = url.path
    }
    let effectiveOptions: JSONValue = .object(["source": .string(source), "frameInterval": .number(options.frameInterval),
      "frameDedupeThreshold": .number(options.frameDedupeThreshold), "frameWidth": .integer(Int64(options.frameWidth)),
      "batchSeconds": .number(options.batchSeconds), "language": options.language.map(JSONValue.string) ?? .null,
      "sttPrompt": options.sttPrompt.map(JSONValue.string) ?? .null, "model": .string(options.model),
      "concurrency": .integer(Int64(options.concurrency)), "maxAttempts": .integer(Int64(options.maxAttempts)),
      "maxDurationSeconds": .number(options.maxDurationSeconds), "keepMedia": .bool(options.keepMedia),
      "carryForwardFrame": .bool(options.carryForwardFrame), "outputDir": options.outputDirectory.map { .string($0.path) } ?? .null,
      "ytDlpPath": options.ytDlpPath.map(JSONValue.string) ?? .null, "ffmpegPath": options.ffmpegPath.map(JSONValue.string) ?? .null,
      "ffprobePath": options.ffprobePath.map(JSONValue.string) ?? .null, "cache": .bool(options.cache)])
    return JSONCanonical.sha256Hex(try JSONCanonical.encode(effectiveOptions))
  }

  func run(_ executable: URL, _ arguments: [String], stage: String, deadline: Date?) async throws -> LocalProcessResult {
    do {
      let result = try await runner.run(configuration: .init(executableURL: executable, arguments: arguments,
        workingDirectoryURL: workingDirectory, stdoutCaptureByteLimit: 2_000_000, stderrCaptureByteLimit: 2_000_000), stdin: "", deadline: deadline)
      guard result.terminationStatus == 0 else { throw VideoTranscribeError.stage(stage, "process exited with status \(result.terminationStatus)") }
      return result
    } catch let error as VideoTranscribeError { throw error } catch { throw VideoTranscribeError.stage(stage, "process could not run") }
  }

  private func executable(_ override: String?, name: String, stage: String) throws -> URL {
    if let override { return URL(fileURLWithPath: override) }
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin").split(separator: ":")
    if let path = paths.map({ URL(fileURLWithPath: String($0)).appendingPathComponent(name) }).first(where: { fileManager.isExecutableFile(atPath: $0.path) }) { return path }
    throw VideoTranscribeError.stage(stage, "\(name) is missing; install with brew install yt-dlp ffmpeg")
  }

  private func probeDuration(_ ffprobe: URL, mediaURL: URL, deadline: Date?) async throws -> Double {
    let result = try await run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "json", mediaURL.path], stage: "audio", deadline: deadline)
    guard let data = result.stdout.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let format = root["format"] as? [String: Any], let text = format["duration"] as? String, let value = Double(text), value > 0 else {
      throw VideoTranscribeError.stage("audio", "could not read media duration")
    }
    return value
  }

  private func resolveSource(_ options: VideoTranscribeOptions, deadline: Date?) async throws -> VideoSourceInfo {
    switch options.source {
    case let .path(path):
      var isDirectory = ObjCBool(false)
      guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw VideoTranscribeError.stage("metadata", "local media file does not exist or is a directory")
      }
      return .init(identity: path.path, videoID: nil, title: path.deletingPathExtension().lastPathComponent, url: nil, localPath: path, duration: 0)
    case let .url(url):
      let ytdlp = try executable(options.ytDlpPath, name: "yt-dlp", stage: "metadata")
      let result = try await run(ytdlp, ["-J", "--no-playlist", url.absoluteString], stage: "metadata", deadline: deadline)
      guard let data = result.stdout.data(using: .utf8), let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw VideoTranscribeError.stage("metadata", "invalid yt-dlp metadata")
      }
      let liveStatus = info["live_status"] as? String
      guard (info["is_live"] as? Bool) != true, liveStatus != "is_live", liveStatus != "is_upcoming" else {
        throw VideoTranscribeError.stage("metadata", "live and upcoming streams are not supported")
      }
      let duration = info["duration"] as? Double ?? 0
      guard duration > 0, duration <= options.maxDurationSeconds else { throw VideoTranscribeError.stage("metadata", "video duration is missing or exceeds maxDurationSeconds") }
      return .init(identity: url.absoluteString, videoID: info["id"] as? String, title: info["title"] as? String ?? "Video",
        url: url.absoluteString, localPath: nil, duration: duration)
    }
  }

  private func download(_ options: VideoTranscribeOptions, sourceInfo: VideoSourceInfo, mediaDirectory: URL, deadline: Date?) async throws -> URL {
    guard case let .url(url) = options.source else { throw VideoTranscribeError.stage("download", "missing URL") }
    let ytdlp = try executable(options.ytDlpPath, name: "yt-dlp", stage: "download")
    let template = mediaDirectory.appendingPathComponent("%(id)s.%(ext)s").path
    _ = try await run(ytdlp, ["--no-playlist", "-f", "bv*[height<=720][ext=mp4]+ba[ext=m4a]/b[height<=720]/b", "--merge-output-format", "mp4", "-o", template, url.absoluteString], stage: "download", deadline: deadline)
    let candidates = try fileManager.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)
    guard let media = candidates.first(where: { $0.lastPathComponent.hasPrefix(sourceInfo.videoID ?? "") }) else {
      throw VideoTranscribeError.stage("download", "yt-dlp did not produce a media file")
    }
    return media
  }
}

private struct VideoSourceInfo: Sendable {
  let identity: String; let videoID: String?; let title: String; let url: String?; let localPath: URL?; let duration: Double
}
