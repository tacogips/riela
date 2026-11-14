import Foundation
import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeTimeSignal(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let variables = addonVariables(for: input)
    guard let scheduledAt = timeSignalNonEmptyString(variables["scheduledAt"]) else {
      throw AdapterExecutionError(.policyBlocked, "riela/time-signal input scheduledAt is required")
    }
    guard let timezone = timeSignalNonEmptyString(variables["timezone"]) else {
      throw AdapterExecutionError(.policyBlocked, "riela/time-signal input timezone is required")
    }
    let intervalMinutes = try timeSignalIntervalMinutes(input.addon.config ?? [:])
    let output = try TimeSignalEngine().output(
      scheduledAt: scheduledAt,
      timezoneIdentifier: timezone,
      intervalMinutes: intervalMinutes
    )

    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: ["always": true, "should_announce": output.shouldAnnounce],
      payload: [
        "status": .string("ok"),
        "addon": .string(input.addon.name),
        "stepId": .string(input.stepId),
        "shouldAnnounce": .bool(output.shouldAnnounce),
        "scheduledAt": .string(output.scheduledAt),
        "timezone": .string(timezone),
        "intervalMinutes": .number(Double(intervalMinutes)),
        "localTime": .string(output.localTime),
        "replyText": .string(output.replyText)
      ]
    )
  }
}

private struct TimeSignalEngine {
  func output(scheduledAt: String, timezoneIdentifier: String, intervalMinutes: Int) throws -> TimeSignalOutput {
    guard !timezoneIdentifier.hasPrefix("/"),
      !timezoneIdentifier.contains(".."),
      !timezoneIdentifier.contains("\\"),
      let timezone = TimeZone(identifier: timezoneIdentifier)
    else {
      throw AdapterExecutionError(.policyBlocked, "invalid timezone: \(timezoneIdentifier)")
    }
    guard let date = parseDate(scheduledAt) else {
      throw AdapterExecutionError(.policyBlocked, "scheduledAt must be an ISO timestamp: \(scheduledAt)")
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let minute = components.minute ?? 0
    let second = components.second ?? 0
    let localTime = String(format: "%04d-%02d-%02d %02d:%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0, components.hour ?? 0, minute)
    let shouldAnnounce = second == 0 && minute % intervalMinutes == 0
    let replyText = shouldAnnounce
      ? "時報です。\(timezoneIdentifier) の現在時刻は \(localTime) です。"
      : ""
    return TimeSignalOutput(
      shouldAnnounce: shouldAnnounce,
      scheduledAt: isoMilliseconds(date),
      localTime: localTime,
      replyText: replyText
    )
  }

  private func parseDate(_ value: String) -> Date? {
    for options in [
      ISO8601DateFormatter.Options.withInternetDateTime,
      [.withInternetDateTime, .withFractionalSeconds]
    ] {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = options
      if let date = formatter.date(from: value) {
        return date
      }
    }
    return nil
  }

  private func isoMilliseconds(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter.string(from: date)
  }
}

private struct TimeSignalOutput {
  var shouldAnnounce: Bool
  var scheduledAt: String
  var localTime: String
  var replyText: String
}

private func timeSignalIntervalMinutes(_ config: JSONObject) throws -> Int {
  let raw = timeSignalInt(config["intervalMinutes"]) ?? 5
  guard raw > 0 else {
    throw AdapterExecutionError(.policyBlocked, "riela/time-signal config.intervalMinutes must be a positive integer")
  }
  return raw
}

private func timeSignalInt(_ value: JSONValue?) -> Int? {
  switch value {
  case let .number(number):
    return Int(exactly: number)
  case let .string(string):
    return Int(string)
  default:
    return nil
  }
}

private func timeSignalNonEmptyString(_ value: JSONValue?) -> String? {
  guard case let .string(value)? = value else {
    return nil
  }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}
