import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension MediaPipelineService {
  func sendClassified(
    _ request: URLRequest, maxAttempts: Int, label: String, deadline: Date?
  ) async throws -> Data {
    try await SpeechRetry.run(maxAttempts: maxAttempts, deadline: deadline) { _ in
      let response: MediaPipelineHTTPResponse
      do {
        response = try await http(request)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw SpeechFailureClassifier.transport(label)
      }
      guard (200..<300).contains(response.status) else {
        throw SpeechFailureClassifier.classify(
          httpStatus: response.status, body: response.body, retryAfter: response.retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, label: label)
      }
      return response.body
    }
  }
}
