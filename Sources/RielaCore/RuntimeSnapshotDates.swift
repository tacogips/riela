import Foundation

/// Snapshot JSON predates fractional timestamps. Keep old snapshots readable while
/// preserving millisecond timing for newly recorded execution traces.
enum RuntimeSnapshotDates {
  private static let formatter = LockedISO8601DateFormatter(fallbackFormatOptions: [.withInternetDateTime])

  static var encoding: JSONEncoder.DateEncodingStrategy {
    .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(formatter.string(from: date))
    }
  }

  static var decoding: JSONDecoder.DateDecodingStrategy {
    .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      if let date = formatter.date(from: value) { return date }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid snapshot ISO 8601 date")
    }
  }
}
