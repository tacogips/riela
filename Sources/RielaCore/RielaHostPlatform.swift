public enum RielaHostPlatform: Equatable, Sendable {
  case darwin
  case other

  public static var current: Self {
    #if canImport(Darwin)
    .darwin
    #else
    .other
    #endif
  }
}
