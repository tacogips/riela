import RielaCore

public extension BuiltinAddonKaibaInstance {
  init(instance: KaibaInstance) {
    self.init(id: instance.id, name: instance.name, endpoint: instance.endpoint,
      credentialEnvironmentVariable: instance.authentication.credentialEnvironmentVariable,
      allowInsecureHTTP: instance.allowInsecureHTTP,
      allowRemoteUnauthenticated: instance.allowRemoteUnauthenticated)
  }

  /// A guest receives only the selected instance, preserving its stable ID and
  /// connection policy. The host's default/catalog may change independently.
  var instance: KaibaInstance {
    .init(id: id, name: name, endpoint: endpoint,
      authentication: credentialEnvironmentVariable.map { .bearer(environmentVariable: $0) } ?? .unauthenticated,
      isDefault: true, allowInsecureHTTP: allowInsecureHTTP,
      allowRemoteUnauthenticated: allowRemoteUnauthenticated)
  }
}
