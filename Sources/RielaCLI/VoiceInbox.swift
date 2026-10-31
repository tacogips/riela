import Foundation

/// 16-bit PCM mono RIFF/WAVE encoder.
enum WAVWriter {
  static let bitsPerSample = 16
  static let headerSize = 44

  static func encode(samples: [Float], sampleRate: Int = 16_000) -> Data {
    let channels = 1
    let blockAlign = channels * bitsPerSample / 8
    let dataSize = samples.count * blockAlign
    var data = Data(capacity: headerSize + dataSize)
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + dataSize), to: &data)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    append(UInt32(16), to: &data)
    append(UInt16(1), to: &data)
    append(UInt16(channels), to: &data)
    append(UInt32(sampleRate), to: &data)
    append(UInt32(sampleRate * blockAlign), to: &data)
    append(UInt16(blockAlign), to: &data)
    append(UInt16(bitsPerSample), to: &data)
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(dataSize), to: &data)
    for sample in samples {
      let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
      append(UInt16(bitPattern: Int16((clamped * Float(Int16.max)).rounded())), to: &data)
    }
    return data
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }
}

/// Writes utterances into a file-change inbox: `<inbox>/.tmp-<id>.wav` is
/// written completely and then renamed to `<inbox>/<UTC timestamp>-<id>.wav`,
/// so a `*.wav` watcher never observes a partial file.
struct VoiceInboxWriter: Sendable {
  var inbox: URL

  static func fileName(date: Date, id: String) -> String {
    "\(timestamp(date))-\(id).wav"
  }

  static func temporaryFileName(id: String) -> String {
    ".tmp-\(id).wav"
  }

  static func timestamp(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
      format: "%04d%02d%02dT%02d%02d%02dZ",
      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
    )
  }

  static func makeIdentifier() -> String {
    String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
  }

  func prepare() throws {
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
  }

  @discardableResult
  func write(_ utterance: VoiceUtterance, date: Date = Date(), id: String = Self.makeIdentifier()) throws -> URL {
    let temporary = inbox.appendingPathComponent(Self.temporaryFileName(id: id))
    let destination = inbox.appendingPathComponent(Self.fileName(date: date, id: id))
    let data = WAVWriter.encode(samples: utterance.samples, sampleRate: utterance.sampleRate)
    do {
      try data.write(to: temporary, options: .withoutOverwriting)
      guard rename(temporary.path, destination.path) == 0 else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
    return destination
  }
}

/// Deletes `*.wav` files in an inbox (non-recursive) whose modification time
/// is older than the retention window. Any other file is left alone.
enum VoiceInboxRetention {
  @discardableResult
  static func prune(inbox: URL, retainSeconds: Int, now: Date = Date()) -> [URL] {
    guard retainSeconds > 0 else { return [] }
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: inbox, includingPropertiesForKeys: keys, options: []
    ) else { return [] }
    let cutoff = now.addingTimeInterval(-TimeInterval(retainSeconds))
    var removed: [URL] = []
    for entry in entries where entry.pathExtension.lowercased() == "wav" {
      guard let values = try? entry.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true,
        let modified = values.contentModificationDate, modified < cutoff else { continue }
      if (try? FileManager.default.removeItem(at: entry)) != nil { removed.append(entry) }
    }
    return removed
  }
}
