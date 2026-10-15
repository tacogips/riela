import Foundation
import RielaCore
import WrikeGatewayCore

/// A native dependency grant is derived from the selected built-in, never
/// from a guest-supplied role, command name, or capability declaration.
struct AppleGatewayContainerCapability: Sendable {
  private enum Permission {
    case query(Set<String>)
    case mutation(Set<String>)
  }

  let addonName: String
  private var expectedArguments: [String]?
  private var workspacePaths: NativeAddonWorkspacePaths?

  init(addonName: String) { self.addonName = addonName }

  init(input: WorkflowAddonExecutionInput, workingDirectory: URL, mounts: [WorkflowAddonContainerMount]) throws {
    addonName = input.addon.name
    workspacePaths = .init(workingDirectory: workingDirectory, mounts: mounts)
    if let operation = BuiltinAppleGatewayAdminAddon(rawValue: addonName) {
      expectedArguments = try AppleGatewayAdminContext(input: input, currentDirectory: workingDirectory).arguments(for: operation)
    }
  }

  var isSupported: Bool { Self.permissions[addonName] != nil || BuiltinAppleGatewayAdminAddon(rawValue: addonName) != nil }

  var maximumNativeCalls: Int {
    if BuiltinAppleGatewayAdminAddon(rawValue: addonName) != nil { return 1 }
    if case .mutation? = Self.permissions[addonName] { return 1 }
    return 128
  }

  func validate(arguments: [String]) throws {
    if BuiltinAppleGatewayAdminAddon(rawValue: addonName) != nil {
      guard let expectedArguments, arguments == expectedArguments else { throw denied() }
      _ = try nativeArguments(arguments)
      return
    }
    guard let permission = Self.permissions[addonName],
          arguments.count == 3 || arguments.count == 5,
          arguments[0] == "graphql", arguments[1] == "--query" else { throw denied() }
    if arguments.count == 5 {
      guard arguments[3] == "--variables", arguments[4].utf8.count <= BuiltinAddonContainerRequest.maximumRecordBytes,
            let variables = arguments[4].data(using: .utf8),
            (try? JSONDecoder().decode(JSONObject.self, from: variables)) != nil else { throw denied() }
    }
    let document: GraphQLDocument
    do { document = try GraphQLParser().parse(arguments[2]) } catch { throw denied() }
    let allowedFields: Set<String>
    switch permission {
    case let .query(fields):
      guard document.operation.type == .query else { throw denied() }
      allowedFields = fields
    case let .mutation(fields):
      guard document.operation.type == .mutation, document.operation.selections.count == 1 else { throw denied() }
      allowedFields = fields
    }
    guard !document.operation.selections.isEmpty,
          document.operation.selections.allSatisfy({ allowedFields.contains($0.name) }) else { throw denied() }
  }

  func nativeArguments(_ arguments: [String]) throws -> [String] {
    try workspacePaths?.nativeArguments(arguments) ?? arguments
  }

  func withNativeArguments(_ arguments: [String], deadline: Date? = nil, environment: [String: String]? = nil,
                           body: ([String]) throws -> AppleGatewayProcessOutput) throws -> AppleGatewayProcessOutput {
    if let workspacePaths {
      return try workspacePaths.withGatewayArguments(arguments, deadline: deadline) { nativeArguments in
        if let environment {
          try NativeAppleGatewayConfiguration.validate(arguments: nativeArguments, environment: environment,
            exposedRoots: workspacePaths.exposedRoots)
        }
        return try body(nativeArguments)
      }
    }
    return try body(arguments)
  }

  var canDownloadReferencedFiles: Bool { ["riela/apple-note-get", "riela/apple-mail-message"].contains(addonName) }

  func validateDependentDownload(_ arguments: [String], approvedKeys: Set<String>) throws {
    guard canDownloadReferencedFiles, workspacePaths != nil,
          arguments.count >= 6, arguments.count.isMultiple(of: 2), Array(arguments.prefix(2)) == ["file", "download"],
          arguments[arguments.count - 2] == "--output-dir" else { throw denied() }
    var keys = Set<String>()
    for index in stride(from: 2, to: arguments.count - 2, by: 2) {
      guard arguments[index] == "--key", approvedKeys.contains(arguments[index + 1]),
            keys.insert(arguments[index + 1]).inserted else { throw denied() }
    }
    _ = try nativeArguments(arguments)
  }

  private func denied() -> AdapterExecutionError {
    AdapterExecutionError(.policyBlocked, "native Apple gateway request exceeds the selected add-on capability")
  }

  private static let permissions: [String: Permission] = [
    "riela/apple-notes-list": .query(["noteAccounts", "noteFolders", "notes"]),
    "riela/apple-note-get": .query(["note"]),
    "riela/apple-note-create": .mutation(["createNote"]),
    "riela/apple-note-update-body": .mutation(["updateNoteBody"]),
    "riela/apple-note-delete": .mutation(["deleteNote"]),
    "riela/apple-note-move": .mutation(["moveNote"]),
    "riela/apple-mail-list": .query(["permissions", "mailAccounts", "mailboxes", "mailMessages"]),
    "riela/apple-mail-message": .query(["permissions", "mailMessage"]),
    "riela/calendar-list": .query(["calendars"]),
    "riela/event-search": .query(["events"]),
    "riela/event-get": .query(["event"]),
    "riela/event-create": .mutation(["createEvent"]),
    "riela/event-update": .mutation(["updateEvent"]),
    "riela/event-delete": .mutation(["deleteEvent"]),
    "riela/event-alarms-set": .mutation(["setEventAlarms"]),
    "riela/apple-reminder-lists": .query(["reminderLists"]),
    "riela/apple-reminders-list": .query(["reminders"]),
    "riela/apple-reminder-get": .query(["reminder"]),
    "riela/apple-reminder-list-create": .mutation(["createReminderList"]),
    "riela/apple-reminder-create": .mutation(["createReminder"]),
    "riela/apple-reminder-update": .mutation(["updateReminder"]),
    "riela/apple-reminder-delete": .mutation(["deleteReminder"]),
    "riela/apple-reminder-complete": .mutation(["setReminderCompleted"]),
    "riela/apple-reminder-alarms-set": .mutation(["setReminderAlarms"]),
    "riela/apple-clock-alarms-list": .query(["clockAlarms"]),
    "riela/apple-clock-alarm-create": .mutation(["createClockAlarm"]),
    "riela/apple-clock-alarm-toggle": .mutation(["toggleClockAlarm"]),
    "riela/apple-clock-alarm-update": .mutation(["updateClockAlarm"]),
    "riela/apple-clock-alarm-delete": .mutation(["deleteClockAlarm"]),
    "riela/apple-notifications-list": .query(["notifications"]),
    "riela/apple-notification-post": .mutation(["postNotification"]),
    "riela/apple-notifications-dismiss": .mutation(["dismissNotifications", "dismissAllGatewayNotifications"])
  ]
}
