import Foundation
import RielaCore

enum SpeechFailureClass: String, CaseIterable, Sendable {
  case quotaExhausted = "quota-exhausted", rateLimited = "rate-limited"
  case serverError = "server-error", transportError = "transport-error"
  case unavailable, rejected

  static let fallbackEligible: Set<Self> = [.quotaExhausted, .rateLimited, .serverError, .transportError, .unavailable]
  static let defaultFallbackOn = fallbackEligible
  var isRetryable: Bool { [.rateLimited, .serverError, .transportError].contains(self) }
}

struct SpeechProviderFailure: Error, Equatable, Sendable, LocalizedError {
  let failureClass: SpeechFailureClass
  let httpStatus: Int?
  let providerProblem: String?
  let retryAfter: Double?
  let message: String
  var fields: String {
    var result = "failureClass=\(failureClass.rawValue)"
    if let httpStatus { result += " httpStatus=\(httpStatus)" }
    if let providerProblem { result += " providerProblem=\(providerProblem)" }
    return result
  }
  var errorDescription: String? { "\(fields): \(message)" }
}

enum SpeechFailureClassifier {
  static let quotaCodes: Set<String> = ["insufficient_quota", "credit_balance_exhausted", "billing_hard_limit_reached", "billing_not_active"]
  private static func error(_ body: Data?) -> [String: Any]? {
    guard let body, let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
    return root["error"] as? [String: Any]
  }
  static func providerProblem(fromJSON body: Data) -> String? {
    guard let value = error(body) else { return nil }
    return (value["code"] as? String) ?? (value["type"] as? String) ?? (value["status"] as? String)
  }
  static func isGeminiDailyQuota(_ body: Data) -> Bool {
    let details = error(body)?["details"] as? [[String: Any]] ?? []
    return details.contains { detail in
      guard let type = detail["@type"] as? String, type.hasSuffix("google.rpc.QuotaFailure"),
        let violations = detail["violations"] as? [[String: Any]] else { return false }
      return violations.contains { ($0["quotaId"] as? String)?.contains("PerDay") == true }
    }
  }
  static func classify(httpStatus: Int, body: Data?, retryAfter: Double?, label: String) -> SpeechProviderFailure {
    let problem = body.flatMap { providerProblem(fromJSON: $0) }
    let perDay = body.map(isGeminiDailyQuota) ?? false
    let kind: SpeechFailureClass
    if problem.map(quotaCodes.contains) == true || httpStatus == 402 || (httpStatus == 429 && perDay) {
      kind = .quotaExhausted
    } else if httpStatus == 429 { kind = .rateLimited
    } else if (500...599).contains(httpStatus) { kind = .serverError
    } else { kind = .rejected }
    return .init(failureClass: kind, httpStatus: httpStatus, providerProblem: problem,
                 retryAfter: retryAfter, message: "\(label) returned HTTP \(httpStatus)")
  }
  static func transport(_ label: String) -> SpeechProviderFailure {
    .init(failureClass: .transportError, httpStatus: nil, providerProblem: nil, retryAfter: nil,
          message: "\(label) request failed")
  }
}

enum SpeechRetry {
  static func run<T: Sendable>(
    maxAttempts: Int, deadline: Date?, now: @Sendable () -> Date = Date.init,
    sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    operation: @Sendable (_ attempt: Int) async throws -> T
  ) async throws -> T {
    var attempt = 1
    while true {
      do { return try await operation(attempt) } catch let failure as SpeechProviderFailure {
        guard failure.failureClass.isRetryable, attempt < maxAttempts else { throw failure }
        let delay = min(60, max(0, failure.retryAfter ?? pow(2, Double(attempt - 1))))
        if let deadline, now().addingTimeInterval(delay) >= deadline { throw failure }
        try await sleep(delay)
        attempt += 1
      }
    }
  }
}

struct WhisperCppOptions: Equatable, Sendable {
  let binary: String?
  let model: String
  let threads: Int?
  let extraArgs: [String]
}
struct SpeechProviderConfig: Equatable, Sendable {
  let provider: SpeechToTextProvider
  let model: String?
  let onDevice: Bool
  let command: [String]
  let whisperCpp: WhisperCppOptions?
  let maxAttempts: Int
  let timeoutSeconds: Double
}
struct SpeechToTextChain: Equatable, Sendable {
  let primary: SpeechProviderConfig
  let fallback: [SpeechProviderConfig]
  let fallbackOn: Set<SpeechFailureClass>
  let cacheAcceptsFallback: Bool
  var providers: [SpeechProviderConfig] { [primary] + fallback }
  var environmentAllowlist: (keys: [String], allowsCommandPrefix: Bool) {
    (Array(Set(providers.flatMap { $0.provider.allowedEnvironment })).sorted(),
     providers.contains { $0.provider == .command })
  }
  var usesWhisperCpp: Bool { providers.contains { $0.provider == .whisperCpp } }
}
struct SpeechTranscriptionRequest: Equatable, Sendable {
  let provider: SpeechToTextProvider
  let model: String
  let apiKeyEnvironmentName: String
  let environment: [String: String]
  let baseURL: String?
  let audioFile: URL
  let language: String?
  let prompt: String?
  let timeoutSeconds: Double
}
typealias SpeechTranscriptionGateway = @Sendable (SpeechTranscriptionRequest) async throws -> String

enum SpeechToTextOptionsParser {
  static func isTemplated(_ value: JSONValue?) -> Bool {
    guard case .string(let text)? = value else { return false }
    return text.contains("{{")
  }
  static func parse(_ options: JSONObject) throws -> SpeechToTextChain {
    let primary = try config(options, prefix: "", defaults: (3, 300), fallback: false)
    var fallback: [SpeechProviderConfig] = []
    if let raw = options["fallback"] {
      guard case .array(let entries) = raw, (1...3).contains(entries.count) else { throw MediaPipelineError.invalidOption("fallback") }
      for (index, entry) in entries.enumerated() {
        let prefix = "fallback[\(index)]"
        guard case .object(let object) = entry else { throw MediaPipelineError.invalidOption(prefix) }
        let allowed: Set<String> = ["provider", "model", "onDevice", "command", "whisperCpp", "maxAttempts", "timeoutSeconds"]
        if let key = object.keys.sorted().first(where: { !allowed.contains($0) }) { throw MediaPipelineError.invalidOption("\(prefix).\(key)") }
        fallback.append(try config(object, prefix: prefix + ".", defaults: (primary.maxAttempts, primary.timeoutSeconds), fallback: true))
      }
    }
    var fallbackOn = SpeechFailureClass.defaultFallbackOn
    if let raw = options["fallbackOn"] {
      guard !fallback.isEmpty, case .array(let values) = raw, !values.isEmpty else { throw MediaPipelineError.invalidOption("fallbackOn") }
      fallbackOn = []
      for value in values {
        guard case .string(let name) = value, let kind = SpeechFailureClass(rawValue: name),
          SpeechFailureClass.fallbackEligible.contains(kind), fallbackOn.insert(kind).inserted else { throw MediaPipelineError.invalidOption("fallbackOn") }
      }
    }
    let accepts = try bool(options, "cacheAcceptsFallback", prefix: "", default: false)
    return .init(primary: primary, fallback: fallback, fallbackOn: fallbackOn, cacheAcceptsFallback: accepts)
  }
  private static func bool(_ values: JSONObject, _ key: String, prefix: String, default fallback: Bool) throws -> Bool {
    guard let raw = values[key] else { return fallback }
    guard case .bool(let value) = raw else { throw MediaPipelineError.invalidOption(prefix + key) }
    return value
  }
  private static func config(_ values: JSONObject, prefix: String, defaults: (Int, Double), fallback: Bool) throws -> SpeechProviderConfig {
    let name: String
    if let raw = values["provider"] {
      guard case .string(let value) = raw else { throw MediaPipelineError.invalidOption(prefix + "provider") }
      name = value
    } else if fallback { throw MediaPipelineError.invalidOption(prefix + "provider") } else { name = "openai" }
    guard let provider = SpeechToTextProvider(rawValue: name) else { throw MediaPipelineError.invalidOption(prefix + "provider") }
    var model = provider.defaultModel
    if let raw = values["model"] {
      guard case .string(let value) = raw else { throw MediaPipelineError.invalidOption(prefix + "model") }
      model = value
    }
    if provider.requiresModel && (model == nil || model?.isEmpty == true) { throw MediaPipelineError.invalidOption(prefix + "model") }
    let attempts: Double
    let timeout: Double
    do {
      attempts = try MediaPipelineOptions.number(values, "maxAttempts", default: Double(defaults.0), range: 1...8)
      timeout = try MediaPipelineOptions.number(values, "timeoutSeconds", default: defaults.1, range: 1...3600)
    } catch MediaPipelineError.invalidOption(let key) { throw MediaPipelineError.invalidOption(prefix + key) }
    let onDevice = try bool(values, "onDevice", prefix: prefix, default: false)
    if fallback && provider != .apple && values["onDevice"] != nil { throw MediaPipelineError.invalidOption(prefix + "onDevice") }
    var command: [String] = []
    if provider == .command {
      do { command = try commandArgv(values["command"]) } catch { throw MediaPipelineError.invalidOption(prefix + "command") }
    } else if values["command"] != nil { throw MediaPipelineError.invalidOption(prefix + "command") }
    var whisper: WhisperCppOptions?
    if provider == .whisperCpp {
      guard case .object(let object)? = values["whisperCpp"] else { throw MediaPipelineError.invalidOption(prefix + "whisperCpp") }
      let keyPrefix = prefix + "whisperCpp."
      let allowed: Set<String> = ["model", "binary", "threads", "extraArgs"]
      if let key = object.keys.sorted().first(where: { !allowed.contains($0) }) { throw MediaPipelineError.invalidOption(keyPrefix + key) }
      guard case .string(let path)? = object["model"], !path.isEmpty else { throw MediaPipelineError.invalidOption(keyPrefix + "model") }
      var binary: String?
      if let raw = object["binary"] {
        guard case .string(let value) = raw, !value.isEmpty, !value.contains("\0") else { throw MediaPipelineError.invalidOption(keyPrefix + "binary") }
        binary = value
      }
      var threads: Int?
      if let raw = object["threads"] {
        guard let value = raw.asInt64, (1...64).contains(value) else { throw MediaPipelineError.invalidOption(keyPrefix + "threads") }
        threads = Int(value)
      }
      var args: [String] = []
      if let raw = object["extraArgs"] {
        guard case .array(let entries) = raw, entries.count <= 64 else { throw MediaPipelineError.invalidOption(keyPrefix + "extraArgs") }
        for entry in entries {
          guard case .string(let value) = entry, !value.contains("\0"), value.utf8.count <= 4096 else { throw MediaPipelineError.invalidOption(keyPrefix + "extraArgs") }
          args.append(value)
        }
      }
      whisper = .init(binary: binary, model: path, threads: threads, extraArgs: args)
    } else if values["whisperCpp"] != nil { throw MediaPipelineError.invalidOption(prefix + "whisperCpp") }
    return .init(provider: provider, model: model, onDevice: onDevice, command: command,
                 whisperCpp: whisper, maxAttempts: Int(attempts), timeoutSeconds: timeout)
  }
}
