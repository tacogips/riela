import Foundation
import RielaAdapters
import RielaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Upload metadata derived from the audio file extension.
struct SpeechAudioUpload: Equatable {
  static let uploadLimit = 25_000_000
  let filename: String
  let contentType: String

  init(_ file: URL) {
    let ext = file.pathExtension.lowercased()
    let known: [String: String] = [
      "wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4", "mp4": "audio/mp4",
      "flac": "audio/flac", "ogg": "audio/ogg", "oga": "audio/ogg", "opus": "audio/ogg",
      "webm": "audio/webm", "aiff": "audio/aiff", "aif": "audio/aiff", "mpga": "audio/mpeg",
      "mpeg": "audio/mpeg"
    ]
    if ext.isEmpty {
      filename = "audio.mp3"
      contentType = "audio/mpeg"
    } else {
      filename = "audio.\(ext)"
      contentType = known[ext] ?? "application/octet-stream"
    }
  }

  /// Reads an upload, enforcing the provider upload limit.
  static func read(_ file: URL) throws -> Data {
    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
      .intValue
    guard let size, size <= uploadLimit,
      let data = try? Data(contentsOf: file), data.count <= uploadLimit
    else {
      throw MediaPipelineError.stage("stt", "audio file is missing or exceeds the 25 MB upload limit")
    }
    return data
  }
}

struct MultipartFormBody {
  let boundary = "RielaBoundary-\(UUID().uuidString)"
  private var body = Data()
  var contentType: String { "multipart/form-data; boundary=\(boundary)" }

  mutating func field(_ name: String, _ value: String) {
    body.append(
      Data(
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
          .utf8))
  }

  mutating func file(_ name: String, filename: String, contentType: String, data: Data) {
    body.append(
      Data(
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n"
          .utf8))
    body.append(data)
    body.append(Data("\r\n".utf8))
  }

  func finalized() -> Data {
    body + Data("--\(boundary)--\r\n".utf8)
  }
}

enum SpeechToTextProvider: String, CaseIterable {
  case openai, deepgram, elevenlabs, google, apple, command

  var isRemote: Bool { ![.apple, .command].contains(self) }

  var defaultModel: String? {
    switch self {
    case .openai: "gpt-4o-transcribe"
    case .deepgram: "nova-3"
    case .elevenlabs: "scribe_v1"
    case .google, .apple, .command: nil
    }
  }

  /// addon.env keys this provider accepts; `command` accepts any `COMMAND_*` key.
  var allowedEnvironment: [String] {
    switch self {
    case .openai: ["OPENAI_API_KEY", "OPENAI_BASE_URL"]
    case .deepgram: ["DEEPGRAM_API_KEY", "DEEPGRAM_BASE_URL"]
    case .elevenlabs: ["ELEVENLABS_API_KEY", "ELEVENLABS_BASE_URL"]
    case .google: ["GOOGLE_SPEECH_API_KEY", "GOOGLE_SPEECH_BASE_URL"]
    case .apple, .command: []
    }
  }

  var apiKeyName: String? {
    switch self {
    case .openai: "OPENAI_API_KEY"
    case .deepgram: "DEEPGRAM_API_KEY"
    case .elevenlabs: "ELEVENLABS_API_KEY"
    case .google: "GOOGLE_SPEECH_API_KEY"
    case .apple, .command: nil
    }
  }

  var baseURLName: String? {
    switch self {
    case .openai: "OPENAI_BASE_URL"
    case .deepgram: "DEEPGRAM_BASE_URL"
    case .elevenlabs: "ELEVENLABS_BASE_URL"
    case .google: "GOOGLE_SPEECH_BASE_URL"
    case .apple, .command: nil
    }
  }

  var defaultBaseURL: String? {
    switch self {
    case .openai: "https://api.openai.com"
    case .deepgram: "https://api.deepgram.com"
    case .elevenlabs: "https://api.elevenlabs.io"
    case .google: "https://speech.googleapis.com"
    case .apple, .command: nil
    }
  }
}

/// Validates addon.env keys against a provider allowlist. `allowsCommandPrefix`
/// admits `COMMAND_*` keys, which the command provider passes to its process.
func validateSpeechEnvironment(
  _ bindings: JSONObject, stage: String, provider: String, allowed: [String],
  allowsCommandPrefix: Bool
) throws {
  let rejected = bindings.keys.filter { key in
    !(allowed.contains(key) || (allowsCommandPrefix && key.hasPrefix("COMMAND_") && key.count > 8))
  }
  guard rejected.isEmpty else {
    var supported = allowed
    if allowsCommandPrefix { supported.append("COMMAND_*") }
    let list = supported.isEmpty ? "no addon.env values" : supported.joined(separator: ", ")
    throw AdapterExecutionError(
      .policyBlocked,
      "\(stage) provider '\(provider)' addon.env supports \(list) only (rejected: \(rejected.sorted().joined(separator: ", ")))"
    )
  }
}

/// Joins a configurable base URL with an endpoint path and query.
func speechEndpoint(_ base: String, _ path: String, query: [URLQueryItem] = []) -> URL? {
  let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  guard var components = URLComponents(string: trimmed + path) else { return nil }
  if !query.isEmpty { components.queryItems = query }
  return components.url
}

/// Replaces `{{name}}` placeholders in each argv element. Unknown placeholders
/// are left untouched so the command sees them verbatim.
func renderCommandArguments(_ argv: [String], values: [String: String]) -> [String] {
  argv.map { argument in
    var rendered = argument
    for (name, value) in values {
      for token in ["{{\(name)}}", "{{ \(name) }}"] {
        rendered = rendered.replacingOccurrences(of: token, with: value)
      }
    }
    return rendered
  }
}

func commandArgv(_ value: JSONValue?) throws -> [String] {
  guard case .array(let raw)? = value, !raw.isEmpty, raw.count <= 256 else {
    throw MediaPipelineError.invalidOption("command")
  }
  return try raw.map { item in
    guard case .string(let text) = item, !text.contains("\0"), text.utf8.count <= 32_768 else {
      throw MediaPipelineError.invalidOption("command")
    }
    return text
  }
}

enum SpeechToTextResponse {
  static func deepgram(_ body: Data) throws -> String {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let results = json["results"] as? [String: Any],
      let channels = results["channels"] as? [[String: Any]],
      let alternatives = channels.first?["alternatives"] as? [[String: Any]],
      let transcript = alternatives.first?["transcript"] as? String
    else { throw MediaPipelineError.stage("stt", "invalid Deepgram transcription response") }
    return transcript
  }

  static func elevenLabs(_ body: Data) throws -> String {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let text = json["text"] as? String
    else { throw MediaPipelineError.stage("stt", "invalid ElevenLabs transcription response") }
    return text
  }

  static func google(_ body: Data) throws -> String {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw MediaPipelineError.stage("stt", "invalid Google transcription response")
    }
    // A response without `results` means no speech was recognized.
    guard let results = json["results"] as? [[String: Any]] else { return "" }
    let pieces = results.compactMap { result in
      ((result["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String)?
        .trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    // Space-separated scripts get a space between results; CJK text joins directly.
    return pieces.reduce(into: "") { text, piece in
      if let last = text.unicodeScalars.last, let first = piece.unicodeScalars.first,
        !isCJK(last), !isCJK(first) {
        text += " "
      }
      text += piece
    }
  }

  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0xAC00...0xD7AF:
      true
    default:
      false
    }
  }
}

struct RemoteSpeechRequest {
  let file: URL
  let data: Data
  let model: String?
  let language: String?
  let apiKey: String
  let baseURL: String
  let maxAttempts: Int
  let timeoutSeconds: Double
}

extension MediaPipelineService {
  func deepgramTranscribe(_ input: RemoteSpeechRequest, deadline: Date?) async throws -> String {
    var query = [URLQueryItem(name: "smart_format", value: "true")]
    if let model = input.model { query.insert(.init(name: "model", value: model), at: 0) }
    if let language = input.language {
      query.append(.init(name: "language", value: language))
    } else {
      query.append(.init(name: "detect_language", value: "true"))
    }
    guard let endpoint = speechEndpoint(input.baseURL, "/v1/listen", query: query) else {
      throw MediaPipelineError.stage("stt", "invalid Deepgram base URL")
    }
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = input.timeoutSeconds
    request.httpMethod = "POST"
    request.httpBody = input.data
    request.setValue("Token \(input.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(SpeechAudioUpload(input.file).contentType, forHTTPHeaderField: "Content-Type")
    return try SpeechToTextResponse.deepgram(
      await send(
        request, maxAttempts: input.maxAttempts, stage: "stt", label: "Deepgram transcription",
        deadline: deadline))
  }

  func elevenLabsTranscribe(_ input: RemoteSpeechRequest, deadline: Date?) async throws -> String {
    guard let endpoint = speechEndpoint(input.baseURL, "/v1/speech-to-text") else {
      throw MediaPipelineError.stage("stt", "invalid ElevenLabs base URL")
    }
    let upload = SpeechAudioUpload(input.file)
    var form = MultipartFormBody()
    form.field("model_id", input.model ?? "scribe_v1")
    if let language = input.language { form.field("language_code", language) }
    form.file("file", filename: upload.filename, contentType: upload.contentType, data: input.data)
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = input.timeoutSeconds
    request.httpMethod = "POST"
    request.httpBody = form.finalized()
    request.setValue(input.apiKey, forHTTPHeaderField: "xi-api-key")
    request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
    return try SpeechToTextResponse.elevenLabs(
      await send(
        request, maxAttempts: input.maxAttempts, stage: "stt", label: "ElevenLabs transcription",
        deadline: deadline))
  }

  func googleTranscribe(_ input: RemoteSpeechRequest, deadline: Date?) async throws -> String {
    var config: [String: Any] = ["languageCode": input.language ?? "en-US"]
    switch input.file.pathExtension.lowercased() {
    // WAV and FLAC carry their encoding and sample rate in the file header.
    case "wav", "flac": break
    default:
      throw MediaPipelineError.stage(
        "stt", "the google provider accepts WAV (LINEAR16) or FLAC audio only")
    }
    if let model = input.model { config["model"] = model }
    let payload: [String: Any] = [
      "config": config, "audio": ["content": input.data.base64EncodedString()]
    ]
    guard
      let endpoint = speechEndpoint(
        input.baseURL, "/v1/speech:recognize", query: [.init(name: "key", value: input.apiKey)])
    else { throw MediaPipelineError.stage("stt", "invalid Google Speech base URL") }
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = input.timeoutSeconds
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try SpeechToTextResponse.google(
      await send(
        request, maxAttempts: input.maxAttempts, stage: "stt", label: "Google Speech recognition",
        deadline: deadline))
  }
}
