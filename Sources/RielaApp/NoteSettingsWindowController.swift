#if os(macOS)
import AppKit
import CoreImage
import Foundation
import RielaAppSupport
import RielaNote
import RielaNoteDispatch
import RielaServer

struct RielaAppNoteSettings: Codable, Equatable, Sendable {
  var exposesNoteAPI: Bool
  var s3Profiles: [RielaAppNoteS3ProfileSettings]

  init(
    exposesNoteAPI: Bool = false,
    s3Profiles: [RielaAppNoteS3ProfileSettings] = []
  ) {
    self.exposesNoteAPI = exposesNoteAPI
    self.s3Profiles = s3Profiles
  }
}

struct RielaAppNoteS3ProfileSettings: Codable, Equatable, Sendable {
  var name: String
  var endpoint: String
  var region: String
  var bucket: String
  var accessKeyIdEnv: String
  var secretAccessKeyEnv: String
  var sessionTokenEnv: String?
  var keyPrefix: String

  init(
    name: String,
    endpoint: String,
    region: String,
    bucket: String,
    accessKeyIdEnv: String = "AWS_ACCESS_KEY_ID",
    secretAccessKeyEnv: String = "AWS_SECRET_ACCESS_KEY",
    sessionTokenEnv: String? = nil,
    keyPrefix: String = ""
  ) {
    self.name = name
    self.endpoint = endpoint
    self.region = region
    self.bucket = bucket
    self.accessKeyIdEnv = accessKeyIdEnv
    self.secretAccessKeyEnv = secretAccessKeyEnv
    self.sessionTokenEnv = sessionTokenEnv
    self.keyPrefix = keyPrefix
  }
}

enum RielaAppNoteRegistrationError: LocalizedError, Equatable {
  case endpointUnavailable

  var errorDescription: String? {
    switch self {
    case .endpointUnavailable:
      return "Note API registration is unavailable because this profile is not currently being served."
    }
  }
}

struct RielaAppNoteSettingsStore: Sendable {
  var settingsURL: URL

  init(noteRoot: URL) {
    settingsURL = noteRoot.appendingPathComponent("app-settings.json")
  }

  func load() -> RielaAppNoteSettings {
    guard let data = try? Data(contentsOf: settingsURL),
          let settings = try? JSONDecoder().decode(RielaAppNoteSettings.self, from: data) else {
      return RielaAppNoteSettings()
    }
    return settings
  }

  func save(_ settings: RielaAppNoteSettings) throws {
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(settings).write(to: settingsURL, options: .atomic)
  }
}

@MainActor
final class NoteSettingsWindowController: NSWindowController, NSWindowDelegate {
  let noteRoot: URL
  let profileName: RielaAppProfileName
  let settingsStore: RielaAppNoteSettingsStore
  let service: NoteService
  let registrationAuthenticator: QRClientRegistrationAuthenticator
  let registrationBaseURLProvider: @MainActor () -> String?

  private let onWindowWillClose: () -> Void
  private let maintenanceTicker: NoteAutoActionMaintenanceTicker?
  let appearanceStore: RielaAppAppearanceSettingsStore?
  private let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let apiExposureCheckbox = NSButton(checkboxWithTitle: "Expose Note API", target: nil, action: nil)
  private let s3ProfileNameField = NSTextField(string: "")
  private let s3EndpointField = NSTextField(string: "")
  private let s3RegionField = NSTextField(string: "")
  private let s3BucketField = NSTextField(string: "")
  private let s3KeyPrefixField = NSTextField(string: "")
  private let s3AccessKeyEnvField = NSTextField(string: "")
  private let s3SecretKeyEnvField = NSTextField(string: "")
  private let s3SessionTokenEnvField = NSTextField(string: "")
  private let clientRowsStack = NSStackView()
  private let statusLabel = NSTextField(labelWithString: "")

  init(
    noteRoot: URL,
    profileName: RielaAppProfileName,
    registrationBaseURL: String? = nil,
    registrationBaseURLProvider: (@MainActor () -> String?)? = nil,
    autoActionLauncher: (any NoteAutoActionWorkflowLaunching)? = nil,
    appearanceStore: RielaAppAppearanceSettingsStore? = nil,
    onWindowWillClose: @escaping () -> Void = {}
  ) throws {
    self.noteRoot = noteRoot
    self.profileName = profileName
    self.appearanceStore = appearanceStore
    self.settingsStore = RielaAppNoteSettingsStore(noteRoot: noteRoot)
    self.registrationBaseURLProvider = registrationBaseURLProvider ?? { registrationBaseURL }
    self.onWindowWillClose = onWindowWillClose

    try FileManager.default.createDirectory(at: noteRoot, withIntermediateDirectories: true)
    let service = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot.path),
      autoActionDispatcher: autoActionLauncher.map { NoteAutoActionWorkflowDispatcher(launcher: $0) }
    )
    self.service = service
    self.maintenanceTicker = autoActionLauncher == nil
      ? nil
      : NoteAutoActionMaintenanceTicker(service: service)
    self.registrationAuthenticator = QRClientRegistrationAuthenticator(
      service: service,
      registrationScope: noteRoot.standardizedFileURL.path
    )

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Notes Settings - \(profileName.rawValue)"
    window.minSize = NSSize(width: 620, height: 500)
    super.init(window: window)
    window.delegate = self
    window.contentView = buildContentView()
    window.center()
    reload()
    if let maintenanceTicker {
      Task { await maintenanceTicker.start() }
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  func windowWillClose(_ notification: Notification) {
    if let maintenanceTicker {
      Task { await maintenanceTicker.stop() }
    }
    onWindowWillClose()
  }

  private func buildContentView() -> NSView {
    let titleLabel = NSTextField(labelWithString: "Notes")
    titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
    titleLabel.alignment = .left
    let titleRow = NSStackView(views: [titleLabel, spacer()])
    titleRow.orientation = .horizontal
    titleRow.alignment = .centerY
    titleRow.spacing = 8

    let rootLabel = NSTextField(labelWithString: noteRoot.path)
    rootLabel.lineBreakMode = .byTruncatingMiddle
    rootLabel.textColor = .secondaryLabelColor
    rootLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    apiExposureCheckbox.target = self
    apiExposureCheckbox.action = #selector(toggleAPIExposure)
    apiExposureCheckbox.toolTip = "Allow the Riela note API to be exposed for this profile when the app serves it."
    apiExposureCheckbox.setAccessibilityLabel("Expose Note API")

    appearancePopup.removeAllItems()
    for scheme in RielaAppColorScheme.allCases {
      appearancePopup.addItem(withTitle: scheme.displayName)
      appearancePopup.lastItem?.representedObject = scheme.rawValue
    }
    appearancePopup.target = self
    appearancePopup.action = #selector(appearanceChanged)
    appearancePopup.toolTip = "Color scheme for all Riela windows. Dark is the default."
    appearancePopup.setAccessibilityLabel("Color Scheme")

    configureS3ProfileFields()

    let s3SaveButton = NSButton(title: "Save Profile", target: self, action: #selector(saveS3Profile))
    s3SaveButton.bezelStyle = .rounded
    s3SaveButton.toolTip = "Save this profile using environment variable names for credentials."

    let s3ClearButton = NSButton(title: "Clear", target: self, action: #selector(clearS3Profile))
    s3ClearButton.bezelStyle = .rounded
    s3ClearButton.toolTip = "Remove saved S3 profiles for this note profile."

    let registerButton = NSButton(
      title: "Register Client",
      target: self,
      action: #selector(registerClient)
    )
    registerButton.bezelStyle = .rounded

    let rootRow = RielaAppSettingsRow(views: [
      rielaAppSettingsTitleLabel("Note Root", maxWidth: 110),
      rootLabel
    ])
    rootRow.orientation = .horizontal
    rootRow.alignment = .firstBaseline
    rootRow.spacing = 8

    let apiRow = RielaAppSettingsRow(views: [
      rielaAppSettingsTitleLabel("API", maxWidth: 110),
      apiExposureCheckbox
    ])
    apiRow.orientation = .horizontal
    apiRow.alignment = .centerY
    apiRow.spacing = 8

    let appearanceRow = RielaAppSettingsRow(views: [
      rielaAppSettingsTitleLabel("Appearance", maxWidth: 110),
      appearancePopup,
      spacer()
    ])
    appearanceRow.orientation = .horizontal
    appearanceRow.alignment = .centerY
    appearanceRow.spacing = 8

    let s3Header = NSStackView(views: [
      sectionTitle("S3 Storage Profile"),
      spacer(),
      s3SaveButton,
      s3ClearButton
    ])
    s3Header.orientation = .horizontal
    s3Header.alignment = .centerY
    s3Header.spacing = 8

    let s3ProfileForm = NSStackView(views: [
      s3ProfileFieldRow("Name", s3ProfileNameField),
      s3ProfileFieldRow("Endpoint", s3EndpointField),
      s3ProfileFieldRow("Region", s3RegionField),
      s3ProfileFieldRow("Bucket", s3BucketField),
      s3ProfileFieldRow("Key Prefix", s3KeyPrefixField),
      s3ProfileFieldRow("Access Key Env", s3AccessKeyEnvField),
      s3ProfileFieldRow("Secret Env", s3SecretKeyEnvField),
      s3ProfileFieldRow("Session Env", s3SessionTokenEnvField)
    ])
    s3ProfileForm.orientation = .vertical
    s3ProfileForm.alignment = .width
    s3ProfileForm.spacing = 8

    let s3ProfileRow = RielaAppSettingsRow(views: [s3ProfileForm])
    s3ProfileRow.orientation = .vertical
    s3ProfileRow.alignment = .width
    s3ProfileRow.spacing = 8

    let clientsHeader = NSStackView(views: [
      sectionTitle("Registered Clients"),
      spacer(),
      registerButton
    ])
    clientsHeader.orientation = .horizontal
    clientsHeader.alignment = .centerY
    clientsHeader.spacing = 8

    clientRowsStack.orientation = .vertical
    clientRowsStack.alignment = .width
    clientRowsStack.spacing = 8

    statusLabel.textColor = .secondaryLabelColor
    statusLabel.alignment = .left
    statusLabel.maximumNumberOfLines = 2
    statusLabel.lineBreakMode = .byWordWrapping
    let statusRow = NSStackView(views: [statusLabel, spacer()])
    statusRow.orientation = .horizontal
    statusRow.alignment = .centerY
    statusRow.spacing = 8

    let stack = NSStackView(views: [
      titleRow,
      rielaAppSettingsRow(rootRow),
      rielaAppSettingsRow(apiRow),
      rielaAppSettingsRow(appearanceRow),
      s3Header,
      rielaAppSettingsRow(s3ProfileRow),
      clientsHeader,
      clientRowsStack,
      statusRow
    ])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -22)
    ])
    return container
  }

  private func reload(status: String? = nil) {
    let settings = settingsStore.load()
    apiExposureCheckbox.state = settings.exposesNoteAPI ? .on : .off
    let colorScheme = appearanceStore?.load().colorScheme ?? .dark
    appearancePopup.selectItem(at: RielaAppColorScheme.allCases.firstIndex(of: colorScheme) ?? 0)
    populateS3ProfileFields(from: settings.s3Profiles.first)
    rebuildClientRows()
    statusLabel.stringValue = status ?? "API exposure is opt-in per profile. Client tokens are shown only when registered."
  }

  private func rebuildClientRows() {
    clientRowsStack.arrangedSubviews.forEach { view in
      clientRowsStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    let clients = (try? service.listAPIClients(includeRevoked: false)) ?? []
    guard !clients.isEmpty else {
      let emptyLabel = NSTextField(labelWithString: "No registered clients.")
      emptyLabel.alignment = .left
      emptyLabel.textColor = .secondaryLabelColor
      let emptyRow = NSStackView(views: [emptyLabel, spacer()])
      emptyRow.orientation = .horizontal
      emptyRow.alignment = .centerY
      emptyRow.spacing = 8
      clientRowsStack.addArrangedSubview(emptyRow)
      return
    }

    for client in clients {
      clientRowsStack.addArrangedSubview(clientRow(client))
    }
  }

  private func clientRow(_ client: NoteAPIClient) -> NSView {
    let nameLabel = NSTextField(labelWithString: client.displayName)
    nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
    let detailLabel = NSTextField(labelWithString: "Created \(client.createdAt) - \(client.clientId)")
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.lineBreakMode = .byTruncatingMiddle

    let labels = NSStackView(views: [nameLabel, detailLabel])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 2

    let revokeButton = NSButton(title: "Revoke", target: self, action: #selector(revokeClient(_:)))
    revokeButton.bezelStyle = .rounded
    revokeButton.identifier = NSUserInterfaceItemIdentifier(client.clientId)

    let row = RielaAppSettingsRow(views: [labels, spacer(), revokeButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    return rielaAppSettingsRow(row)
  }

  @objc private func appearanceChanged() {
    guard let rawValue = appearancePopup.selectedItem?.representedObject as? String,
          let colorScheme = RielaAppColorScheme(rawValue: rawValue) else {
      return
    }
    setColorScheme(colorScheme)
  }

  func setColorScheme(_ colorScheme: RielaAppColorScheme) {
    rielaAppApplyColorScheme(colorScheme)
    guard let appearanceStore else {
      reload(status: "Switched to \(colorScheme.displayName) appearance (not persisted).")
      return
    }
    do {
      try appearanceStore.save(RielaAppAppearanceSettings(colorScheme: colorScheme))
      reload(status: "Switched to \(colorScheme.displayName) appearance.")
    } catch {
      reload(status: "Failed to save appearance: \(error.localizedDescription)")
    }
  }

  @objc private func toggleAPIExposure() {
    var settings = settingsStore.load()
    settings.exposesNoteAPI = apiExposureCheckbox.state == .on
    do {
      try settingsStore.save(settings)
      reload(status: settings.exposesNoteAPI ? "Note API exposure enabled for this profile." : "Note API exposure disabled.")
    } catch {
      reload(status: "Failed to save settings: \(error.localizedDescription)")
    }
  }

  @objc private func saveS3Profile() {
    do {
      try saveS3ProfileFromEditor()
    } catch {
      reload(status: "Failed to save S3 profile: \(error.localizedDescription)")
    }
  }

  @objc private func clearS3Profile() {
    do {
      try clearS3ProfilesFromSettings()
    } catch {
      reload(status: "Failed to clear S3 profile: \(error.localizedDescription)")
    }
  }

  func setS3ProfileEditor(_ profile: RielaAppNoteS3ProfileSettings) {
    populateS3ProfileFields(from: profile)
  }

  func saveS3ProfileFromEditor() throws {
    var settings = settingsStore.load()
    settings.s3Profiles = [try profileFromS3Editor()]
    try settingsStore.save(settings)
    reload(status: "Saved S3 profile \(settings.s3Profiles[0].name).")
  }

  func clearS3ProfilesFromSettings() throws {
    var settings = settingsStore.load()
    settings.s3Profiles = []
    try settingsStore.save(settings)
    reload(status: "Removed saved S3 profiles for this note profile.")
  }

  @objc private func registerClient() {
    Task { @MainActor in
      await registerClientUsingChallenge()
    }
  }

  private func registerClientUsingChallenge() async {
    do {
      let challenge = try await createRegistrationChallengeForSheet()
      reload(status: "Scan the registration QR or copy the URL. Code expires at \(challenge.expiresAt).")
      showRegistrationChallenge(challenge)
    } catch {
      reload(status: "Failed to register client: \(error.localizedDescription)")
    }
  }

  func createRegistrationChallengeForSheet() async throws -> NoteAPIRegistrationChallenge {
    try await registrationAuthenticator.createRegistrationChallenge(publicBaseURL: try registrationBaseURL())
  }

  func registerNextClientUsingChallenge() async throws -> NoteAPIRegistrationCredential {
    let displayName = "Client \((try service.listAPIClients(includeRevoked: true)).count + 1)"
    let challenge = try await registrationAuthenticator.createRegistrationChallenge(publicBaseURL: try registrationBaseURL())
    return try await registrationAuthenticator.redeemRegistrationCode(
      code: challenge.code,
      displayName: displayName
    )
  }

  private func registrationBaseURL() throws -> String {
    guard let baseURL = registrationBaseURLProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !baseURL.isEmpty else {
      throw RielaAppNoteRegistrationError.endpointUnavailable
    }
    return baseURL
  }

  @objc private func revokeClient(_ sender: NSButton) {
    guard let clientId = sender.identifier?.rawValue else {
      return
    }
    do {
      let client = try service.revokeAPIClient(clientId: clientId)
      reload(status: "Revoked \(client.displayName).")
    } catch {
      reload(status: "Failed to revoke client: \(error.localizedDescription)")
    }
  }

  private func showRegistrationChallenge(_ challenge: NoteAPIRegistrationChallenge) {
    guard let window else {
      return
    }
    let alert = NSAlert()
    alert.messageText = "Register Note Client"
    alert.informativeText = """
    Scan this QR code from the client app, or enter the code shown below.
    Expires at \(challenge.expiresAt).
    """
    alert.accessoryView = registrationChallengeAccessoryView(challenge)
    alert.addButton(withTitle: "Copy URL")
    alert.addButton(withTitle: "Done")
    alert.beginSheetModal(for: window) { response in
      guard response == .alertFirstButtonReturn else {
        return
      }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(challenge.registrationURL, forType: .string)
    }
  }

  func registrationChallengeAccessoryView(_ challenge: NoteAPIRegistrationChallenge) -> NSView {
    let codeLabel = NSTextField(labelWithString: challenge.code)
    codeLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
    codeLabel.alignment = .center

    let urlLabel = NSTextField(labelWithString: challenge.registrationURL)
    urlLabel.font = .systemFont(ofSize: 11)
    urlLabel.textColor = .secondaryLabelColor
    urlLabel.lineBreakMode = .byTruncatingMiddle
    urlLabel.maximumNumberOfLines = 1
    urlLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let stackViews: [NSView]
    if let qrImage = registrationQRCodeImage(for: challenge.registrationURL) {
      let imageView = NSImageView(image: qrImage)
      imageView.imageScaling = .scaleProportionallyUpOrDown
      imageView.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        imageView.widthAnchor.constraint(equalToConstant: 180),
        imageView.heightAnchor.constraint(equalToConstant: 180)
      ])
      stackViews = [imageView, codeLabel, urlLabel]
    } else {
      stackViews = [codeLabel, urlLabel]
    }

    let stack = NSStackView(views: stackViews)
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])
    return container
  }

  private func registrationQRCodeImage(for payload: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
      return nil
    }
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let outputImage = filter.outputImage else {
      return nil
    }
    let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: 180, height: 180))
  }

  private func sectionTitle(_ title: String) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 14, weight: .semibold)
    label.alignment = .left
    return label
  }

  private func configureS3ProfileFields() {
    let placeholders: [(NSTextField, String)] = [
      (s3ProfileNameField, "default-s3"),
      (s3EndpointField, "https://s3.example.com"),
      (s3RegionField, "ap-northeast-1"),
      (s3BucketField, "bucket-name"),
      (s3KeyPrefixField, "profiles/default"),
      (s3AccessKeyEnvField, "AWS_ACCESS_KEY_ID"),
      (s3SecretKeyEnvField, "AWS_SECRET_ACCESS_KEY"),
      (s3SessionTokenEnvField, "AWS_SESSION_TOKEN")
    ]
    for (field, placeholder) in placeholders {
      field.placeholderString = placeholder
      field.lineBreakMode = .byTruncatingMiddle
      field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
  }

  private func s3ProfileFieldRow(_ title: String, _ field: NSTextField) -> NSStackView {
    let row = NSStackView(views: [
      rielaAppSettingsTitleLabel(title, maxWidth: 120),
      field
    ])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
  }

  private func populateS3ProfileFields(from profile: RielaAppNoteS3ProfileSettings?) {
    let defaults = RielaAppNoteS3ProfileSettings(name: "default-s3", endpoint: "", region: "", bucket: "")
    let profile = profile ?? defaults
    s3ProfileNameField.stringValue = profile.name
    s3EndpointField.stringValue = profile.endpoint
    s3RegionField.stringValue = profile.region
    s3BucketField.stringValue = profile.bucket
    s3KeyPrefixField.stringValue = profile.keyPrefix
    s3AccessKeyEnvField.stringValue = profile.accessKeyIdEnv
    s3SecretKeyEnvField.stringValue = profile.secretAccessKeyEnv
    s3SessionTokenEnvField.stringValue = profile.sessionTokenEnv ?? ""
  }

  private func profileFromS3Editor() throws -> RielaAppNoteS3ProfileSettings {
    let name = trimmed(s3ProfileNameField)
    let endpoint = trimmed(s3EndpointField)
    let region = trimmed(s3RegionField)
    let bucket = trimmed(s3BucketField)
    let accessKeyEnv = trimmed(s3AccessKeyEnvField)
    let secretKeyEnv = trimmed(s3SecretKeyEnvField)
    guard !name.isEmpty, !endpoint.isEmpty, !region.isEmpty, !bucket.isEmpty else {
      throw NoteSettingsS3ProfileEditorError.missingRequiredFields
    }
    guard URL(string: endpoint) != nil else {
      throw NoteSettingsS3ProfileEditorError.invalidEndpoint
    }
    guard !accessKeyEnv.isEmpty, !secretKeyEnv.isEmpty else {
      throw NoteSettingsS3ProfileEditorError.missingCredentialEnvironment
    }
    let sessionTokenEnv = trimmed(s3SessionTokenEnvField)
    return RielaAppNoteS3ProfileSettings(
      name: name,
      endpoint: endpoint,
      region: region,
      bucket: bucket,
      accessKeyIdEnv: accessKeyEnv,
      secretAccessKeyEnv: secretKeyEnv,
      sessionTokenEnv: sessionTokenEnv.isEmpty ? nil : sessionTokenEnv,
      keyPrefix: trimmed(s3KeyPrefixField)
    )
  }

  private func trimmed(_ field: NSTextField) -> String {
    field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return view
  }
}

private enum NoteSettingsS3ProfileEditorError: LocalizedError {
  case missingRequiredFields
  case invalidEndpoint
  case missingCredentialEnvironment

  var errorDescription: String? {
    switch self {
    case .missingRequiredFields:
      return "name, endpoint, region, and bucket are required."
    case .invalidEndpoint:
      return "endpoint must be a valid URL."
    case .missingCredentialEnvironment:
      return "access key and secret key environment variable names are required."
    }
  }
}
#endif
