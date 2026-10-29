import Foundation
import RielaAdapters
import RielaCore

extension VideoTranscribeService {
  func makeChunks(ffmpeg: URL, audioURL: URL, batches: [VideoBatch], directory: URL, deadline: Date?) async throws -> [URL] {
    var values: [URL] = []
    for (index, batch) in batches.enumerated() {
      let url = directory.appendingPathComponent(String(format: "%04d.mp3", index))
      let segmentDuration = batch.end - batch.start
      _ = try await run(ffmpeg, ["-y", "-ss", String(format: "%.3f", batch.start), "-t", String(format: "%.3f", segmentDuration),
        "-i", audioURL.path, "-ac", "1", "-ar", "16000", "-b:a", "48k", url.path], stage: "audio", deadline: deadline)
      values.append(url)
    }
    return values
  }

  func transcribe(_ urls: [URL], options: VideoTranscribeOptions, apiKey: String, baseURL: String, directory: URL, deadline: Date?) async throws -> [String] {
    try await withThrowingTaskGroup(of: (Int, String).self) { group in
      var index = 0, results = [String?](repeating: nil, count: urls.count)
      func enqueue(_ item: Int) {
        group.addTask {
          let response = try await transcribeChunk(urls[item], options: options, apiKey: apiKey, baseURL: baseURL, deadline: deadline)
          return (item, response)
        }
      }
      for _ in 0..<min(options.concurrency, urls.count) where index < urls.count { enqueue(index); index += 1 }
      while let (completed, text) = try await group.next() {
        results[completed] = text
        let chunkJSON = directory.appendingPathComponent(String(format: "%04d.json", completed))
        try JSONEncoder().encode(JSONValue.object(["text": .string(text)])).write(to: chunkJSON, options: .atomic)
        if index < urls.count { enqueue(index); index += 1 }
      }
      return results.compactMap { $0 }
    }
  }

  func transcribeChunk(_ file: URL, options: VideoTranscribeOptions, apiKey: String, baseURL: String, deadline: Date?) async throws -> String {
    guard let fileData = try? Data(contentsOf: file), fileData.count < 25_000_000 else { throw VideoTranscribeError.stage("stt", "audio chunk exceeds the 25 MB upload limit") }
    let boundary = "RielaBoundary-\(UUID().uuidString)"
    var body = Data()
    func field(_ name: String, _ value: String) { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)) }
    field("model", options.model)
    field("response_format", "json")
    if let language = options.language { field("language", language) }
    if let prompt = options.sttPrompt { field("prompt", prompt) }
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.mp3\"\r\nContent-Type: audio/mpeg\r\n\r\n".utf8))
    body.append(fileData); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    let endpoint = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/audio/transcriptions")
    guard let endpoint else { throw VideoTranscribeError.stage("stt", "invalid OpenAI base URL") }
    var attempt = 0
    while attempt < options.maxAttempts {
      if let deadline, Date() >= deadline { throw VideoTranscribeError.stage("stt", "execution deadline exceeded") }
      attempt += 1
      var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.httpBody = body
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
      do {
        let response = try await http(request)
        if response.status == 200 {
          guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any], let text = json["text"] as? String else {
            throw VideoTranscribeError.stage("stt", "invalid transcription response")
          }
          return text
        }
        guard response.status == 429 || (500..<600).contains(response.status), attempt < options.maxAttempts else {
          throw VideoTranscribeError.stage("stt", "transcription service returned HTTP \(response.status)")
        }
        let delay = response.retryAfter ?? pow(2, Double(attempt - 1))
        try await Task.sleep(for: .seconds(min(max(delay, 0), 60)))
      } catch is CancellationError { throw CancellationError() } catch let error as VideoTranscribeError { throw error } catch {
        guard attempt < options.maxAttempts else { throw VideoTranscribeError.stage("stt", "transcription request failed") }
        try await Task.sleep(for: .seconds(pow(2, Double(attempt - 1))))
      }
    }
    throw VideoTranscribeError.stage("stt", "transcription attempts exhausted")
  }

  func extractFrames(ffmpeg: URL, mediaURL: URL, options: VideoTranscribeOptions, directory: URL, deadline: Date?) async throws -> (frames: [VideoFrame], sampled: Int) {
    let rawURL = directory.appendingPathComponent("samples.gray")
    _ = try await run(ffmpeg, ["-y", "-i", mediaURL.path, "-vf", "fps=1/\(options.frameInterval),scale=17:16:flags=area,format=gray",
      "-f", "rawvideo", rawURL.path], stage: "frames", deadline: deadline)
    let raw = try Data(contentsOf: rawURL); try? FileManager.default.removeItem(at: rawURL)
    let frameBytes = 272, count = raw.count / frameBytes
    let hashes = (0..<count).compactMap { index in VideoTranscribeMediaLogic.differenceHash(Array(raw[(index * frameBytes)..<(index * frameBytes + frameBytes)])) }
    let selected = VideoTranscribeMediaLogic.keptFrameIndices(hashes: hashes, threshold: options.frameDedupeThreshold)
    var frames: [VideoFrame] = []
    for index in selected {
      let time = Double(index) * options.frameInterval
      let milliseconds = Int((time.truncatingRemainder(dividingBy: 1) * 1000).rounded())
      let seconds = Int(time)
      let name = String(format: "frame_%02d%02d%02d_%03d.jpg", seconds / 3600, seconds / 60 % 60, seconds % 60, milliseconds)
      let path = directory.appendingPathComponent(name)
      _ = try await run(ffmpeg, ["-y", "-ss", String(format: "%.3f", time), "-i", mediaURL.path, "-frames:v", "1",
        "-vf", "scale=\(options.frameWidth):-2", path.path], stage: "frames", deadline: deadline)
      frames.append(.init(time: time, path: path.standardizedFileURL.path))
    }
    return (frames, count)
  }
}
