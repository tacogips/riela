import Foundation
import RielaAdapters
import RielaCore

extension MediaPipelineService {
  func whisperCppTranscribe(
    audio: URL, options: WhisperCppOptions, language: String?, timeoutSeconds: Double, deadline: Date?
  ) async throws -> String {
    let executable: URL
    do {
      executable = try command(options.binary ?? "whisper-cli", stage: "stt")
      guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw MediaPipelineError.invalidOption("command")
      }
    } catch {
      throw SpeechProviderFailure(
        failureClass: .unavailable, httpStatus: nil, providerProblem: nil, retryAfter: nil,
        message: "whisper-cli is not installed or not on PATH")
    }
    let model = options.model.hasPrefix("/")
      ? URL(fileURLWithPath: options.model)
      : workingDirectory.appendingPathComponent(options.model)
    guard FileManager.default.fileExists(atPath: model.path) else {
      throw SpeechProviderFailure(
        failureClass: .unavailable, httpStatus: nil, providerProblem: nil, retryAfter: nil,
        message: "whisper-cpp model file not found")
    }
    let selectedLanguage = language.flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
    var arguments = ["-m", model.path, "-f", audio.path, "-l", selectedLanguage, "-nt", "-np"]
    if let threads = options.threads { arguments += ["-t", String(threads)] }
    arguments += options.extraArgs
    do {
      let result = try await run(
        executable, arguments, stage: "stt",
        deadline: min(deadline ?? .distantFuture, Date().addingTimeInterval(timeoutSeconds)))
      return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AdapterExecutionError where error.code == .timeout {
      throw SpeechFailureClassifier.transport("whisper-cpp")
    } catch let error as MediaPipelineError {
      let message: String
      if case .stage(_, let detail) = error { message = detail } else { message = "whisper-cpp could not run" }
      throw SpeechProviderFailure(
        failureClass: .unavailable, httpStatus: nil, providerProblem: nil, retryAfter: nil,
        message: message)
    }
  }
}
