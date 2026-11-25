import Foundation
import RielaCore
import RielaGraphQL
import Testing

struct AskGraphQLTests {
  @Test func dispatchesAllRootsWithTypedArguments() async throws {
    let provider = try RecordingAskProvider()
    let executor = AskGraphQLDocumentExecutor(provider: provider)
    let docs = [
      #"query { askConversations(remote:"srv") { origin { remote } } }"#,
      #"query { askConversation(conversationId:"id",remote:"srv") { conversation { title } } }"#,
      #"query { askActivity(conversationId:"id",afterSequence:7,limit:9,waitMs:12,remote:"srv") { turnStatus } }"#,
      #"mutation { startAsk(input:{message:"hi",context:{kind:"session",id:"run"},selection:{model:"example"},remote:"srv"}) { warnings } }"#,
      #"mutation { sendAskMessage(input:{conversationId:"id",message:"again",draftDefinition:{title:"draft"}}) { warnings } }"#,
      #"mutation { cancelAsk(input:{conversationId:"id",remote:"srv"}) { warnings } }"#,
      #"mutation { confirmAskAction(input:{conversationId:"id",actionId:"action",remote:"srv"}) { warnings } }"#,
      #"mutation { dismissAskAction(input:{conversationId:"id",actionId:"action",remote:"srv"}) { warnings } }"#,
      #"mutation { removeAskConversation(input:{conversationId:"id",remote:"srv"}) { conversations { title } } }"#
    ]
    for document in docs {
      let response = await executor.execute(request(document))
      #expect(response.handled)
      #expect(response.body["errors"] == nil)
    }
    let calls = await provider.calls
    #expect(calls == [
      "list:srv", "show:id:srv", "activity:id:7:9:12:srv", "start:hi:session:run:example:srv", "send:id:again:draft",
      "cancel:id:srv", "confirm:id:action:srv", "dismiss:id:action:srv", "remove:id:srv"
    ])
  }

  @Test func validatesInputsAndPreservesAskErrorCodes() async throws {
    let provider = try RecordingAskProvider()
    let executor = AskGraphQLDocumentExecutor(provider: provider)
    for input in [#"{}"#, #"{message:"hi",context:{kind:"unknown"}}"#] {
      let response = await executor.execute(request("mutation { startAsk(input:\(input)) { warnings } }"))
      #expect(String(describing: response.body["errors"]).contains("INVALID_ASK"))
    }
    let denied = await executor.execute(.init(query: "{ askConversations { origin { remote } } }", environment: [:]))
    #expect(String(describing: denied.body["errors"]).contains("ASK_UNAVAILABLE"))
    #expect(await provider.calls.isEmpty)
    let running = await executor.execute(request(#"mutation { startAsk(input:{message:"busy"}) { warnings } }"#))
    #expect(String(describing: running.body["errors"]).contains("ask_turn_running"))
  }

  @Test func generatedPayloadSelectionRoundTrips() async throws {
    let executor = AskGraphQLDocumentExecutor(provider: try RecordingAskProvider())
    let document = try GraphQLSelectionBuilder.document(for: "Query.askConversation", arguments: ["conversationId"])
    let response = await executor.execute(.init(
      query: document.query, variables: ["conversationId": .string("id")], environment: [:], isLocallyTrusted: true
    ))
    #expect(response.body["errors"] == nil)
    guard case let .object(data)? = response.body["data"] else { Issue.record("Missing data"); return }
    let value = try #require(data["askConversation"])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(AskConversationPayload.self, from: JSONEncoder().encode(value))
    #expect(snapshot.conversation.conversationId == "id")
    #expect(snapshot.conversation.turn?.status == .completed)
  }

  private func request(_ query: String) -> GraphQLDocumentRequest {
    .init(query: query, environment: [:], isLocallyTrusted: true)
  }
}

private actor RecordingAskProvider: AskGraphQLProviding {
  private(set) var calls: [String] = []
  private let payload: AskConversationPayload

  init() throws {
    let conversation = try JSONDecoder().decode(AskConversation.self, from: Data("""
    {
      "conversationId":"id","title":"Example","context":{"kind":"none"},"selection":{},
      "usage":{"turns":1,"toolCalls":0,"toolBytes":0},"createdAt":"now","updatedAt":"now",
      "turn":{"turnId":"turn-1","status":"completed","startedAt":"now","backend":"fixture",
        "providerInstanceId":"fixture","toolTransport":"rounds","limitedPolicy":false,"runnerId":"runner",
        "heartbeatAt":"now","toolCalls":0,"toolBytes":0}
    }
    """.utf8))
    payload = .init(
      conversation: conversation, messages: [], actions: [], limits: .standard, warnings: [],
      origin: .local(serverId: nil, serverName: nil, at: Date(timeIntervalSince1970: 0))
    )
  }

  func askConversations(remote: String?) -> AskConversationListPayload {
    calls.append("list:\(remote ?? "")")
    return .init(conversations: [payload.conversation], origin: payload.origin)
  }

  func askConversation(conversationId: String, remote: String?) -> AskConversationPayload {
    calls.append("show:\(conversationId):\(remote ?? "")")
    return payload
  }

  func askActivity(conversationId: String, afterSequence: Int, limit: Int, waitMs: Int, remote: String?) -> AskActivityPage {
    calls.append("activity:\(conversationId):\(afterSequence):\(limit):\(waitMs):\(remote ?? "")")
    return .init(
      events: [], state: nil, lastSequence: afterSequence, firstRetainedSequence: 1, truncated: false,
      activitySource: "acp", turnStatus: "completed", origin: payload.origin
    )
  }

  func startAsk(input: StartAskInput) throws -> AskConversationPayload {
    if input.message == "busy" { throw AskError(code: "ask_turn_running", message: "Busy") }
    let context = input.context ?? AskContext()
    calls.append("start:\(input.message):\(context.kind.rawValue):\(context.id ?? ""):\(input.selection?.model ?? ""):\(input.remote ?? "")")
    return payload
  }

  func sendAskMessage(input: SendAskMessageInput) -> AskConversationPayload {
    let draft = input.draftDefinition?["title"] == .string("draft") ? "draft" : ""
    calls.append("send:\(input.conversationId):\(input.message):\(draft)")
    return payload
  }

  func cancelAsk(input: AskConversationInput) -> AskConversationPayload {
    calls.append("cancel:\(input.conversationId):\(input.remote ?? "")")
    return payload
  }

  func confirmAskAction(input: AskActionInput) -> AskConversationPayload {
    calls.append("confirm:\(input.conversationId):\(input.actionId):\(input.remote ?? "")")
    return payload
  }

  func dismissAskAction(input: AskActionInput) -> AskConversationPayload {
    calls.append("dismiss:\(input.conversationId):\(input.actionId):\(input.remote ?? "")")
    return payload
  }

  func removeAskConversation(input: AskConversationInput) -> AskConversationListPayload {
    calls.append("remove:\(input.conversationId):\(input.remote ?? "")")
    return .init(conversations: [], origin: payload.origin)
  }
}
