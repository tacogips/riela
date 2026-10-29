import Foundation

struct VideoSilence: Equatable, Sendable { let start: Double; let end: Double }
struct VideoBatch: Equatable, Sendable { let start: Double; let end: Double }
struct VideoFrame: Equatable, Sendable { let time: Double; let path: String }

enum VideoTranscribeMediaLogic {
  static func differenceHash(_ pixels: [UInt8]) -> [UInt64]? {
    guard pixels.count == 17 * 16 else { return nil }
    var words = [UInt64](repeating: 0, count: 4)
    for y in 0..<16 { for x in 0..<16 where pixels[y * 17 + x] > pixels[y * 17 + x + 1] {
      let bit = y * 16 + x
      words[bit / 64] |= UInt64(1) << UInt64(bit % 64)
    } }
    return words
  }

  static func difference(_ lhs: [UInt64], _ rhs: [UInt64]) -> Double {
    guard lhs.count == 4, rhs.count == 4 else { return 1 }
    let bits = zip(lhs, rhs).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    return Double(bits) / 256
  }

  static func keptFrameIndices(hashes: [[UInt64]], threshold: Double) -> [Int] {
    var kept: [Int] = [], lastHash: [UInt64]?
    for (index, hash) in hashes.enumerated() {
      guard let previous = lastHash else { kept.append(index); lastHash = hash; continue }
      if difference(previous, hash) > threshold { kept.append(index); lastHash = hash }
    }
    return kept
  }

  static func silences(stderr: String) -> [VideoSilence] {
    let startPattern = try? NSRegularExpression(pattern: #"silence_start:\s*([0-9.]+)"#)
    let endPattern = try? NSRegularExpression(pattern: #"silence_end:\s*([0-9.]+)"#)
    var pending: Double?, values: [VideoSilence] = []
    for line in stderr.components(separatedBy: .newlines) {
      if let match = startPattern?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
        let range = Range(match.range(at: 1), in: line), let value = Double(line[range]) { pending = value }
      if let match = endPattern?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
        let range = Range(match.range(at: 1), in: line), let end = Double(line[range]), let start = pending, end >= start {
        values.append(.init(start: start, end: end)); pending = nil
      }
    }
    return values
  }

  static func batches(duration: Double, target: Double, silences: [VideoSilence]) -> [VideoBatch] {
    guard duration > 0 else { return [] }
    var boundaries: [Double] = [0], cursor = target
    while cursor < duration {
      let window = target * 0.2
      let candidates = silences.map { ($0.start + $0.end) / 2 }.filter { abs($0 - cursor) <= window && $0 > (boundaries.last ?? 0) }
      let boundary = min(duration, candidates.min(by: { abs($0 - cursor) < abs($1 - cursor) }) ?? cursor)
      if boundary <= (boundaries.last ?? 0) { break }
      boundaries.append(boundary); cursor += target
    }
    boundaries.append(duration)
    var result = zip(boundaries, boundaries.dropFirst()).map { VideoBatch(start: $0, end: $1) }
    if result.count > 1, let last = result.last, last.end - last.start < target * 0.25 {
      result.removeLast(); result[result.count - 1] = .init(start: result[result.count - 1].start, end: duration)
    }
    return result
  }

  static func framesByBatch(_ frames: [VideoFrame], batches: [VideoBatch], carryForward: Bool) -> [[(VideoFrame, Bool)]] {
    var prior: VideoFrame?, result: [[(VideoFrame, Bool)]] = []
    for batch in batches {
      let inside = frames.filter { $0.time >= batch.start && $0.time < batch.end }
      var selected = inside.map { ($0, false) }
      if selected.isEmpty, carryForward, let prior { selected = [(prior, true)] }
      if let latest = inside.last { prior = latest }
      result.append(selected)
    }
    return result
  }
}
