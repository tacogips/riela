import Foundation

public enum WorkflowAddonContainerRuntime: String, Codable, Sendable {
  case auto
  case appleContainer = "apple-container"
  case docker
  case podman
}

public enum WorkflowAddonContainerNetworkPolicy: String, Codable, Sendable {
  case denied
  case egressAllowed = "egress-allowed"
}

public struct WorkflowAddonContainerMount: Codable, Equatable, Sendable {
  public var source: String
  public var target: String
  public var readOnly: Bool

  public init(source: String, target: String, readOnly: Bool = true) {
    self.source = source
    self.target = target
    self.readOnly = readOnly
  }

  private enum CodingKeys: String, CodingKey { case source, target, readOnly }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    source = try values.decode(String.self, forKey: .source)
    target = try values.decode(String.self, forKey: .target)
    readOnly = try values.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true
  }
}

/// A common execution selection, independent of an add-on's own config.
/// An empty object selects the first-party worker image and runtime discovery.
public struct WorkflowAddonContainerExecution: Codable, Equatable, Sendable {
  public static let defaultImage = "riela-builtin-addons:local"
  public static let workerEntrypoint = "riela-addon-worker"
  public var image: String {
    didSet { imageWasSpecified = true }
  }
  public private(set) var imageWasSpecified: Bool
  public var runtime: WorkflowAddonContainerRuntime
  public var networkPolicy: WorkflowAddonContainerNetworkPolicy
  public var mounts: [WorkflowAddonContainerMount]

  public init(
    image: String? = nil,
    runtime: WorkflowAddonContainerRuntime = .auto,
    networkPolicy: WorkflowAddonContainerNetworkPolicy = .egressAllowed,
    mounts: [WorkflowAddonContainerMount] = []
  ) {
    self.image = image ?? Self.defaultImage
    imageWasSpecified = image != nil
    self.runtime = runtime
    self.networkPolicy = networkPolicy
    self.mounts = mounts
  }

  private enum CodingKeys: String, CodingKey { case image, runtime, networkPolicy, mounts }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    imageWasSpecified = values.contains(.image)
    image = try values.decodeIfPresent(String.self, forKey: .image) ?? Self.defaultImage
    runtime = try values.decodeIfPresent(WorkflowAddonContainerRuntime.self, forKey: .runtime) ?? .auto
    networkPolicy = try values.decodeIfPresent(WorkflowAddonContainerNetworkPolicy.self, forKey: .networkPolicy) ?? .egressAllowed
    mounts = try values.decodeIfPresent([WorkflowAddonContainerMount].self, forKey: .mounts) ?? []
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    if imageWasSpecified { try values.encode(image, forKey: .image) }
    try values.encode(runtime, forKey: .runtime)
    try values.encode(networkPolicy, forKey: .networkPolicy)
    try values.encode(mounts, forKey: .mounts)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.image == rhs.image && lhs.runtime == rhs.runtime && lhs.networkPolicy == rhs.networkPolicy && lhs.mounts == rhs.mounts
  }

  public func validate() throws {
    guard !image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !image.hasPrefix("-"),
          !image.contains(where: { $0.isWhitespace || $0.isNewline }), !image.contains("\0") else {
      throw AdapterExecutionError(.policyBlocked, "addon.container.image must be a non-empty image reference")
    }
    var targets = Set<String>()
    for mount in mounts {
      let target = URL(fileURLWithPath: mount.target).standardizedFileURL.path
      guard !mount.source.isEmpty, mount.source != "/", mount.target.hasPrefix("/"), target != "/",
            !mount.source.contains("\0"), !mount.source.contains(","), !mount.source.contains(":"),
            !target.contains("\0"), !target.contains(","), !target.contains(":"), targets.insert(target).inserted else {
        throw AdapterExecutionError(.policyBlocked, "addon.container.mounts require valid sources and distinct absolute targets")
      }
    }
  }
}
