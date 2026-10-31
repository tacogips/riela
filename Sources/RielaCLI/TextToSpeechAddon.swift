import Foundation
import RielaAdapters
import RielaAddonSupport
import RielaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum TextToSpeechProvider: String, CaseIterable {
  case apple, openai, elevenlabs, voicevox, command

  var allowedEnvironment: [String] {
    switch self {
    case .openai: ["OPENAI_API_KEY", "OPENAI_BASE_URL"]
    case .elevenlabs: ["ELEVENLABS_API_KEY", "ELEVENLABS_BASE_URL"]
    case .voicevox: ["VOICEVOX_BASE_URL"]
    case .apple, .command: []
    }
  }

  var apiKeyName: String? {
    switch self {
    case .openai: "OPENAI_API_KEY"
    case .elevenlabs: "ELEVENLABS_API_KEY"
    case .apple, .voicevox, .command: nil
    }
  }

  var baseURLName: String? {
    switch self {
    case .openai: "OPENAI_BASE_URL"
    case .elevenlabs: "ELEVENLABS_BASE_URL"
    case .voicevox: "VOICEVOX_BASE_URL"
    case .apple, .command: nil
    }
  }

  var defaultBaseURL: String? {
    switch self {
    case .openai: "https://api.openai.com"
    case .elevenlabs: "https://api.elevenlabs.io"
    case .voicevox: "http://127.0.0.1:50021"
    case .apple, .command: nil
    }
  }

  var defaultModel: String? {
    switch self {
    case .openai: "gpt-4o-mini-tts"
    case .elevenlabs: "eleven_multilingual_v2"
    case .apple, .voicevox, .command: nil
    }
  }
}

/// Parses an ISO-8601 instant, accepting fractional seconds and offsets.
func parseTextToSpeechInstant(_ value: String) -> Date? {
  let trimmed = value.trimmingCharacters(in: .whitespaces)
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: trimmed) { return date }
  return ISO8601DateFormatter().date(from: trimmed)
}

/// `always` plus exactly one of `spoken`, `skipped`, or `expired`.
func textToSpeechWhenLabels(_ payload: JSONObject) -> [String: Bool] {
  guard case .object(let fields)? = payload["textToSpeech"],
    case .string(let status)? = fields["status"]
  else { return ["always": true] }
  let label = status == "completed" ? "spoken" : status
  return ["always": true, label: true]
}

/// Validates the output format against what each provider can produce.
func textToSpeechFormat(_ value: String?, provider: TextToSpeechProvider) throws -> String {
  let fixed: String?
  switch provider {
  case .apple: fixed = "aiff"
  case .elevenlabs: fixed = "mp3"
  case .voicevox: fixed = "wav"
  case .openai, .command: fixed = nil
  }
  let format = (value ?? fixed ?? (provider == .openai ? "mp3" : "wav")).lowercased()
  guard !format.isEmpty, format.allSatisfy({ $0.isLetter || $0.isNumber }),
    fixed == nil || fixed == format
  else { throw MediaPipelineError.invalidOption("format") }
  return format
}

extension BuiltinWorkflowAddonResolver {
  static let textToSpeechRegistration = BuiltinAddonHandlerRegistration(
    name: "riela/text-to-speech", bindsCLIVariablesAsInputs: false
  ) { resolver, input, context in
    try await MediaPipelineContext(resolver: resolver, stage: "text-to-speech").finish(
      input, context, rawOptionKeys: ["command"], whenLabels: textToSpeechWhenLabels
    ) { options, _ in
      try await resolver.textToSpeech(
        options, bindings: input.addon.env ?? [:], deadline: context.deadline)
    }
  }

  func textToSpeech(
    _ values: JSONObject, bindings: JSONObject, deadline: Date?, now: Date = Date()
  ) async throws -> JSONObject {
    let c = MediaPipelineContext(resolver: self, stage: "text-to-speech")
    let service = c.service
    guard let providerName = try c.string(values, "provider", "apple"),
      let provider = TextToSpeechProvider(rawValue: providerName)
    else { throw MediaPipelineError.invalidOption("provider") }
    guard let text = try c.string(values, "text") else {
      throw MediaPipelineError.invalidOption("text")
    }
    let voice = try c.string(values, "voice").flatMap { $0.isEmpty ? nil : $0 }
    let language = try c.string(values, "language").flatMap {
      $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
    }
    let model = try c.string(values, "model", provider.defaultModel)
    let instructions = try c.string(values, "instructions")
    let rate = try values["rate"].map { _ in Int(try c.number(values, "rate", 175, 1...1000)) }
    let speaker = Int(try c.number(values, "speaker", 1, 0...100_000))
    let play = try c.bool(values, "play", false)
    let useCache = try c.bool(values, "cache", true)
    let attempts = Int(try c.number(values, "maxAttempts", 3, 1...8))
    let timeout = try c.number(values, "timeoutSeconds", 120, 1...3600)
    let argv = provider == .command ? try commandArgv(values["command"]) : []
    if provider != .command, values["command"] != nil {
      throw MediaPipelineError.invalidOption("command")
    }
    let notAfter = try c.string(values, "notAfter").flatMap { raw -> Date? in
      if raw.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
      guard let date = parseTextToSpeechInstant(raw) else {
        throw MediaPipelineError.invalidOption("notAfter")
      }
      return date
    }
    let format = try textToSpeechFormat(c.string(values, "format"), provider: provider)
    if provider == .elevenlabs, voice == nil { throw MediaPipelineError.invalidOption("voice") }
    #if !os(macOS)
      if provider == .apple {
        throw AdapterExecutionError(
          .policyBlocked, "text-to-speech provider 'apple' requires macOS (/usr/bin/say)")
      }
      if play {
        throw AdapterExecutionError(
          .policyBlocked, "text-to-speech play requires macOS (/usr/bin/afplay)")
      }
    #endif
    try validateSpeechEnvironment(
      bindings, stage: "text-to-speech", provider: provider.rawValue,
      allowed: provider.allowedEnvironment, allowsCommandPrefix: provider == .command)
    func result(_ status: String, path: String?, played: Bool, cached: Bool) -> JSONObject {
      [
        "textToSpeech": .object([
          "status": .string(status), "provider": .string(provider.rawValue),
          "path": path.map(JSONValue.string) ?? .null, "played": .bool(played),
          "cached": .bool(cached)
        ])
      ]
    }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return result("skipped", path: nil, played: false, cached: false)
    }
    if let notAfter, now > notAfter {
      return result("expired", path: nil, played: false, cached: false)
    }
    let env = try resolveAddonEnvironment(bindings, runtimeEnvironment: environment)
    var apiKey = ""
    if let keyName = provider.apiKeyName {
      guard let value = env[keyName], !value.isEmpty else {
        throw AdapterExecutionError(.policyBlocked, "text-to-speech requires addon.env.\(keyName)")
      }
      apiKey = value
    }
    let baseURL = provider.baseURLName.flatMap { env[$0] } ?? provider.defaultBaseURL
    var identity: JSONObject = [
      "provider": .string(provider.rawValue), "text": .string(text),
      "voice": voice.map(JSONValue.string) ?? .null,
      "language": language.map(JSONValue.string) ?? .null,
      "model": model.map(JSONValue.string) ?? .null, "format": .string(format),
      "instructions": instructions.map(JSONValue.string) ?? .null,
      "rate": rate.map { .integer(Int64($0)) } ?? .null
    ]
    if let baseURL { identity["baseURL"] = .string(baseURL) }
    if provider == .voicevox { identity["speaker"] = .integer(Int64(speaker)) }
    if provider == .command { identity["command"] = .array(argv.map(JSONValue.string)) }
    let fingerprint = try c.fingerprint(.object(identity))
    let outputDir =
      try c.outputDirectory(c.string(values, "outputDir"), stage: "text-to-speech")
      ?? (artifactRootURL ?? workingDirectory.appendingPathComponent(".riela/artifacts"))
      .appendingPathComponent("text-to-speech", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let output = outputDir.appendingPathComponent("tts-\(fingerprint.prefix(24)).\(format)")
      .standardizedFileURL
    let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let cached = useCache && size > 0
    let effectiveDeadline = min(deadline ?? .distantFuture, Date().addingTimeInterval(timeout))
    if !cached {
      try? FileManager.default.removeItem(at: output)
      let partial = outputDir.appendingPathComponent(".partial-\(UUID().uuidString).\(format)")
      defer { try? FileManager.default.removeItem(at: partial) }
      switch provider {
      case .apple:
        let textFile = outputDir.appendingPathComponent(".text-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: textFile, options: .atomic)
        defer { try? FileManager.default.removeItem(at: textFile) }
        var arguments: [String] = []
        if let voice { arguments += ["-v", voice] }
        if let rate { arguments += ["-r", String(rate)] }
        arguments += ["-o", partial.path, "--file-format=AIFF", "-f", textFile.path]
        _ = try await service.run(
          URL(fileURLWithPath: "/usr/bin/say"), arguments, stage: "say", deadline: effectiveDeadline)
      case .openai:
        try await service.openAISpeech(
          text: text, model: model ?? "gpt-4o-mini-tts", voice: voice ?? "alloy", format: format,
          instructions: instructions, apiKey: apiKey, baseURL: baseURL ?? "",
          timeoutSeconds: timeout, maxAttempts: attempts, deadline: effectiveDeadline
        ).write(to: partial, options: .atomic)
      case .elevenlabs:
        try await service.elevenLabsSpeech(
          text: text, voice: voice ?? "", model: model ?? "eleven_multilingual_v2",
          language: language, apiKey: apiKey, baseURL: baseURL ?? "", timeoutSeconds: timeout,
          maxAttempts: attempts, deadline: effectiveDeadline
        ).write(to: partial, options: .atomic)
      case .voicevox:
        try await service.voicevoxSpeech(
          text: text, speaker: speaker, baseURL: baseURL ?? "", timeoutSeconds: timeout,
          maxAttempts: attempts, deadline: effectiveDeadline
        ).write(to: partial, options: .atomic)
      case .command:
        let arguments = renderCommandArguments(
          argv,
          values: [
            "text": text, "output": partial.path, "voice": voice ?? "", "language": language ?? ""
          ])
        let executable = try service.command(arguments[0], stage: "tts")
        _ = try await service.run(
          executable, Array(arguments.dropFirst()), stage: "tts", deadline: effectiveDeadline,
          environmentOverlay: env.filter { $0.key.hasPrefix("COMMAND_") })
      }
      let produced = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      guard produced > 0 else {
        throw MediaPipelineError.stage("tts", "\(provider.rawValue) produced no audio file")
      }
      try FileManager.default.moveItem(at: partial, to: output)
    }
    if play {
      let playDeadline = min(deadline ?? .distantFuture, Date().addingTimeInterval(timeout))
      _ = try await service.run(
        URL(fileURLWithPath: "/usr/bin/afplay"), [output.path], stage: "play",
        deadline: playDeadline)
    }
    return result("completed", path: output.path, played: play, cached: cached)
  }
}

extension MediaPipelineService {
  func openAISpeech(
    text: String, model: String, voice: String, format: String, instructions: String?,
    apiKey: String, baseURL: String, timeoutSeconds: Double, maxAttempts: Int, deadline: Date?
  ) async throws -> Data {
    let normalizedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .replacingOccurrences(of: "/v1", with: "", options: [.backwards, .anchored])
    guard let endpoint = URL(string: normalizedBase + "/v1/audio/speech") else {
      throw MediaPipelineError.stage("tts", "invalid OpenAI base URL")
    }
    var body: [String: Any] = [
      "model": model, "voice": voice, "input": text, "response_format": format
    ]
    if let instructions { body["instructions"] = instructions }
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = timeoutSeconds
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try await send(
      request, maxAttempts: maxAttempts, stage: "tts", label: "OpenAI speech", deadline: deadline)
  }

  func elevenLabsSpeech(
    text: String, voice: String, model: String, language: String?, apiKey: String,
    baseURL: String, timeoutSeconds: Double, maxAttempts: Int, deadline: Date?
  ) async throws -> Data {
    let encodedVoice =
      voice.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"]))
      ?? voice
    guard
      let endpoint = speechEndpoint(
        baseURL, "/v1/text-to-speech/\(encodedVoice)",
        query: [.init(name: "output_format", value: "mp3_44100_128")])
    else { throw MediaPipelineError.stage("tts", "invalid ElevenLabs base URL") }
    var body: [String: Any] = ["text": text, "model_id": model]
    if let language { body["language_code"] = language }
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = timeoutSeconds
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
    return try await send(
      request, maxAttempts: maxAttempts, stage: "tts", label: "ElevenLabs speech",
      deadline: deadline)
  }

  func voicevoxSpeech(
    text: String, speaker: Int, baseURL: String, timeoutSeconds: Double, maxAttempts: Int,
    deadline: Date?
  ) async throws -> Data {
    guard
      let queryURL = speechEndpoint(
        baseURL, "/audio_query",
        query: [.init(name: "text", value: text), .init(name: "speaker", value: String(speaker))]),
      let synthesisURL = speechEndpoint(
        baseURL, "/synthesis", query: [.init(name: "speaker", value: String(speaker))])
    else { throw MediaPipelineError.stage("tts", "invalid VOICEVOX base URL") }
    var queryRequest = URLRequest(url: queryURL)
    queryRequest.timeoutInterval = timeoutSeconds
    queryRequest.httpMethod = "POST"
    let audioQuery = try await send(
      queryRequest, maxAttempts: maxAttempts, stage: "tts", label: "VOICEVOX audio_query",
      deadline: deadline)
    guard (try? JSONSerialization.jsonObject(with: audioQuery)) is [String: Any] else {
      throw MediaPipelineError.stage("tts", "invalid VOICEVOX audio_query response")
    }
    var synthesis = URLRequest(url: synthesisURL)
    synthesis.timeoutInterval = timeoutSeconds
    synthesis.httpMethod = "POST"
    synthesis.httpBody = audioQuery
    synthesis.setValue("application/json", forHTTPHeaderField: "Content-Type")
    synthesis.setValue("audio/wav", forHTTPHeaderField: "Accept")
    return try await send(
      synthesis, maxAttempts: maxAttempts, stage: "tts", label: "VOICEVOX synthesis",
      deadline: deadline)
  }
}
