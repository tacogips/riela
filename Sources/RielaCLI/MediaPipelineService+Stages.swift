import Foundation
import RielaAdapters
import RielaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct MediaPipelineSTTOptions: Sendable {
  let model: String
  let language: String?
  let prompt: String?
  let maxAttempts: Int
}

struct MediaFrameExtractionOptions: Sendable {
  let intervalSeconds: Double
  let dedupeThreshold: Double
  let width: Int
}

extension MediaPipelineService {
  func transcribeChunk(
    _ file: URL, options: MediaPipelineSTTOptions, apiKey: String, baseURL: String,
    deadline: Date?, timeoutSeconds: Double
  ) async throws -> String {
    let fileData = try SpeechAudioUpload.read(file)
    let upload = SpeechAudioUpload(file)
    var form = MultipartFormBody()
    form.field("model", options.model)
    form.field("response_format", "json")
    if let language = options.language { form.field("language", language) }
    if let prompt = options.prompt { form.field("prompt", prompt) }
    form.file("file", filename: upload.filename, contentType: upload.contentType, data: fileData)
    let normalizedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .replacingOccurrences(of: "/v1", with: "", options: [.backwards, .anchored])
    guard let endpoint = URL(string: normalizedBase + "/v1/audio/transcriptions") else {
      throw MediaPipelineError.stage("stt", "invalid OpenAI base URL")
    }
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = timeoutSeconds
    request.httpMethod = "POST"
    request.httpBody = form.finalized()
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
    let body = try await send(
      request, maxAttempts: options.maxAttempts, stage: "stt", label: "transcription service",
      deadline: deadline)
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let text = json["text"] as? String
    else {
      throw MediaPipelineError.stage("stt", "invalid transcription response")
    }
    return text
  }

  /// Sends a request with bounded retries on 429/5xx and transport failures,
  /// returning the body of the first 2xx response.
  func send(
    _ request: URLRequest, maxAttempts: Int, stage: String, label: String, deadline: Date?
  ) async throws -> Data {
    var attempt = 0
    while attempt < maxAttempts {
      if let deadline, Date() >= deadline {
        throw MediaPipelineError.stage(stage, "execution deadline exceeded")
      }
      attempt += 1
      do {
        let response = try await http(request)
        if (200..<300).contains(response.status) { return response.body }
        guard response.status == 429 || (500..<600).contains(response.status),
          attempt < maxAttempts
        else {
          throw MediaPipelineError.stage(stage, "\(label) returned HTTP \(response.status)")
        }
        try await Task.sleep(
          for: .seconds(min(max(response.retryAfter ?? pow(2, Double(attempt - 1)), 0), 60)))
      } catch is CancellationError { throw CancellationError() } catch let error
        as MediaPipelineError { throw error } catch {
        guard attempt < maxAttempts else {
          throw MediaPipelineError.stage(stage, "\(label) request failed")
        }
        try await Task.sleep(for: .seconds(pow(2, Double(attempt - 1))))
      }
    }
    throw MediaPipelineError.stage(stage, "\(label) attempts exhausted")
  }

  func extractFrames(
    ffmpeg: URL, mediaURL: URL, options: MediaFrameExtractionOptions, directory: URL,
    deadline: Date?
  ) async throws -> (frames: [MediaFrame], sampled: Int) {
    let rawURL = directory.appendingPathComponent("samples.gray")
    _ = try await run(
      ffmpeg,
      [
        "-y", "-i", mediaURL.path, "-vf",
        "fps=1/\(options.intervalSeconds):round=up,scale=17:16:flags=area,format=gray",
        "-f", "rawvideo", rawURL.path
      ], stage: "frames", deadline: deadline)
    let raw = try Data(contentsOf: rawURL)
    try? FileManager.default.removeItem(at: rawURL)
    let frameBytes = 272
    let count = raw.count / frameBytes
    let hashes = (0..<count).compactMap { index in
      MediaPipelineMediaLogic.differenceHash(
        Array(raw[(index * frameBytes)..<(index * frameBytes + frameBytes)]))
    }
    let selected = MediaPipelineMediaLogic.keptFrameIndices(
      hashes: hashes, threshold: options.dedupeThreshold)
    var frames: [MediaFrame] = []
    for index in selected {
      let time = Double(index) * options.intervalSeconds
      let milliseconds = Int((time.truncatingRemainder(dividingBy: 1) * 1000).rounded())
      let seconds = Int(time)
      let name = String(
        format: "frame_%02d%02d%02d_%03d.jpg", seconds / 3600, seconds / 60 % 60, seconds % 60,
        milliseconds)
      let path = directory.appendingPathComponent(name)
      do {
        _ = try await run(
          ffmpeg,
          [
            "-y", "-ss", String(format: "%.3f", time), "-i", mediaURL.path, "-frames:v", "1",
            "-vf", "scale=\(options.width):-2", path.path
          ], stage: "frames", deadline: deadline)
      } catch is CancellationError { throw CancellationError() } catch let error as AdapterExecutionError
        where error.code == .timeout { throw error } catch let error as MediaPipelineError {
        guard case .stage(_, let message) = error,
          message.hasPrefix("process exited with status ") else { throw error }
        try? FileManager.default.removeItem(at: path)
      } catch { throw error }
      if !FileManager.default.fileExists(atPath: path.path), index == selected.last {
        do {
          _ = try await run(
            ffmpeg,
            [
              "-y", "-sseof", "-0.1", "-i", mediaURL.path, "-frames:v", "1",
              "-vf", "scale=\(options.width):-2", path.path
            ], stage: "frames", deadline: deadline)
        } catch is CancellationError { throw CancellationError() } catch let error as AdapterExecutionError
          where error.code == .timeout { throw error } catch let error as MediaPipelineError {
          guard case .stage(_, let message) = error,
            message.hasPrefix("process exited with status ") else { throw error }
          try? FileManager.default.removeItem(at: path)
        } catch { throw error }
      }
      if FileManager.default.fileExists(atPath: path.path) {
        frames.append(.init(time: time, path: path.standardizedFileURL.path))
      }
    }
    return (frames, count)
  }
}
