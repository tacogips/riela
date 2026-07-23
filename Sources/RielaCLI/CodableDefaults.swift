import Foundation
import RielaCore

@propertyWrapper
public struct CodableDefaultFalse: Codable, Equatable, Sendable {
  public var wrappedValue: Bool

  public init(wrappedValue: Bool = false) {
    self.wrappedValue = wrappedValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    wrappedValue = try container.decode(Bool.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wrappedValue)
  }
}

extension KeyedDecodingContainer {
  func decode(_ type: CodableDefaultFalse.Type, forKey key: Key) throws -> CodableDefaultFalse {
    try decodeIfPresent(type, forKey: key) ?? CodableDefaultFalse()
  }
}

@propertyWrapper
public struct CodableDefaultImmutable: Codable, Equatable, Sendable {
  public var wrappedValue: WorkflowProvenance

  public init(wrappedValue: WorkflowProvenance = .immutable) {
    self.wrappedValue = wrappedValue
  }
}

@propertyWrapper
public struct CodableDefaultActive: Codable, Equatable, Sendable {
  public var wrappedValue: WorkflowActivationState

  public init(wrappedValue: WorkflowActivationState = .active) {
    self.wrappedValue = wrappedValue
  }
}

extension KeyedDecodingContainer {
  func decode(_ type: CodableDefaultImmutable.Type, forKey key: Key) throws -> CodableDefaultImmutable {
    try decodeIfPresent(type, forKey: key) ?? CodableDefaultImmutable()
  }

  func decode(_ type: CodableDefaultActive.Type, forKey key: Key) throws -> CodableDefaultActive {
    try decodeIfPresent(type, forKey: key) ?? CodableDefaultActive()
  }
}
