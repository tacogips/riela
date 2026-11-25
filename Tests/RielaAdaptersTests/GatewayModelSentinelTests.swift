import AgentGateway
import AgentGatewayAppCore
import Testing
@testable import RielaAdapters
import RielaCore

@Suite struct GatewayModelSentinelTests {
  @Test(arguments: ["default", "gpt-x"]) func resolvesNodeModel(_ requested: String) async throws {
    let executor = ModelExecutor()
    let adapter = AgentGatewayNodeAdapter(executorFactory: { _ in executor })
    let output = try await adapter.execute(
      .init(node: .init(id: "worker", executionBackend: .codexAgent, model: requested), promptText: "test"),
      context: .init()
    )
    #expect(await executor.model == (requested == "default" ? "" : requested))
    #expect(output.model == requested)
  }

  @Test func prefersReportedModelForSentinel() async throws {
    let executor = ModelExecutor(reported: "provider-model")
    let adapter = AgentGatewayNodeAdapter(executorFactory: { _ in executor })
    let output = try await adapter.execute(
      .init(node: .init(id: "worker", executionBackend: .codexAgent, model: "default"), promptText: "test"),
      context: .init()
    )
    #expect(await executor.model == "")
    #expect(output.model == "provider-model")
  }

  private actor ModelExecutor: GatewayExecuting {
    private(set) var model: String?
    let reported: String

    init(reported: String = "") { self.reported = reported }

    func execute(_ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter) async throws -> GatewayExecuteResult {
      model = params.model
      return .init(vendor: params.vendor, model: reported, text: "ok")
    }
  }
}
