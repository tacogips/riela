#if os(macOS)
import Foundation
@testable import RielaAppSupport
import XCTest

final class RielaAppDefaultProfileBootstrapperTests: XCTestCase {
  func testDefaultProfileBootstrapInstallsInactiveStarterPackages() throws {
    let root = try temporaryHome()
    let appRoot = root.appendingPathComponent(".riela/rielaapp", isDirectory: true)
    let profileStore = RielaAppProfileStore(appRootURL: appRoot)
    try profileStore.prepareInitialProfile(.default, persistsSelection: false)
    let stateURL = appRoot.appendingPathComponent("profiles/default/daemon-workflows.json")
    let daemonStore = RielaAppDaemonWorkflowStore(stateURL: stateURL, profileName: .default)

    let result = try RielaAppDefaultProfileBootstrapper(
      profileStore: profileStore,
      daemonStore: daemonStore,
      profileName: .default
    ).bootstrapIfNeeded()

    XCTAssertEqual(result.installedPackageNames, [
      "discord-yuki-chat-bot",
      "telegram-yuki-chat-bot",
      "slack-chat-bot",
      "mail-gateway-latest-mail"
    ])
    let state = daemonStore.load()
    XCTAssertTrue(state.preferences.values.allSatisfy(\.available))
    XCTAssertTrue(state.preferences.values.allSatisfy { !$0.active })
    XCTAssertEqual(state.preferences.keys.sorted(), [
      "app-package:discord-yuki-chat-bot:discord-yuki-chat-bot",
      "app-package:mail-gateway-latest-mail:mail-gateway-latest-mail",
      "app-package:slack-chat-bot:slack-chat-bot",
      "app-package:telegram-yuki-chat-bot:telegram-yuki-chat-bot"
    ])

    let discoveredCandidates = RielaAppDaemonWorkflowDiscovery(homeDirectory: root).discoverUserDaemonWorkflows(
      appPackageRoot: RielaAppProfileStore.packageRootURL(appRootURL: appRoot, profileName: .default)
    )
    let candidates = state.managedCandidates(from: discoveredCandidates)

    XCTAssertEqual(candidates.map(\.displayName), [
      "Discord Yuki Chat Bot",
      "Mail Gateway Latest Mail",
      "Slack Chat Bot",
      "Telegram Yuki Chat Bot"
    ])
    XCTAssertEqual(
      candidates.first { $0.workflowId == "discord-yuki-chat-bot" }?.eventSourceSummary,
      "discord-yuki-bot:discord-gateway"
    )
    XCTAssertEqual(
      candidates.first { $0.workflowId == "telegram-yuki-chat-bot" }?.eventSourceSummary,
      "telegram-yuki-bot:telegram-gateway"
    )
    XCTAssertEqual(
      candidates.first { $0.workflowId == "slack-chat-bot" }?.eventSourceSummary,
      "slack-chat-bot:slack-gateway"
    )
    XCTAssertEqual(candidates.first { $0.workflowId == "mail-gateway-latest-mail" }?.eventSourceSummary, "None")
    XCTAssertTrue(candidates.first { $0.workflowId == "telegram-yuki-chat-bot" }?.requiredEnvironment.contains {
      $0.name == "RIELA_TELEGRAM_YUKI_BOT_TOKEN" && $0.secret
    } == true)
  }

  func testDefaultProfileBootstrapSkipsExistingStateAndOtherProfiles() throws {
    let root = try temporaryHome()
    let appRoot = root.appendingPathComponent(".riela/rielaapp", isDirectory: true)
    let profileStore = RielaAppProfileStore(appRootURL: appRoot)
    try profileStore.prepareInitialProfile(.default, persistsSelection: false)
    let stateURL = appRoot.appendingPathComponent("profiles/default/daemon-workflows.json")
    let daemonStore = RielaAppDaemonWorkflowStore(stateURL: stateURL, profileName: .default)
    try daemonStore.save(RielaAppDaemonWorkflowState(preferences: [
      "custom": RielaAppDaemonWorkflowPreference(identity: "custom", available: true, active: true)
    ]))

    let existingResult = try RielaAppDefaultProfileBootstrapper(
      profileStore: profileStore,
      daemonStore: daemonStore,
      profileName: .default
    ).bootstrapIfNeeded()
    let workResult = try RielaAppDefaultProfileBootstrapper(
      profileStore: profileStore,
      daemonStore: RielaAppDaemonWorkflowStore(
        stateURL: appRoot.appendingPathComponent("profiles/work/daemon-workflows.json"),
        profileName: RielaAppProfileName("work")
      ),
      profileName: RielaAppProfileName("work")
    ).bootstrapIfNeeded()

    XCTAssertTrue(existingResult.skipped)
    XCTAssertTrue(workResult.skipped)
    XCTAssertEqual(daemonStore.load().preferences.keys.sorted(), ["custom"])
  }

  private func temporaryHome() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-app-default-profile-bootstrapper-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }
}
#endif
