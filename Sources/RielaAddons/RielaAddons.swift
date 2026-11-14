import RielaCore

public struct RielaAddonDescriptor: Codable, Equatable, Sendable {
  public var name: String
  public var version: String?

  public init(name: String, version: String? = nil) {
    self.name = name
    self.version = version
  }
}

public enum RielaBuiltinAddonCatalog {
  public static let appleGatewayAddons: [RielaAddonDescriptor] = [
    .init(name: "riela/apple-notes-list", version: "1"),
    .init(name: "riela/apple-mail-list", version: "1"),
    .init(name: "riela/apple-mail-message", version: "1"),
    .init(name: "riela/apple-note-get", version: "1"),
    .init(name: "riela/apple-note-create", version: "1"),
    .init(name: "riela/apple-note-update-body", version: "1"),
    .init(name: "riela/apple-note-delete", version: "1"),
    .init(name: "riela/apple-note-move", version: "1"),
    .init(name: "riela/apple-notifications-list", version: "1"),
    .init(name: "riela/apple-notification-post", version: "1"),
    .init(name: "riela/apple-notifications-dismiss", version: "1"),
    .init(name: "riela/calendar-list", version: "1"),
    .init(name: "riela/event-search", version: "1"),
    .init(name: "riela/event-get", version: "1"),
    .init(name: "riela/event-create", version: "1"),
    .init(name: "riela/event-update", version: "1"),
    .init(name: "riela/event-delete", version: "1"),
    .init(name: "riela/event-alarms-set", version: "1"),
    .init(name: "riela/apple-clock-alarms-list", version: "1"),
    .init(name: "riela/apple-clock-alarm-create", version: "1"),
    .init(name: "riela/apple-clock-alarm-toggle", version: "1"),
    .init(name: "riela/apple-clock-alarm-update", version: "1"),
    .init(name: "riela/apple-clock-alarm-delete", version: "1")
  ]

  public static let appleReminderReadAddons: [RielaAddonDescriptor] = [
    .init(name: "riela/apple-reminder-lists", version: "1"),
    .init(name: "riela/apple-reminders-list", version: "1"),
    .init(name: "riela/apple-reminder-get", version: "1")
  ]

  public static let appleReminderMutationAddons: [RielaAddonDescriptor] = [
    .init(name: "riela/apple-reminder-list-create", version: "1"),
    .init(name: "riela/apple-reminder-create", version: "1"),
    .init(name: "riela/apple-reminder-update", version: "1"),
    .init(name: "riela/apple-reminder-delete", version: "1"),
    .init(name: "riela/apple-reminder-complete", version: "1"),
    .init(name: "riela/apple-reminder-alarms-set", version: "1")
  ]

  public static let noteAddons: [RielaAddonDescriptor] = [
    .init(name: "kaiba/note-create", version: "1"),
    .init(name: "kaiba/note-update", version: "1"),
    .init(name: "kaiba/note-get", version: "1"),
    .init(name: "kaiba/note-search", version: "1"),
    .init(name: "kaiba/note-tag-search", version: "1"),
    .init(name: "kaiba/note-graph-neighbors", version: "1"),
    .init(name: "kaiba/note-chain", version: "1"),
    .init(name: "kaiba/note-tag-apply", version: "1"),
    .init(name: "kaiba/note-attach-file", version: "1"),
    .init(name: "kaiba/note-attachments", version: "1"),
    .init(name: "kaiba/note-memos", version: "1"),
    .init(name: "kaiba/note-graphql-document", version: "1"),
    .init(name: "kaiba/note-graphql-remote", version: "1"),
    .init(name: "kaiba/note-comment-add", version: "1"),
    .init(name: "kaiba/notebook-ingest-pages", version: "1"),
    .init(name: "kaiba/document-import", version: "1"),
    .init(name: "kaiba/note-conversation-save", version: "1"),
    .init(name: "kaiba/memory-consolidate", version: "1"),
    .init(name: "kaiba/memory-recall", version: "1")
  ]

  public static let workflowAddons: [RielaAddonDescriptor] = [
    .init(name: "riela/workflow-create-register-run", version: "1")
  ]

  public static let documentAddons: [RielaAddonDescriptor] = [
    .init(name: "riela/file-markdown-convert", version: "1")
  ]

  public static let keyValueStoreAddons: [RielaAddonDescriptor] = [
    .init(name: "riela/kv-set", version: "1"),
    .init(name: "riela/kv-get", version: "1"),
    .init(name: "riela/kv-delete", version: "1"),
    .init(name: "riela/kv-list", version: "1")
  ]

  public static let wrikeGatewayAddons: [RielaAddonDescriptor] = [
    .init(name: "riela/wrike-gateway-read", version: "1"),
    .init(name: "riela/wrike-gateway-write", version: "1"),
    .init(name: "riela/wrike-gateway-admin", version: "1")
  ]

  public static let googleServiceGatewayAddons: [RielaAddonDescriptor] = [
    .init(name: "riela/google-service-gateway-read", version: "1"),
    .init(name: "riela/google-service-gateway-write", version: "1")
  ]

  public static let appleGatewayAdminAddons: [RielaAddonDescriptor] = [
    .init(name: "riela/apple-gateway-graphql", version: "1"),
    .init(name: "riela/apple-gateway-schema", version: "1"),
    .init(name: "riela/apple-gateway-permissions-status", version: "1"),
    .init(name: "riela/apple-gateway-permissions-request", version: "1"),
    .init(name: "riela/apple-gateway-config-validate", version: "1"),
    .init(name: "riela/apple-gateway-file-download", version: "1"),
    .init(name: "riela/apple-gateway-cache-prune", version: "1")
  ]

  public static let all: [RielaAddonDescriptor] = appleGatewayAddons
    + appleReminderReadAddons
    + appleReminderMutationAddons
    + appleGatewayAdminAddons
    + noteAddons
    + workflowAddons
    + documentAddons
    + keyValueStoreAddons
    + wrikeGatewayAddons
    + googleServiceGatewayAddons

  public static func descriptor(named name: String) -> RielaAddonDescriptor? {
    all.first { $0.name == name }
  }

  public static func supports(name: String, version: String?) -> Bool {
    guard let descriptor = descriptor(named: name) else {
      return false
    }
    return version == nil || descriptor.version == nil || descriptor.version == version
  }
}
