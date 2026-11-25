extension SurfaceCatalog {
  static let botFamilyRows: [SurfaceOperation] = [
    botRow("create", mutation: "createBot", options: botRecordOptions + ["--id"]),
    botRow("list", query: "bots", options: ["--group-by"]),
    botRow("show", query: "bot"),
    botRow("update", mutation: "updateBot", options: botRecordOptions),
    botRow("pause", mutation: "setBotPaused"),
    botRow("resume", sharesMutation: "setBotPaused"),
    botRow("remove", mutation: "removeBot"),
    botRow("activity", query: "botActivity", options: ["--session", "--after", "--limit", "--follow"], stream: true),
    botRow("answer", mutation: "answerBotRequest", options: ["--option", "--decline"]),
    botRow("pin", mutation: "setBotListState", options: ["--item"]),
    botRow("unpin", sharesMutation: "setBotListState", options: ["--item"]),
    botRow("move", sharesMutation: "setBotListState", options: ["--item", "--position"]),
    botRow("snooze", sharesMutation: "setBotListState", options: ["--item", "--until", "--for"]),
    botRow("unsnooze", sharesMutation: "setBotListState", options: ["--item"]),
    botRow("settle", sharesMutation: "setBotListState", options: ["--item"]),
    botRow("unsettle", sharesMutation: "setBotListState", options: ["--item"]),
    catalogRow("model", "list", query: "modelCatalog", options: ["--provider"]),
    catalogRow("provider", "list", query: "providers"),
    catalogRow("provider", "show", query: "provider"),
    catalogRow("provider", "refresh", mutation: "refreshProviders"),
    catalogRow("provider", "add", mutation: "saveProviderInstance", options: providerRecordOptions + ["--id"]),
    catalogRow("provider", "update", options: providerRecordOptions + ["--clear-custom-models"]),
    catalogRow("provider", "remove", mutation: "removeProviderInstance")
  ]

  private static let providerRecordOptions = [
    "--driver", "--label", "--account", "--provider-name", "--provider-proxy", "--api-key-env", "--custom-model"
  ]

  private static func catalogRow(
    _ family: String, _ verb: String, query: String? = nil, mutation: String? = nil, options: [String] = []
  ) -> SurfaceOperation {
    let design = "design-docs/specs/design-bots-overview.md#75-surfaces"
    let defaults = SurfaceRowDefaults(
      cli: SurfaceExclusion.consoleOnly("this catalog operation"),
      graphql: SurfaceExclusion.localProcess("this catalog operation"),
      webAPI: .excluded(reason: "Catalog operations use GraphQL", design: design),
      library: SurfaceExclusion.notALibraryEntryPoint("catalog management"),
      design: design
    )
    return surfaceRow(
      defaults, id: "\(family).\(verb)", family: family, kind: query == nil ? .mutation : .query,
      cli: "\(family) \(verb)", cliOptions: options + ["--session-store", "--scope", "--working-dir", "--output"],
      graphql: query.map(graphQLQuery) ?? mutation.map(graphQLMutation),
      graphqlState: verb == "update" ? .excluded(
        reason: "This CLI verb shares Mutation.saveProviderInstance", design: design
      ) : nil
    )
  }

  private static let botDesign = "design-docs/specs/design-bots-overview.md#12-control-surfaces"
  private static let botRecordOptions = [
    "--name", "--purpose", "--persona", "--backend", "--model", "--provider", "--workspace",
    "--memory-upkeep", "--look-around", "--permission-wait-ms"
  ]

  private static func botRow(
    _ verb: String, query: String? = nil, mutation: String? = nil,
    sharesMutation: String? = nil, options: [String] = [], stream: Bool = false
  ) -> SurfaceOperation {
    let defaults = SurfaceRowDefaults(
      cli: SurfaceExclusion.consoleOnly("this bot operation"),
      graphql: SurfaceExclusion.localProcess("this bot operation"),
      webAPI: .excluded(reason: "Bot operations use GraphQL", design: botDesign),
      library: SurfaceExclusion.notALibraryEntryPoint("bot management"),
      design: botDesign
    )
    let kind: SurfaceOperation.Kind = stream ? .stream : (query == nil ? .mutation : .query)
    return surfaceRow(
      defaults, id: "bot.\(verb)", family: "bot", kind: kind,
      cli: "bot \(verb)", cliOptions: options + ["--session-store", "--scope", "--working-dir", "--output"],
      graphql: query.map(graphQLQuery) ?? mutation.map(graphQLMutation),
      graphqlState: sharesMutation.map {
        .excluded(reason: "This CLI verb shares Mutation.\($0)", design: botDesign)
      },
      desktop: query != nil || verb == "create" ? .implemented : nil
    )
  }
}
