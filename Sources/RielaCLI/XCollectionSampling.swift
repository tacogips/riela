import Foundation
import RielaCore

/// Deterministic sampling primitives for X author collection.
enum XCollectionSampling {
  static func drawValue(handle: String, end: String) throws -> Double {
    let canonicalEnd = ISO8601DateFormatter().string(from: try xInstant(end))
    let digest = JSONCanonical.sha256Hex(Data((handle.lowercased() + "\n" + canonicalEnd).utf8))
    guard let value = UInt64(digest.prefix(16), radix: 16) else { throw xCollectionInvalid() }
    // Double rounds the largest UInt64 values up to 2^64; clamp to preserve [0, 1).
    return min(Double(value) / 18_446_744_073_709_551_616, 1.nextDown)
  }

  static func drawn(probability: Double, value: Double) -> Bool { value < probability }
}

/// Rolling observations are private to the returned collection checkpoint.
struct XSamplingState {
  struct Entry {
    let probability: Double
    let observedDailyVolume: Double
  }
  private struct Count {
    var posts: Int64 = 0
    var seconds: Double = 0
  }
  private struct Pending {
    let start: String
    let end: String
    var posts: [String: Int64]
  }

  let day: String
  private let timezone: String
  private let handles: Set<String>
  private var through: [String: Date] = [:]
  private var pending: [String: Pending] = [:]
  private var days: [String: [String: Count]] = [:]
  private(set) var auto: [String: Entry] = [:]

  init(options: XCollectionOptions) throws {
    guard let threshold = options.authorDailyPostThreshold else { throw xCollectionInvalid() }
    timezone = options.timezone
    handles = Set(options.handles.map { $0.lowercased() })
    day = try Self.day(end: options.end, timezone: options.timezone)
    var oldDay: String?
    if let value = options.previous["author_sampling"] {
      guard case let .object(state) = value,
        Set(state.keys) == Set(["version", "timezone", "auto_day", "auto", "through", "pending", "days"]),
        state["version"] == .integer(1), case let .string(savedTimezone)? = state["timezone"],
        case let .string(savedDay)? = state["auto_day"], Self.validDay(savedDay, timezone: savedTimezone),
        case let .object(savedAuto)? = state["auto"], case let .object(savedThrough)? = state["through"],
        case let .object(savedPending)? = state["pending"], case let .object(savedDays)? = state["days"] else { throw xCollectionInvalid() }
      oldDay = savedDay
      for (handle, value) in savedAuto {
        guard case let .object(item) = value,
          Set(item.keys) == Set(["probability", "observed_daily_volume"]),
          let probability = Self.number(item["probability"]), (0...1).contains(probability),
          let observed = Self.number(item["observed_daily_volume"]), observed > 0 else { throw xCollectionInvalid() }
        if handles.contains(handle) { auto[handle] = Entry(probability: probability, observedDailyVolume: observed) }
      }
      for (handle, value) in savedThrough {
        guard case let .string(instant) = value else { throw xCollectionInvalid() }
        let date = try xInstant(instant)
        if handles.contains(handle) { through[handle] = date }
      }
      guard savedPending.count <= 100, savedDays.count <= 7 else { throw xCollectionInvalid() }
      for (key, value) in savedPending {
        guard xMatches(.string(key), #"^[0-9a-f]{24}$"#), case let .object(item) = value,
          Set(item.keys) == Set(["start", "end", "posts"]),
          case let .string(start)? = item["start"], case let .string(end)? = item["end"],
          try xInstant(start) < xInstant(end), case let .object(posts)? = item["posts"] else { throw xCollectionInvalid() }
        pending[key] = Pending(start: start, end: end, posts: try Self.readPosts(posts, handles: handles))
      }
      for (key, value) in savedDays {
        guard Self.validDay(key, timezone: savedTimezone), case let .object(authors) = value else { throw xCollectionInvalid() }
        var bucket: [String: Count] = [:]
        for (handle, value) in authors {
          guard case let .object(item) = value,
            Set(item.keys) == Set(["posts", "seconds"]), let posts = xInt(item["posts"]), posts >= 0,
            let seconds = Self.number(item["seconds"]), seconds >= 0 else { throw xCollectionInvalid() }
          if handles.contains(handle) { bucket[handle] = Count(posts: posts, seconds: seconds) }
        }
        days[key] = bucket
      }
      if savedTimezone != timezone {
        oldDay = nil; auto.removeAll(); through.removeAll(); pending.removeAll(); days.removeAll()
      }
    }
    try prune(end: options.end)
    if oldDay != day {
      for handle in handles where options.authorSampling?[handle] == nil {
        if let observed = volume(handle) {
          if observed > Double(threshold) { auto[handle] = Entry(probability: min(1, Double(threshold) / observed), observedDailyVolume: observed) } else { auto.removeValue(forKey: handle) }
        }
      }
    }
  }

  static func day(end: String, timezone: String) throws -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: timezone) ?? .gmt
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: try xInstant(end))
  }

  func volume(_ handle: String) -> Double? {
    let values = days.values.compactMap { $0[handle.lowercased()] }
    let seconds = values.reduce(0.0) { $0 + $1.seconds }
    guard seconds >= 86_400 else { return nil }
    let posts = values.reduce(0.0) { $0 + Double($1.posts) }
    return posts / seconds * 86_400
  }

  mutating func retainPending(queries: [String]) {
    let active = Set(queries.map { String(JSONCanonical.sha256Hex(Data($0.utf8)).prefix(24)) })
    pending = pending.filter { active.contains($0.key) }
  }

  mutating func apply(window: XCollectionWindow, handles authors: [String], sampled: Bool, success: Bool) throws {
    let names = authors.map { $0.lowercased() }
    let first = try xInstant(window.start), last = try xInstant(window.end)
    let key = String(JSONCanonical.sha256Hex(Data(window.query.utf8)).prefix(24))
    var previous = pending[key]
    if previous?.start != window.start || previous?.end != window.end || window.checkpoint["pending_scan"] == nil { previous = nil }
    if sampled { previous = nil }
    var lower = first
    if sampled, window.cursor != nil {
      guard success, let oldest = try window.posts.map({ post -> Date in
        guard case let .string(created)? = post["createdAt"] else { throw xCollectionInvalid() }
        return try xInstant(created)
      }).min() else { return }
      lower = max(first, oldest)
    }
    let result = try window.result(at: ISO8601DateFormatter().string(from: Date()))
    let complete: Bool
    if case let .object(coverage)? = result["coverage"] { complete = coverage["complete"] == .bool(true) } else { complete = false }
    let pendingScan = result["pending_scan"] != nil
    if sampled && !success { return }
    if !sampled && !complete && !pendingScan { pending.removeValue(forKey: key); return }
    var tally = previous?.posts ?? [:]
    for post in window.posts {
      guard case let .object(author)? = post["author"], case let .string(name)? = author["username"],
        names.contains(name.lowercased()), case let .string(created)? = post["createdAt"] else { continue }
      let handle = name.lowercased(), time = try xInstant(created)
      if time >= max(lower, through[handle] ?? lower), time < last {
        let (total, overflow) = (tally[handle] ?? 0).addingReportingOverflow(1)
        guard !overflow else { throw xCollectionInvalid() }
        tally[handle] = total
      }
    }
    if !sampled && !complete {
      pending[key] = Pending(start: window.start, end: window.end, posts: tally)
      return
    }
    let bucketDay = try Self.day(end: window.end, timezone: timezone)
    for handle in names {
      let lo = max(lower, through[handle] ?? lower)
      let seconds = last.timeIntervalSince(lo)
      guard seconds > 0 else { continue }
      var bucket = days[bucketDay] ?? [:]
      var count = bucket[handle] ?? Count()
      let (total, overflow) = count.posts.addingReportingOverflow(tally[handle] ?? 0)
      guard !overflow, (count.seconds + seconds).isFinite else { throw xCollectionInvalid() }
      count.seconds += seconds; count.posts = total
      bucket[handle] = count; days[bucketDay] = bucket; through[handle] = last
    }
    if !sampled { pending.removeValue(forKey: key) }
    try prune(end: window.options.end)
  }

  var json: JSONObject {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    let autos = auto.mapValues { JSONValue.object(["probability": .number($0.probability), "observed_daily_volume": .number($0.observedDailyVolume)]) }
    let throughValues = through.mapValues { JSONValue.string(formatter.string(from: $0)) }
    let pendingValues = pending.mapValues { value in
      JSONValue.object(["start": .string(value.start), "end": .string(value.end),
        "posts": .object(value.posts.mapValues { .integer($0) })])
    }
    let buckets = days.mapValues { authors in
      JSONValue.object(authors.mapValues { .object(["posts": .integer($0.posts), "seconds": .number($0.seconds)]) })
    }
    return ["version": .integer(1), "timezone": .string(timezone), "auto_day": .string(day), "auto": .object(autos),
      "through": .object(throughValues), "pending": .object(pendingValues), "days": .object(buckets)]
  }

  private mutating func prune(end: String) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timezone) ?? .gmt
    let endDate = try xInstant(end)
    guard let earliest = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: endDate)) else { throw xCollectionInvalid() }
    let first = try Self.day(end: ISO8601DateFormatter().string(from: earliest), timezone: timezone)
    days = days.filter { $0.key >= first && $0.key <= day }
  }

  private static func validDay(_ value: String, timezone: String) -> Bool {
    guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: timezone) ?? .gmt
    formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
    return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
  }

  private static func number(_ value: JSONValue?) -> Double? {
    let number: Double
    switch value {
    case let .integer(value)?: number = Double(value)
    case let .number(value)?: number = value
    default: return nil
    }
    return number.isFinite ? number : nil
  }

  private static func readPosts(_ posts: JSONObject, handles: Set<String>) throws -> [String: Int64] {
    var result: [String: Int64] = [:]
    for (handle, value) in posts {
      guard let count = xInt(value), count >= 0 else { throw xCollectionInvalid() }
      if handles.contains(handle) { result[handle] = count }
    }
    return result
  }
}
