import RielaCore
import XCTest
@testable import RielaGraphQL

final class ConfigurationGraphQLTests: XCTestCase {
  func testSchemaPublishesConfigurationQueriesAndMutations() {
    let schema = GraphQLContractProjector.schemaContract
    for token in [
      "configuration: RielaConfiguration!",
      "updateAssistantConfiguration(input: UpdateAssistantConfigurationInput!)",
      "updateAppearanceConfiguration(input: UpdateAppearanceConfigurationInput!)",
      "updateHTTPServerConfiguration(input: UpdateHTTPServerConfigurationInput!)"
    ] {
      XCTAssertTrue(schema.contains(token), token)
    }
  }

  func testLocalConfigurationQueryProjectsModelCatalogs() async throws {
    let provider = StubConfigurationProvider()
    let executor = RielaConfigGraphQLDocumentExecutor(provider: provider)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query WebConfiguration {
        configuration {
          profile revision
          assistant { vendor model modelCatalogs { vendor models } }
          server { configuredPort boundPort state }
        }
      }
      """,
      operationName: "WebConfiguration",
      isLocallyTrusted: true
    ))

    guard case let .object(data)? = response.body["data"],
          case let .object(configuration)? = data["configuration"],
          case let .object(assistant)? = configuration["assistant"],
          case let .array(catalogs)? = assistant["modelCatalogs"],
          case let .object(catalog) = catalogs[0] else {
      return XCTFail("missing configuration: \(response.body)")
    }
    XCTAssertEqual(configuration["profile"], .string("default"))
    XCTAssertEqual(configuration["revision"], .number(4))
    XCTAssertEqual(catalog["models"], .array([.string("live-model")]))
    XCTAssertNil(configuration["appearance"], "unselected fields must not leak")
  }

  func testAssistantMutationUsesTypedInput() async throws {
    let provider = StubConfigurationProvider()
    let executor = RielaConfigGraphQLDocumentExecutor(provider: provider)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Update($input: UpdateAssistantConfigurationInput!) {
        updateAssistantConfiguration(input: $input) { profile revision assistant { vendor model } }
      }
      """,
      variables: ["input": .object([
        "expectedRevision": .number(4),
        "expectedProfile": .string("default"),
        "vendor": .string("openai-api"),
        "model": .string("live-model")
      ])],
      operationName: "Update",
      isLocallyTrusted: true
    ))

    XCTAssertNil(response.body["errors"], "\(response.body)")
    let input = await provider.assistantInput
    XCTAssertEqual(input?.expectedRevision, 4)
    XCTAssertEqual(input?.expectedProfile, "default")
    XCTAssertEqual(input?.model, "live-model")
  }

  func testConfigurationIsUnavailableWithoutLocalRielaAppProvider() async {
    let response = await RielaConfigGraphQLDocumentExecutor().execute(GraphQLDocumentRequest(
      query: "query { configuration { revision } }"
    ))

    XCTAssertEqual(configurationErrorCode(response), "CONFIGURATION_UNAVAILABLE")
  }
}

private actor StubConfigurationProvider: RielaConfigurationGraphQLProviding {
  private(set) var assistantInput: GraphQLUpdateAssistantConfigurationInput?

  func configuration() async throws -> GraphQLRielaConfiguration {
    fixture()
  }

  func updateAssistant(
    input: GraphQLUpdateAssistantConfigurationInput
  ) async throws -> GraphQLRielaConfiguration {
    assistantInput = input
    return fixture()
  }

  func updateAppearance(
    input: GraphQLUpdateAppearanceConfigInput
  ) async throws -> GraphQLRielaConfiguration {
    fixture()
  }

  func updateHTTPServer(
    input: GraphQLUpdateHTTPServerConfigInput
  ) async throws -> GraphQLRielaConfiguration {
    fixture()
  }

  private func fixture() -> GraphQLRielaConfiguration {
    GraphQLRielaConfiguration(
      profile: "default",
      revision: 4,
      assistant: GraphQLAssistantConfiguration(
        assistance: "",
        vendor: "openai-api",
        model: "live-model",
        modelCatalogs: [GraphQLConfigurationModelCatalog(
          vendor: "openai-api",
          models: ["live-model"]
        )]
      ),
      appearance: GraphQLAppearanceConfiguration(colorScheme: "dark", options: ["dark", "light"]),
      server: GraphQLHTTPServerConfiguration(
        isEnabled: false,
        configuredPort: 19_091,
        boundPort: nil,
        restartRequired: false,
        state: "stopped"
      )
    )
  }
}

private func configurationErrorCode(_ response: GraphQLDocumentExecutionResponse) -> String? {
  guard case let .array(errors)? = response.body["errors"],
        case let .object(error)? = errors.first,
        case let .object(extensions)? = error["extensions"],
        case let .string(code)? = extensions["code"] else {
    return nil
  }
  return code
}
