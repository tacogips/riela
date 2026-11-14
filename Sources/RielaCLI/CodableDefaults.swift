import Foundation

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
