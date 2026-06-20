import Foundation
import RielaCore
import RielaEvents

extension ScopedParityCommandRunner {
  func eventEnvelope(from object: JSONObject) throws -> ExternalEventEnvelope {
    try eventEnvelope(from: object, sourceIdOverride: nil, source: nil)
  }

  func eventEnvelope(
    from object: JSONObject,
    sourceIdOverride: String?,
    source: EventSourceContract?
  ) throws -> ExternalEventEnvelope {
    guard case let .string(sourceId)? = object["sourceId"] else {
      if let sourceIdOverride,
        let normalized = normalizedGatewayFixtureEnvelope(from: object, sourceId: sourceIdOverride, source: source) {
        return normalized
      }
      if let sourceIdOverride {
        return ExternalEventEnvelope(
          sourceId: sourceIdOverride,
          eventId: object["eventId"]?.stringValue ?? "event-dry-run",
          provider: object["provider"]?.stringValue ?? "riela",
          eventType: object["eventType"]?.stringValue ?? "event-input",
          receivedAt: try eventEnvelopeReceivedAt(from: object["receivedAt"]),
          dedupeKey: object["dedupeKey"]?.stringValue,
          input: jsonObjectValue(object["input"]) ?? [:]
        )
      }
      throw CLIUsageError("event envelope requires sourceId")
    }
    return ExternalEventEnvelope(
      sourceId: sourceIdOverride ?? sourceId,
      eventId: object["eventId"]?.stringValue ?? "event-dry-run",
      provider: object["provider"]?.stringValue ?? "riela",
      eventType: object["eventType"]?.stringValue ?? "event-input",
      receivedAt: try eventEnvelopeReceivedAt(from: object["receivedAt"]),
      dedupeKey: object["dedupeKey"]?.stringValue,
      input: jsonObjectValue(object["input"]) ?? [:]
    )
  }

  func normalizedGatewayFixtureEnvelope(
    from object: JSONObject,
    sourceId: String,
    source: EventSourceContract?
  ) -> ExternalEventEnvelope? {
    switch source?.kind {
    case .telegramGateway:
      return telegramGatewayFixtureEnvelope(from: object, sourceId: sourceId)
    case .discordGateway:
      return discordGatewayFixtureEnvelope(from: object, sourceId: sourceId)
    case .matrix:
      return matrixFixtureEnvelope(from: object, sourceId: sourceId)
    default:
      return nil
    }
  }

  private func telegramGatewayFixtureEnvelope(from object: JSONObject, sourceId: String) -> ExternalEventEnvelope? {
    guard let message = jsonObjectValue(object["message"]),
      let text = message["text"]?.stringValue,
      let chat = jsonObjectValue(message["chat"])
    else {
      return nil
    }
    let chatId = jsonStringOrIntegerValue(chat["id"]) ?? "telegram-chat"
    let messageId = jsonStringOrIntegerValue(message["message_id"]) ?? "message"
    let updateId = jsonStringOrIntegerValue(object["update_id"]) ?? messageId
    let actor = telegramActor(message["from"])
    let conversation = compactObject([
      "id": .string(chatId),
      "threadId": jsonStringOrIntegerValue(message["message_thread_id"]).map(JSONValue.string),
      "title": chat["title"],
      "type": chat["type"]
    ])
    return ExternalEventEnvelope(
      sourceId: sourceId,
      eventId: updateId,
      provider: "telegram",
      eventType: "chat.message",
      receivedAt: Date(timeIntervalSince1970: jsonNumberValue(message["date"]) ?? 0),
      actor: actor,
      conversation: conversation,
      input: chatInput(text: text, provider: "telegram")
    )
  }

  private func telegramActor(_ value: JSONValue?) -> JSONObject? {
    guard let from = jsonObjectValue(value) else {
      return nil
    }
    return compactObject([
      "id": jsonStringOrIntegerValue(from["id"]).map(JSONValue.string),
      "displayName": from["first_name"] ?? from["username"],
      "username": from["username"],
      "isBot": from["is_bot"]
    ])
  }

  private func discordGatewayFixtureEnvelope(from object: JSONObject, sourceId: String) -> ExternalEventEnvelope? {
    guard let messageId = jsonStringOrIntegerValue(object["id"]),
      let channelId = jsonStringOrIntegerValue(object["channel_id"]),
      let text = object["content"]?.stringValue
    else {
      return nil
    }
    let parentChannelId = jsonStringOrIntegerValue(object["parent_channel_id"])
    let conversationId = parentChannelId ?? channelId
    let author = jsonObjectValue(object["author"])
    let history = jsonArrayValue(object["history"]) ?? []
    return ExternalEventEnvelope(
      sourceId: sourceId,
      eventId: messageId,
      provider: "discord",
      eventType: "chat.message",
      receivedAt: discordTimestamp(object["timestamp"]),
      actor: discordActor(author),
      conversation: compactObject([
        "id": .string(conversationId),
        "threadId": parentChannelId == nil ? nil : .string(channelId),
        "guildId": jsonStringOrIntegerValue(object["guild_id"]).map(JSONValue.string)
      ]),
      input: chatInput(
        text: text,
        provider: "discord",
        history: history,
        historySource: object["historySourceMode"] ?? .string("fixture")
      )
    )
  }

  private func discordActor(_ author: JSONObject?) -> JSONObject? {
    guard let author else {
      return nil
    }
    return compactObject([
      "id": jsonStringOrIntegerValue(author["id"]).map(JSONValue.string),
      "displayName": author["global_name"] ?? author["username"],
      "username": author["username"],
      "isBot": author["bot"]
    ])
  }

  private func matrixFixtureEnvelope(from object: JSONObject, sourceId: String) -> ExternalEventEnvelope? {
    guard object["type"]?.stringValue == "m.room.message",
      let eventId = object["event_id"]?.stringValue,
      let roomId = object["room_id"]?.stringValue,
      let content = jsonObjectValue(object["content"]),
      let text = content["body"]?.stringValue
    else {
      return nil
    }
    let relatesTo = jsonObjectValue(content["m.relates_to"])
    return ExternalEventEnvelope(
      sourceId: sourceId,
      eventId: eventId,
      provider: "matrix",
      eventType: "chat.message",
      receivedAt: Date(timeIntervalSince1970: (jsonNumberValue(object["origin_server_ts"]) ?? 0) / 1_000),
      actor: matrixActor(sender: object["sender"]?.stringValue),
      conversation: compactObject([
        "id": .string(roomId),
        "threadId": relatesTo?["event_id"],
        "replyToEventId": jsonObjectValue(relatesTo?["m.in_reply_to"])?["event_id"]
      ]),
      input: chatInput(
        text: text,
        provider: "matrix",
        history: jsonArrayValue(object["history"]) ?? [],
        historySource: object["historySourceMode"] ?? .string("fixture")
      )
    )
  }

  private func matrixActor(sender: String?) -> JSONObject? {
    guard let sender else {
      return nil
    }
    return [
      "id": .string(sender),
      "displayName": .string(sender)
    ]
  }

  private func chatInput(
    text: String,
    provider: String,
    history: [JSONValue] = [],
    historySource: JSONValue = .string("fixture")
  ) -> JSONObject {
    [
      "text": .string(text),
      "provider": .string(provider),
      "history": .array(history),
      "historySource": historySource,
      "attachments": .array([]),
      "imagePaths": .array([]),
      "attachmentText": .string("")
    ]
  }

  private func discordTimestamp(_ value: JSONValue?) -> Date {
    guard let timestamp = value?.stringValue else {
      return Date(timeIntervalSince1970: 0)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: timestamp) ?? Date(timeIntervalSince1970: 0)
  }

  private func eventEnvelopeReceivedAt(from value: JSONValue?) throws -> Date {
    guard let value else {
      return Date(timeIntervalSince1970: 0)
    }
    guard case let .string(timestamp) = value else {
      throw CLIUsageError("event envelope receivedAt must be an ISO8601 string")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: timestamp) else {
      throw CLIUsageError("event envelope receivedAt must be an ISO8601 string")
    }
    return date
  }

  func jsonObjectValue(_ value: JSONValue?) -> JSONObject? {
    guard case let .object(object)? = value else {
      return nil
    }
    return object
  }

  private func jsonNumberValue(_ value: JSONValue?) -> Double? {
    guard case let .number(number)? = value else {
      return nil
    }
    return number
  }

  private func jsonArrayValue(_ value: JSONValue?) -> [JSONValue]? {
    guard case let .array(array)? = value else {
      return nil
    }
    return array
  }

  private func jsonStringOrIntegerValue(_ value: JSONValue?) -> String? {
    switch value {
    case let .string(string)?:
      return string
    case let .number(number)? where number.rounded() == number:
      return String(Int64(number))
    case let .number(number)?:
      return String(number)
    default:
      return nil
    }
  }

  private func compactObject(_ object: [String: JSONValue?]) -> JSONObject {
    object.compactMapValues { $0 }
  }
}
