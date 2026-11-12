import AgentGateway
import AgentGatewayAppCore
import Foundation

func makeAgentGatewaySpeechTranscription(
  transcriberFactory: @escaping @Sendable ([String: String]) -> any GatewayTranscribing = {
    ProductionGatewayExecutor(environment: $0)
  }
) -> SpeechTranscriptionGateway {
  { request in
    let vendor: GatewayVendor
    switch request.provider {
    case .openai: vendor = .openAI
    case .gemini: vendor = .gemini
    case .openrouter: vendor = .openRouter
    default:
      throw SpeechProviderFailure(failureClass: .rejected, httpStatus: nil, providerProblem: nil,
                                  retryAfter: nil, message: "\(request.provider.rawValue) transcription")
    }
    var baseURL = request.baseURL.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    if request.provider == .openai, var base = baseURL {
      if base.hasSuffix("/v1") { base.removeLast(3) }
      baseURL = base + "/v1"
    }
    let params = GatewayTranscriptionParams(
      vendor: vendor, model: request.model, audioFile: request.audioFile,
      mimeType: SpeechAudioUpload(request.audioFile).contentType,
      language: request.language.flatMap { $0.isEmpty ? nil : $0 },
      prompt: request.prompt.flatMap { $0.isEmpty ? nil : $0 },
      apiKeyEnvironment: request.apiKeyEnvironmentName, baseURL: baseURL,
      timeoutSeconds: max(1, Int(ceil(request.timeoutSeconds))))
    let label = "\(request.provider.rawValue) transcription"
    do {
      return try await transcriberFactory(request.environment).transcribe(params).text
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as GatewayTranscriptionFailure {
      throw mapGatewayTranscriptionFailure(error, label: label)
    } catch let error as GatewayRPCError {
      let kind: SpeechFailureClass = [-32011, -32021].contains(error.code) ? .unavailable : .rejected
      throw SpeechProviderFailure(failureClass: kind, httpStatus: nil, providerProblem: nil,
                                  retryAfter: nil, message: label)
    } catch is URLError {
      throw SpeechFailureClassifier.transport(label)
    } catch {
      throw SpeechProviderFailure(failureClass: .rejected, httpStatus: nil, providerProblem: nil,
                                  retryAfter: nil, message: label)
    }
  }
}

private func mapGatewayTranscriptionFailure(_ error: GatewayTranscriptionFailure, label: String) -> SpeechProviderFailure {
  let code = error.vendorErrorCode
  let numeric = code.map { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } } ?? false
  let candidate = numeric ? error.vendorErrorType : (code ?? error.vendorErrorType)
  let problem = candidate.flatMap { value -> String? in
    guard (1...64).contains(value.utf8.count), value.utf8.allSatisfy({ byte in
      (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        || [45, 46, 58, 95].contains(byte)
    }) else { return nil }
    return value
  }
  let dailyQuota = error.httpStatus == 429 && error.rawBody.map {
    SpeechFailureClassifier.isGeminiDailyQuota(Data($0.utf8))
  } == true
  let kind: SpeechFailureClass
  if error.classification == .quotaExhausted || problem.map(SpeechFailureClassifier.quotaCodes.contains) == true || dailyQuota {
    kind = .quotaExhausted
  } else {
    switch error.classification {
    case .rateLimited: kind = .rateLimited
    case .serverError: kind = .serverError
    case .transport: kind = .transportError
    default: kind = .rejected
    }
  }
  return SpeechProviderFailure(failureClass: kind, httpStatus: error.httpStatus, providerProblem: problem,
                               retryAfter: error.retryAfterSeconds.map(Double.init), message: label)
}

let agentGatewaySpeechTranscription = makeAgentGatewaySpeechTranscription()
