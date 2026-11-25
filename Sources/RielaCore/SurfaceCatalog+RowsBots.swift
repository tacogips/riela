extension SurfaceCatalog {
  static let botFamilyRows: [SurfaceOperation] = [
    botRow("create", mutation: "createBot", options: botRecordOptions + ["--id"]),
    botRow("list", query: "bots", options: ["--group-by"]),
    botRow("show", query: "bot", options: ["--memory-root"]),
    botRow("update", mutation: "updateBot", options: botRecordOptions),
    botRow("pause", mutation: "setBotPaused"),
    botRow("resume", sharesMutation: "setBotPaused"),
    botRow("remove", mutation: "removeBot"),
    botRow("activity", query: "botActivity", options: ["--session", "--after", "--limit", "--follow"], stream: true),
    botRow("memory.show", query: "botMemory", options: ["--memory-root"]),
    botRow("memory.export", options: ["--out", "--force", "--memory-root"], graphqlExclusion: "This CLI verb shares Query.botMemory"),
    botRow("memory.edit", mutation: "updateBotMemory", options: ["--file", "--reason", "--memory-root"]),
    botRow("memory.history", query: "botMemoryHistory", options: ["--limit", "--memory-root"]),
    botRow("memory.diff", query: "botMemoryDiff", options: ["--memory-root"]),
    botRow("memory.undo", mutation: "undoBotMemoryChange", options: ["--memory-root"]),
    botRow("feedback", mutation: "captureBotFeedback", options: ["--session", "--task", "--text", "--topic", "--from-findings", "--memory-root"]),
    botRow("job.run", mutation: "runBotJob", options: ["--force", "--mock-scenario"]),
    botRow("job.list", query: "botJobHistory", options: ["--job", "--limit"]),
    botRow("suggestion.list", query: "botSuggestions", options: ["--status"]),
    botRow("suggestion.accept", mutation: "decideBotSuggestion", options: ["--run", "--mock-scenario"]),
    botRow("suggestion.dismiss", sharesMutation: "decideBotSuggestion", options: ["--reason"]),
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

  static let remoteRows: [SurfaceOperation] = {
    let design = "design-docs/specs/design-bots-overview.md#114-client-commands"
    let defaults = SurfaceRowDefaults(
      cli: SurfaceExclusion.localProcess("remote registry management"),
      graphql: SurfaceExclusion.localProcess("remote registry management"),
      webAPI: .excluded(reason: "Remote registry operations use GraphQL", design: design),
      library: SurfaceExclusion.notALibraryEntryPoint("remote registry management"),
      design: design
    )
    return [
      surfaceRow(defaults, id: "remote.add", family: "remote", kind: .mutation,
                 cli: "remote add", cliOptions: ["--name", "--code", "--client-name", "--output"],
                 graphql: graphQLMutation("addRemote")),
      surfaceRow(defaults, id: "remote.list", family: "remote", kind: .query,
                 cli: "remote list", cliOptions: ["--output"], graphql: graphQLQuery("remotes")),
      surfaceRow(defaults, id: "remote.show", family: "remote", kind: .query,
                 cli: "remote show", cliOptions: ["--output"],
                 graphqlState: .excluded(reason: "Shares Query.remotes with remote list", design: design)),
      surfaceRow(defaults, id: "remote.remove", family: "remote", kind: .mutation,
                 cli: "remote remove", cliOptions: ["--output"], graphql: graphQLMutation("removeRemote")),
      surfaceRow(defaults, id: "remote.use", family: "remote", kind: .mutation,
                 cli: "remote use", cliOptions: ["--output"], graphql: graphQLMutation("useRemote"))
    ]
  }()

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
      cli: "\(family) \(verb)", cliOptions: options + ["--session-store", "--scope", "--working-dir", "--output", "--remote"]
        + (verb == "list" ? ["--all-remotes"] : []),
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
    sharesMutation: String? = nil, options: [String] = [], stream: Bool = false, graphqlExclusion: String? = nil
  ) -> SurfaceOperation {
    let defaults = SurfaceRowDefaults(
      cli: SurfaceExclusion.consoleOnly("this bot operation"),
      graphql: SurfaceExclusion.localProcess("this bot operation"),
      webAPI: .excluded(reason: "Bot operations use GraphQL", design: botDesign),
      library: SurfaceExclusion.notALibraryEntryPoint("bot management"),
      design: botDesign
    )
    let kind: SurfaceOperation.Kind = stream ? .stream : (query != nil || graphqlExclusion != nil ? .query : .mutation)
    let exclusion = graphqlExclusion ?? sharesMutation.map { "This CLI verb shares Mutation.\($0)" }
    let command = verb.split(separator: ".").joined(separator: " ")
    return surfaceRow(
      defaults, id: "bot.\(verb)", family: "bot", kind: kind,
      cli: "bot \(command)", cliOptions: options + ["--session-store", "--scope", "--working-dir", "--output", "--remote"]
        + (["list", "suggestion.list"].contains(verb) ? ["--all-remotes"] : []),
      graphql: query.map(graphQLQuery) ?? mutation.map(graphQLMutation),
      graphqlState: exclusion.map { .excluded(reason: $0, design: botDesign) },
      desktop: query != nil || verb == "create" ? .implemented : nil
    )
  }
}
