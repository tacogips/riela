extension SurfaceCatalog {
  static let askRows: [SurfaceOperation] = {
    let design = "design-docs/specs/design-ask-riela-chat.md#13-control-surfaces"
    let defaults = SurfaceRowDefaults(
      cli: .excluded(reason: "riela ask --conversation uses the ask command", design: design),
      graphql: SurfaceExclusion.localProcess("Ask Riela"),
      webAPI: .excluded(reason: "Ask operations use GraphQL", design: design),
      library: SurfaceExclusion.notALibraryEntryPoint("Ask Riela"),
      design: design
    )
    let storeOptions = ["--remote", "--output", "--session-store", "--scope", "--working-dir"]
    return [
      surfaceRow(
        defaults, id: "ask.send", family: "ask", kind: .mutation, cli: "ask",
        cliOptions: storeOptions + ["--conversation", "--session", "--bot", "--workflow", "--provider", "--model", "--effort", "--no-follow"],
        graphql: graphQLMutation("startAsk")
      ),
      surfaceRow(defaults, id: "ask.reply", family: "ask", kind: .mutation,
                 graphql: graphQLMutation("sendAskMessage")),
      surfaceRow(defaults, id: "ask.list", family: "ask", kind: .query, cli: "ask list",
                 cliOptions: storeOptions, graphql: graphQLQuery("askConversations")),
      surfaceRow(defaults, id: "ask.show", family: "ask", kind: .query, cli: "ask show",
                 cliOptions: storeOptions + ["--follow"], graphql: graphQLQuery("askConversation")),
      surfaceRow(
        defaults, id: "ask.activity", family: "ask", kind: .stream,
        cliState: .excluded(reason: "riela ask and riela ask show --follow read this stream", design: design),
        graphql: graphQLQuery("askActivity")
      ),
      surfaceRow(defaults, id: "ask.cancel", family: "ask", kind: .mutation, cli: "ask cancel",
                 cliOptions: storeOptions, graphql: graphQLMutation("cancelAsk")),
      surfaceRow(defaults, id: "ask.confirm", family: "ask", kind: .mutation, cli: "ask confirm",
                 cliOptions: storeOptions, graphql: graphQLMutation("confirmAskAction")),
      surfaceRow(defaults, id: "ask.dismiss", family: "ask", kind: .mutation, cli: "ask dismiss",
                 cliOptions: storeOptions, graphql: graphQLMutation("dismissAskAction")),
      surfaceRow(defaults, id: "ask.remove", family: "ask", kind: .mutation, cli: "ask remove",
                 cliOptions: storeOptions, graphql: graphQLMutation("removeAskConversation")),
      surfaceRow(
        defaults, id: "ask.tool-server", family: "ask", kind: .stream, cli: "ask tool-server",
        cliOptions: ["--session-store", "--working-dir", "--conversation", "--turn", "--scope", "--redaction-values"],
        graphqlState: .excluded(reason: "Local stdio process started by the vendor CLI", design: design)
      )
    ]
  }()
}
