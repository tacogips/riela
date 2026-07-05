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
  public static let noteAddons: [RielaAddonDescriptor] = [
    .init(name: "riela/note-create", version: "1"),
    .init(name: "riela/note-update", version: "1"),
    .init(name: "riela/note-get", version: "1"),
    .init(name: "riela/note-search", version: "1"),
    .init(name: "riela/note-tag-apply", version: "1"),
    .init(name: "riela/note-attach-file", version: "1"),
    .init(name: "riela/note-graphql-document", version: "1"),
    .init(name: "riela/note-comment-add", version: "1"),
    .init(name: "riela/notebook-ingest-pages", version: "1"),
    .init(name: "riela/note-conversation-save", version: "1")
  ]

  public static let all: [RielaAddonDescriptor] = noteAddons

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
