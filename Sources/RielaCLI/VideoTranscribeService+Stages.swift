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

  func transcribe(_ urls: [URL], options: VideoTranscribeOptions, apiKey: String, baseURL: String, directory: URL, cacheKeys: [String], deadline: Date?) async throws -> [String] {
    var cached = [String?](repeating: nil, count: urls.count)
    var pending: [Int] = []
    for index in urls.indices {
      let cacheURL = directory.appendingPathComponent(String(format: "%04d.json", index))
      if let data = try? Data(contentsOf: cacheURL), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
         case let .object(object) = value, object["cacheKey"]?.stringValue == cacheKeys[index], let text = object["text"]?.stringValue {
        cached[index] = text
      } else { pending.append(index) }
    }
    try await withThrowingTaskGroup(of: (Int, String).self) { group in
      var cursor = 0
      func enqueue(_ item: Int) {
        group.addTask {
          let response = try await transcribeChunk(urls[item], options: options, apiKey: apiKey, baseURL: baseURL, deadline: deadline)
          return (item, response)
        }
      }
      for _ in 0..<min(options.concurrency, pending.count) where cursor < pending.count { enqueue(pending[cursor]); cursor += 1 }
      while let (completed, text) = try await group.next() {
        cached[completed] = text
        let chunkJSON = directory.appendingPathComponent(String(format: "%04d.json", completed))
        try JSONEncoder().encode(JSONValue.object(["text": .string(text), "cacheKey": .string(cacheKeys[completed])])).write(to: chunkJSON, options: .atomic)
        if cursor < pending.count { enqueue(pending[cursor]); cursor += 1 }
      }
    }
    return cached.compactMap { $0 }
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
    let normalizedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .replacingOccurrences(of: "/v1", with: "", options: [.backwards, .anchored])
    let endpoint = URL(string: normalizedBase + "/v1/audio/transcriptions")
    guard let endpoint else { throw VideoTranscribeError.stage("stt", "invalid OpenAI base URL") }
    var attempt = 0
    while attempt < options.maxAttempts {
      if let deadline, Date() >= deadline { throw VideoTranscribeError.stage("stt", "execution deadline exceeded") }
      attempt += 1
      var request = URLRequest(url: endpoint); request.timeoutInterval = 300; request.httpMethod = "POST"; request.httpBody = body
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
    _ = try await run(ffmpeg, ["-y", "-i", mediaURL.path, "-vf", "fps=1/\(options.frameInterval):round=up,scale=17:16:flags=area,format=gray",
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
      do {
        _ = try await run(ffmpeg, ["-y", "-ss", String(format: "%.3f", time), "-i", mediaURL.path, "-frames:v", "1",
          "-vf", "scale=\(options.frameWidth):-2", path.path], stage: "frames", deadline: deadline)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try? FileManager.default.removeItem(at: path)
      }
      if !FileManager.default.fileExists(atPath: path.path), index == selected.last {
        do {
          _ = try await run(ffmpeg, ["-y", "-sseof", "-0.1", "-i", mediaURL.path, "-frames:v", "1",
            "-vf", "scale=\(options.frameWidth):-2", path.path], stage: "frames", deadline: deadline)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          try? FileManager.default.removeItem(at: path)
        }
      }
      guard FileManager.default.fileExists(atPath: path.path) else { continue }
      frames.append(.init(time: time, path: path.standardizedFileURL.path))
    }
    return (frames, count)
  }
}
