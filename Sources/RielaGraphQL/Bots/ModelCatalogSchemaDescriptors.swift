extension GraphQLSchemaGenerator {
  static let modelCatalogTypes: [TypeDescriptor] = [
    .init(kind: .object, name: "CatalogModel", fields: [
      .init(name: "id", type: "String!"),
      .init(name: "label", type: "String"),
      .init(name: "sources", type: "[String!]!"),
      .init(name: "reasoningEfforts", type: "[String!]!"),
      .init(name: "serviceTiers", type: "[String!]!"),
      .init(name: "modes", type: "[String!]!"),
      .init(name: "observedAt", type: "String")
    ]),
    .init(kind: .object, name: "ProviderInstance", fields: [
      .init(name: "instanceId", type: "String!"),
      .init(name: "driver", type: "String!"),
      .init(name: "label", type: "String"),
      .init(name: "account", type: "String"),
      .init(name: "builtIn", type: "Boolean!"),
      .init(name: "availability", type: "String"),
      .init(name: "authentication", type: "String"),
      .init(name: "version", type: "String"),
      .init(name: "failures", type: "[String!]!"),
      .init(name: "probedAt", type: "String"),
      .init(name: "models", type: "[CatalogModel!]!"),
      .init(name: "origin", type: "BotOrigin!")
    ]),
    .init(kind: .object, name: "ModelCatalogPayload", fields: [
      .init(name: "providers", type: "[ProviderInstance!]!")
    ]),
    .init(kind: .object, name: "ProviderListPayload", fields: [
      .init(name: "providers", type: "[ProviderInstance!]!")
    ]),
    .init(kind: .object, name: "ProviderPayload", fields: [
      .init(name: "provider", type: "ProviderInstance!")
    ]),
    .init(kind: .input, name: "SaveProviderInstanceInput", fields: [
      .init(name: "instanceId", type: "String!"),
      .init(name: "driver", type: "String"),
      .init(name: "label", type: "String"),
      .init(name: "account", type: "String"),
      .init(name: "providerName", type: "String"),
      .init(name: "providerProxy", type: "String"),
      .init(name: "apiKeyEnvironment", type: "String"),
      .init(name: "customModels", type: "[String!]"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "RefreshProvidersInput", fields: [
      .init(name: "instanceId", type: "String"),
      .init(name: "remote", type: "String")
    ]),
    .init(kind: .input, name: "RemoveProviderInstanceInput", fields: [
      .init(name: "instanceId", type: "String!"),
      .init(name: "remote", type: "String")
    ])
  ]
}
