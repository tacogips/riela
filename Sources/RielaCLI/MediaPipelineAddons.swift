import Foundation
import RielaAdapters
import RielaAddonSupport
import RielaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private enum MediaPipelineStageError: Error {
  case option(String)
  case stage(String, String)
}
struct MediaPipelineContext: Sendable {
  let resolver: BuiltinWorkflowAddonResolver
  let stage: String
  var service: MediaPipelineService {
    .init(
      runner: resolver.containerProcessRunner, workingDirectory: resolver.workingDirectory,
      http: resolver.mediaPipelineHTTP, resolverEnvironment: resolver.environment)
  }
  func path(_ value: String) -> URL {
    (value.hasPrefix("/")
      ? URL(fileURLWithPath: value) : resolver.workingDirectory.appendingPathComponent(value))
      .standardizedFileURL
  }
  func outputDirectory(_ value: String?, stage: String) throws -> URL? {
    guard let value else { return nil }
    let output = path(value).resolvingSymlinksInPath().standardizedFileURL
    let workingRoot = resolver.workingDirectory.resolvingSymlinksInPath().standardizedFileURL
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    guard output != workingRoot, output != home else {
      throw MediaPipelineStageError.stage(
        stage, "outputDir must not be the working directory root or the user's home directory")
    }
    return output
  }
  var artifactDirectory: URL {
    (resolver.artifactRootURL ?? resolver.workingDirectory.appendingPathComponent(".riela/artifacts"))
      .appendingPathComponent("audio-segments", isDirectory: true)
  }
  func number(
    _ values: JSONObject, _ name: String, _ fallback: Double, _ range: ClosedRange<Double>
  ) throws -> Double {
    try MediaPipelineOptions.number(values, name, default: fallback, range: range)
  }
  func bool(_ values: JSONObject, _ name: String, _ fallback: Bool) throws -> Bool {
    guard let value = values[name] else { return fallback }
    guard case .bool(let result) = value else { throw MediaPipelineStageError.option(name) }
    return result
  }
  func string(_ values: JSONObject, _ name: String, _ fallback: String? = nil) throws -> String? {
    guard let value = values[name] else { return fallback }
    guard case .string(let result) = value else { throw MediaPipelineStageError.option(name) }
    return result
  }
  /// Stages whose providers take credentials or command overlays from addon.env.
  static let environmentStages: Set<String> = ["speech-to-text", "text-to-speech"]

  /// Renders the add-on config and runs `body`. `rawOptionKeys` name options
  /// that are passed through without workflow template rendering, such as a
  /// command argv whose `{{path}}` placeholders the stage fills itself.
  func finish(
    _ input: WorkflowAddonExecutionInput, _ context: AdapterExecutionContext,
    rawOptionKeys: Set<String> = [],
    whenLabels: (JSONObject) -> [String: Bool] = { _ in ["always": true] },
    _ body: (JSONObject, JSONObject) async throws -> JSONObject
  ) async throws -> AdapterExecutionOutput {
    do {
      var rawConfig = input.addon.config ?? [:]
      var preserved: JSONObject = [:]
      if case .object(var rawOptions)? = rawConfig["options"] {
        for key in rawOptionKeys {
          if let value = rawOptions.removeValue(forKey: key) { preserved[key] = value }
        }
        rawConfig["options"] = .object(rawOptions)
      }
      var templateInput = input
      templateInput.addon.config = rawConfig
      guard input.addon.version == nil || input.addon.version == "1",
        case .object(var config) = try renderAddonConfig(
          .object(rawConfig), variables: addonVariables(for: templateInput)),
        Set(config.keys).isSubset(of: ["options", "context"]),
        case .object(var options)? = config["options"],
        try JSONEncoder().encode(JSONValue.object(config)).count <= 8_000_000
      else { throw MediaPipelineStageError.option("options") }
      options.merge(preserved) { _, raw in raw }
      config["options"] = .object(options)
      if !Self.environmentStages.contains(stage), !(input.addon.env ?? [:]).isEmpty {
        throw AdapterExecutionError(.policyBlocked, "\(stage) does not accept addon.env values")
      }
      var payload = try await body(options, config)
      if let contextValue = config["context"] { payload["context"] = contextValue }
      guard try JSONEncoder().encode(JSONValue.object(payload)).count <= 8_000_000 else {
        throw AdapterExecutionError(.invalidInput, "\(stage) output exceeds 8 MB")
      }
      return .init(
        provider: "riela-builtin-addon", model: input.addon.name, promptText: "",
        completionPassed: true,
        when: whenLabels(payload), payload: payload)
    } catch is CancellationError { throw CancellationError() } catch let error
      as AdapterExecutionError { throw error } catch MediaPipelineStageError.option(let option) {
      throw AdapterExecutionError(.invalidInput, "invalid \(stage) option '\(option)'")
    } catch MediaPipelineStageError.stage(let name, let message) {
      throw AdapterExecutionError(.providerError, "\(stage) \(name) failed: \(redacted(message))")
    } catch MediaPipelineError.invalidOption(let option) {
      throw AdapterExecutionError(.invalidInput, "invalid \(stage) option '\(option)'")
    } catch MediaPipelineError.stage(let name, let message) {
      throw AdapterExecutionError(.providerError, "\(stage) \(name) failed: \(redacted(message))")
    } catch {
      let detail = safeDiagnostic(for: error)
      throw AdapterExecutionError(.providerError,
        detail.isEmpty ? "\(stage) processing failed" : "\(stage) processing failed: \(detail)")
    }
  }
  func cached(outputDir: URL, manifest: String, fingerprint: String, enabled: Bool) -> JSONObject? {
    let file = outputDir.appendingPathComponent(manifest)
    guard enabled, let data = try? Data(contentsOf: file),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["optionsFingerprint"] as? String == fingerprint,
      let payloadData = try? JSONSerialization.data(withJSONObject: object["payload"] ?? [:]),
      let value = try? JSONDecoder().decode(JSONValue.self, from: payloadData),
      case .object(var payload) = value,
      referencedFilesExist(value)
    else { return nil }
    for (key, child) in payload {
      if case .object(var node) = child {
        node["cached"] = .bool(true)
        payload[key] = .object(node)
      }
    }
    return payload
  }
  func save(_ payload: JSONObject, outputDir: URL, manifest: String, fingerprint: String) throws {
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let wrapper: [String: Any] = [
      "optionsFingerprint": fingerprint,
      "payload": try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(JSONValue.object(payload)))
    ]
    try JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys]).write(
      to: outputDir.appendingPathComponent(manifest), options: .atomic)
  }
  func fingerprint(_ value: JSONValue) throws -> String {
    JSONCanonical.sha256Hex(try JSONCanonical.encode(value))
  }
  private func referencedFilesExist(_ value: JSONValue) -> Bool {
    switch value {
    case .object(let object):
      return object.allSatisfy { key, child in
        if ["path", "audioPath", "sourcePath"].contains(key), case .string(let path) = child {
          return FileManager.default.fileExists(atPath: path)
        }
        if key == "imagePaths", case .array(let paths) = child {
          return paths.allSatisfy { path in
            guard case .string(let value) = path else { return false }
            return FileManager.default.fileExists(atPath: value)
          }
        }
        return referencedFilesExist(child)
      }
    case .array(let array): return array.allSatisfy(referencedFilesExist)
    default: return true
    }
  }

  func safeDiagnostic(for error: any Error) -> String {
    let message: String
    if type(of: error) == NSError.self {
      message = (error as NSError).localizedDescription
    } else {
      message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
    return redacted(message)
  }

  func redacted(_ message: String) -> String {
    MediaPipelineRedaction.diagnostic(message, environment: resolver.environment)
  }
}

extension BuiltinWorkflowAddonResolver {
  static let audioSegmentsRegistration = BuiltinAddonHandlerRegistration(
    name: "riela/audio-segments", bindsCLIVariablesAsInputs: false
  ) { resolver, input, context in
    try await MediaPipelineContext(resolver: resolver, stage: "audio-segments").finish(
      input, context
    ) { options, _ in
      try await resolver.audioSegments(options, deadline: context.deadline)
    }
  }
  static let videoFramesRegistration = BuiltinAddonHandlerRegistration(
    name: "riela/video-frames", bindsCLIVariablesAsInputs: false
  ) { resolver, input, context in
    try await MediaPipelineContext(resolver: resolver, stage: "video-frames").finish(input, context) { options, _ in
      try await resolver.videoFrames(options, deadline: context.deadline)
    }
  }
  static let speechToTextRegistration = BuiltinAddonHandlerRegistration(
    name: "riela/speech-to-text", bindsCLIVariablesAsInputs: false
  ) { resolver, input, context in
    try await MediaPipelineContext(resolver: resolver, stage: "speech-to-text").finish(
      input, context, rawOptionKeys: ["command"]
    ) { options, _ in
      try await resolver.speechToText(
        options, bindings: input.addon.env ?? [:], deadline: context.deadline)
    }
  }

  func audioSegments(_ values: JSONObject, deadline: Date?) async throws -> JSONObject {
    let c = MediaPipelineContext(resolver: self, stage: "audio-segments")
    let service = c.service
    guard let rawPath = try c.string(values, "path") else {
      throw MediaPipelineStageError.option("path")
    }
    let media = c.path(rawPath)
    guard FileManager.default.fileExists(atPath: media.path) else {
      throw MediaPipelineStageError.stage("audio", "input file does not exist")
    }
    let target = try c.number(values, "segmentSeconds", 180, 30...600)
    let noise = try c.number(values, "silenceNoiseDb", -35, -100...0)
    let silenceMin = try c.number(values, "silenceMinSeconds", 0.4, 0.05...10)
    let inputFileSize = Int64((try? media.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    let inputIdentity = String(
      try c.fingerprint(.object(["path": .string(media.path), "size": .integer(inputFileSize)])).prefix(24))
    let out = try c.outputDirectory(c.string(values, "outputDir"), stage: "audio-segments")
      ?? c.artifactDirectory.appendingPathComponent(inputIdentity, isDirectory: true)
    let fp = try c.fingerprint(
      .object([
        "path": .string(media.path),
        "size": .integer(Int64((try? media.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)),
        "mtime": .string(
          ((try? media.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast).description),
        "segmentSeconds": .number(target), "noise": .number(noise),
        "silenceMin": .number(silenceMin), "ffmpegPath": values["ffmpegPath"] ?? .null,
        "ffprobePath": values["ffprobePath"] ?? .null
      ]))
    let enabled = try c.bool(values, "cache", true)
    if let hit = c.cached(
      outputDir: out, manifest: "audio-segments-manifest.json", fingerprint: fp, enabled: enabled) {
      return hit
    }
    let ffmpeg = try service.executable(
      try c.string(values, "ffmpegPath"), name: "ffmpeg", stage: "audio")
    let ffprobe = try service.executable(
      try c.string(values, "ffprobePath"), name: "ffprobe", stage: "audio")
    let manifest = "audio-segments-manifest.json"
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: out.appendingPathComponent(manifest))
    let probe = try await service.run(
      ffprobe, ["-v", "error", "-show_entries", "stream=codec_type:format=duration", "-of", "json", media.path],
      stage: "audio", deadline: deadline)
    guard let probeData = probe.stdout.data(using: .utf8),
      let probeRoot = try JSONSerialization.jsonObject(with: probeData) as? [String: Any]
    else { throw MediaPipelineStageError.stage("audio", "could not inspect media streams") }
    guard let streams = probeRoot["streams"] as? [[String: Any]],
      streams.contains(where: { $0["codec_type"] as? String == "audio" })
    else { throw MediaPipelineStageError.stage("audio", "input media has no audio stream") }
    guard let format = probeRoot["format"] as? [String: Any], let rawDuration = format["duration"],
      let duration = (rawDuration as? NSNumber)?.doubleValue
        ?? (rawDuration as? String).flatMap(Double.init), duration > 0
    else { throw MediaPipelineStageError.stage("audio", "could not read media duration") }
    let audio = out.appendingPathComponent("audio.mp3")
    _ = try await service.run(
      ffmpeg,
      ["-y", "-i", media.path, "-vn", "-ac", "1", "-ar", "16000", "-b:a", "48k", audio.path],
      stage: "audio", deadline: deadline)
    let detected = try await service.run(
      ffmpeg,
      [
        "-nostats", "-i", audio.path, "-vn", "-af",
        "silencedetect=noise=\(noise)dB:d=\(silenceMin)", "-f", "null", "-"
      ], stage: "silence", deadline: deadline)
    let batches = MediaPipelineMediaLogic.batches(
      duration: duration, target: target,
      silences: MediaPipelineMediaLogic.silences(stderr: detected.stderr))
    var segments: [JSONValue] = []
    for (index, batch) in batches.enumerated() {
      let path = out.appendingPathComponent(String(format: "segment_%04d.mp3", index))
      _ = try await service.run(
        ffmpeg,
        [
          "-y", "-ss", String(format: "%.3f", batch.start), "-t",
          String(format: "%.3f", batch.end - batch.start), "-i", audio.path, "-ac", "1", "-ar",
          "16000", "-b:a", "48k", path.path
        ], stage: "audio", deadline: deadline)
      segments.append(
        .object([
          "index": .integer(Int64(index)), "startSeconds": .number(batch.start),
          "endSeconds": .number(batch.end), "path": .string(path.standardizedFileURL.path)
        ]))
    }
    let payload: JSONObject = [
      "audioSegments": .object([
        "status": .string("completed"), "durationSeconds": .number(duration),
        "audioPath": .string(audio.path), "sourcePath": .string(media.path),
        "segments": .array(segments),
        "outputDir": .string(out.path), "cached": .bool(false)
      ])
    ]
    try c.save(payload, outputDir: out, manifest: manifest, fingerprint: fp)
    return payload
  }

  func videoFrames(_ values: JSONObject, deadline: Date?) async throws -> JSONObject {
    let c = MediaPipelineContext(resolver: self, stage: "video-frames")
    let service = c.service
    guard let rawPath = try c.string(values, "path") else {
      throw MediaPipelineStageError.option("path")
    }
    let media = c.path(rawPath)
    guard FileManager.default.fileExists(atPath: media.path) else {
      throw MediaPipelineStageError.stage("frames", "input file does not exist")
    }
    let interval = try c.number(values, "intervalSeconds", 10, 1...600)
    let threshold = try c.number(values, "dedupeThreshold", 0.15, 0...1)
    let width = Int(try c.number(values, "width", 960, 2...7680))
    let carry = try c.bool(values, "carryForward", true)
    let attrs = try media.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let inputIdentity = String(try c.fingerprint(.object([
      "path": .string(media.path), "size": .integer(Int64(attrs.fileSize ?? 0))
    ])).prefix(24))
    let out = try c.outputDirectory(c.string(values, "outputDir"), stage: "video-frames")
      ?? (self.artifactRootURL ?? workingDirectory.appendingPathComponent(".riela/artifacts"))
        .appendingPathComponent("video-frames/\(inputIdentity)", isDirectory: true)
    var fingerprintOptions: JSONObject = [
      "path": .string(media.path), "size": .integer(Int64(attrs.fileSize ?? 0)),
      "mtime": .string((attrs.contentModificationDate ?? .distantPast).description),
      "interval": .number(interval), "threshold": .number(threshold),
      "width": .integer(Int64(width)), "carry": .bool(carry)
    ]
    if let segments = values["segments"] { fingerprintOptions["segments"] = segments }
    fingerprintOptions["ffmpegPath"] = values["ffmpegPath"] ?? .null
    fingerprintOptions["ffprobePath"] = values["ffprobePath"] ?? .null
    let fp = try c.fingerprint(.object(fingerprintOptions))
    let enabled = try c.bool(values, "cache", true)
    if var hit = c.cached(
      outputDir: out, manifest: "video-frames-manifest.json", fingerprint: fp, enabled: enabled) {
      // Manifests written before sourcePath existed are upgraded on replay.
      if case .object(var cachedFrames)? = hit["videoFrames"] {
        cachedFrames["sourcePath"] = .string(media.path)
        hit["videoFrames"] = .object(cachedFrames)
      }
      return hit
    }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let manifest = "video-frames-manifest.json"
    try? FileManager.default.removeItem(at: out.appendingPathComponent(manifest))
    for file in try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
      where file.lastPathComponent.hasPrefix("frame_") && file.pathExtension == "jpg" {
      try FileManager.default.removeItem(at: file)
    }
    let frameOptions = MediaFrameExtractionOptions(
      intervalSeconds: interval, dedupeThreshold: threshold, width: width)
    let ffmpeg = try service.executable(
      try c.string(values, "ffmpegPath"), name: "ffmpeg", stage: "frames")
    let ffprobe = try service.executable(
      try c.string(values, "ffprobePath"), name: "ffprobe", stage: "frames")
    let streamResult = try await service.run(
      ffprobe, ["-v", "error", "-show_entries", "stream=codec_type", "-of", "json", media.path],
      stage: "frames", deadline: deadline)
    guard let streamData = streamResult.stdout.data(using: .utf8),
      let streamRoot = try JSONSerialization.jsonObject(with: streamData) as? [String: Any],
      let streams = streamRoot["streams"] as? [[String: Any]]
    else { throw MediaPipelineStageError.stage("frames", "could not inspect media streams") }
    let hasVideo = streams.contains { $0["codec_type"] as? String == "video" }
    let extraction =
      hasVideo
      ? try await service.extractFrames(
        ffmpeg: ffmpeg, mediaURL: media, options: frameOptions, directory: out, deadline: deadline)
      : (frames: [MediaFrame](), sampled: 0)
    let frames = extraction.frames.map {
      JSONValue.object(["timeSeconds": .number($0.time), "path": .string($0.path)])
    }
    var result: JSONObject = [
      "status": .string("completed"), "intervalSeconds": .number(interval),
      "dedupeThreshold": .number(threshold), "sampled": .integer(Int64(extraction.sampled)),
      "kept": .integer(Int64(extraction.frames.count)), "frames": .array(frames),
      "outputDir": .string(out.path), "sourcePath": .string(media.path), "cached": .bool(false)
    ]
    if let rawSegments = values["segments"] {
      guard case .array(let inputSegments) = rawSegments else {
        throw MediaPipelineStageError.option("segments")
      }
      let decodedFrames = extraction.frames
      var outputSegments: [JSONValue] = []
      for segment in inputSegments {
        guard case .object(var fields) = segment, let start = mediaNumber(fields["startSeconds"]),
          let end = mediaNumber(fields["endSeconds"]), start < end
        else { throw MediaPipelineStageError.option("segments") }
        var selected = decodedFrames.filter { $0.time >= start && $0.time < end }.map {
          ($0, false)
        }
        if selected.isEmpty, carry, let prior = decodedFrames.last(where: { $0.time < start }) {
          selected = [(prior, true)]
        }
        fields["frames"] = .array(
          selected.map { frame, carried in
            .object([
              "timeSeconds": .number(frame.time), "path": .string(frame.path),
              "kind": .string("image"), "mediaType": .string("image/jpeg"),
              "carried": .bool(carried)
            ])
          })
        fields["imagePaths"] = .array(selected.map { .string($0.0.path) })
        outputSegments.append(.object(fields))
      }
      result["segments"] = .array(outputSegments)
    }
    let payload: JSONObject = ["videoFrames": .object(result)]
    try c.save(payload, outputDir: out, manifest: manifest, fingerprint: fp)
    return payload
  }

  func speechToText(_ values: JSONObject, bindings: JSONObject, deadline: Date?) async throws
    -> JSONObject {
    let c = MediaPipelineContext(resolver: self, stage: "speech-to-text")
    let service = c.service
    guard let rawPath = try c.string(values, "path") else {
      throw MediaPipelineStageError.option("path")
    }
    let audio = c.path(rawPath)
    guard let providerName = try c.string(values, "provider", "openai"),
      let provider = SpeechToTextProvider(rawValue: providerName)
    else { throw MediaPipelineStageError.option("provider") }
    let model = try c.string(values, "model", provider.defaultModel)
    // A blank language (for example an unset template value) lets the provider detect it.
    let language = try c.string(values, "language").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    let prompt = try c.string(values, "prompt")
    let attempts = Int(try c.number(values, "maxAttempts", 3, 1...8))
    let timeout = try c.number(values, "timeoutSeconds", 300, 1...3600)
    let onDevice = try c.bool(values, "onDevice", false)
    let argv = provider == .command ? try commandArgv(values["command"]) : []
    if provider != .command, values["command"] != nil {
      throw MediaPipelineStageError.option("command")
    }
    try validateSpeechEnvironment(
      bindings, stage: "speech-to-text", provider: provider.rawValue,
      allowed: provider.allowedEnvironment, allowsCommandPrefix: provider == .command)
    let data: Data
    if provider.isRemote {
      data = try SpeechAudioUpload.read(audio)
    } else {
      guard FileManager.default.fileExists(atPath: audio.path),
        let local = try? Data(contentsOf: audio, options: .mappedIfSafe)
      else { throw MediaPipelineStageError.stage("stt", "audio file is missing") }
      data = local
    }
    let env = try resolveAddonEnvironment(bindings, runtimeEnvironment: environment)
    var apiKey = ""
    if let keyName = provider.apiKeyName {
      guard let value = env[keyName], !value.isEmpty else {
        throw AdapterExecutionError(.policyBlocked, "speech-to-text requires addon.env.\(keyName)")
      }
      apiKey = value
    }
    let baseURL = provider.baseURLName.flatMap { env[$0] } ?? provider.defaultBaseURL
    var identity: JSONObject = [
      "provider": .string(provider.rawValue), "model": model.map(JSONValue.string) ?? .null,
      "language": language.map(JSONValue.string) ?? .null,
      "prompt": prompt.map(JSONValue.string) ?? .null,
      "contentSHA256": .string(JSONCanonical.sha256Hex(data))
    ]
    if let baseURL { identity["baseURL"] = .string(baseURL) }
    if provider == .command { identity["command"] = .array(argv.map(JSONValue.string)) }
    if provider == .apple { identity["onDevice"] = .bool(onDevice) }
    let cacheFile = URL(fileURLWithPath: audio.path + ".stt.json")
    let fingerprint = try c.fingerprint(.object(identity))
    func result(_ text: String, cached: Bool) -> JSONObject {
      [
        "speechToText": .object([
          "status": .string("completed"), "provider": .string(provider.rawValue),
          "model": model.map(JSONValue.string) ?? .null,
          "language": language.map(JSONValue.string) ?? .null, "text": .string(text),
          "path": .string(audio.path), "cached": .bool(cached)
        ])
      ]
    }
    let enabled = try c.bool(values, "cache", true)
    if enabled, let cached = try? Data(contentsOf: cacheFile),
      let object = try? JSONDecoder().decode(JSONValue.self, from: cached),
      case .object(let fields) = object, fields["optionsFingerprint"]?.stringValue == fingerprint,
      let text = fields["text"]?.stringValue {
      return result(text, cached: true)
    }
    let remote = RemoteSpeechRequest(
      file: audio, data: data, model: model, language: language, apiKey: apiKey,
      baseURL: baseURL ?? "", maxAttempts: attempts, timeoutSeconds: timeout)
    let text: String
    switch provider {
    case .openai:
      text = try await service.transcribeChunk(
        audio,
        options: .init(
          model: model ?? "gpt-4o-transcribe", language: language, prompt: prompt,
          maxAttempts: attempts),
        apiKey: apiKey, baseURL: remote.baseURL, deadline: deadline, timeoutSeconds: timeout)
    case .deepgram: text = try await service.deepgramTranscribe(remote, deadline: deadline)
    case .elevenlabs: text = try await service.elevenLabsTranscribe(remote, deadline: deadline)
    case .google: text = try await service.googleTranscribe(remote, deadline: deadline)
    case .apple:
      text = try await AppleSpeechRecognition.transcribe(
        file: audio, language: language, onDevice: onDevice, timeoutSeconds: timeout)
    case .command:
      let arguments = renderCommandArguments(
        argv, values: ["path": audio.path, "language": language ?? ""])
      let executable = try service.command(arguments[0], stage: "stt")
      let commandDeadline = min(deadline ?? .distantFuture, Date().addingTimeInterval(timeout))
      let output = try await service.run(
        executable, Array(arguments.dropFirst()), stage: "stt", deadline: commandDeadline,
        environmentOverlay: env.filter { $0.key.hasPrefix("COMMAND_") })
      text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try? JSONEncoder().encode(
      JSONValue.object(["optionsFingerprint": .string(fingerprint), "text": .string(text)])
    ).write(to: cacheFile, options: .atomic)
    return result(text, cached: false)
  }
}

private func mediaNumber(_ value: JSONValue?) -> Double? {
  switch value {
  case .integer(let number): return Double(number)
  case .number(let number): return number
  default: return nil
  }
}
