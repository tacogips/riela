import Foundation
import RielaAdapters
import RielaCore

#if os(macOS) && canImport(Speech)
  import Speech

  /// On-device (or Apple-hosted) file recognition through the Speech framework.
  enum AppleSpeechRecognition {
    static let isAvailable = true

    static func transcribe(
      file: URL, language: String?, onDevice: Bool, timeoutSeconds: Double
    ) async throws -> String {
      let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
      }
      guard status == .authorized else {
        throw AdapterExecutionError(
          .policyBlocked,
          "speech-to-text provider 'apple' needs Speech Recognition permission for riela (System Settings > Privacy & Security > Speech Recognition)"
        )
      }
      let recognizer =
        language.map { SFSpeechRecognizer(locale: Locale(identifier: $0)) } ?? SFSpeechRecognizer()
      guard let recognizer else {
        throw MediaPipelineError.stage(
          "stt", "Apple speech recognition does not support language '\(language ?? "default")'")
      }
      guard recognizer.isAvailable else {
        throw MediaPipelineError.stage("stt", "Apple speech recognition is currently unavailable")
      }
      if onDevice, !recognizer.supportsOnDeviceRecognition {
        throw MediaPipelineError.stage(
          "stt", "on-device recognition is not available for this language; install it or set onDevice false")
      }
      let request = SFSpeechURLRecognitionRequest(url: file)
      request.requiresOnDeviceRecognition = onDevice
      request.shouldReportPartialResults = false
      let gate = RecognitionGate()
      return try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        let task = recognizer.recognitionTask(with: request) { result, error in
          if let result, result.isFinal {
            gate.finish(.success(result.bestTranscription.formattedString))
          } else if let error {
            let nsError = error as NSError
            // 1110: "No speech detected" — an empty transcript, not a failure.
            if nsError.code == 1110 {
              gate.finish(.success(""))
            } else {
              gate.finish(
                .failure(
                  MediaPipelineError.stage(
                    "stt", "Apple speech recognition failed: \(nsError.localizedDescription)")))
            }
          }
        }
        let cancel = TaskCancelBox(task, recognizer: recognizer)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
          cancel.cancel()
          gate.finish(.failure(AdapterExecutionError(.timeout, "Apple speech recognition timed out")))
        }
      }
    }
  }

  private final class TaskCancelBox: @unchecked Sendable {
    private let task: SFSpeechRecognitionTask
    // Keeps the recognizer alive for the lifetime of its recognition task.
    private let recognizer: SFSpeechRecognizer
    init(_ task: SFSpeechRecognitionTask, recognizer: SFSpeechRecognizer) {
      self.task = task
      self.recognizer = recognizer
    }
    func cancel() { task.cancel() }
  }

  private final class RecognitionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?

    func install(_ continuation: CheckedContinuation<String, any Error>) {
      lock.withLock { self.continuation = continuation }
    }

    func finish(_ result: Result<String, any Error>) {
      let pending = lock.withLock { () -> CheckedContinuation<String, any Error>? in
        defer { continuation = nil }
        return continuation
      }
      pending?.resume(with: result)
    }
  }
#else
  enum AppleSpeechRecognition {
    static let isAvailable = false

    static func transcribe(
      file: URL, language: String?, onDevice: Bool, timeoutSeconds: Double
    ) async throws -> String {
      throw AdapterExecutionError(
        .policyBlocked, "speech-to-text provider 'apple' requires macOS (not available here or inside a container)")
    }
  }
#endif
