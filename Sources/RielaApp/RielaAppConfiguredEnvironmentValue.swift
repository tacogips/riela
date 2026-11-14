#if os(macOS)
struct RielaAppConfiguredEnvironmentValue: Equatable {
  var name: String
  var value: String
  var source: String
}
#endif
