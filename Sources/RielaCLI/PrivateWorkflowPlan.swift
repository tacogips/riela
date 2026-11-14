import Foundation
import RielaCore

struct PrivateWorkflowPlan: Codable, Sendable {
  var workflowId: String
  var definitionRoot: String
  var variables: JSONObject
  var outputSchema: JSONObject
  var maxSteps: Int?
  var maxConcurrency: Int?
  var timeoutSeconds: Int?
  var xUsageScope: String?

  init(config: JSONObject) throws {
    guard Set(config.keys).isSubset(of: ["workflowId", "definitionRoot", "variables", "outputSchema",
      "maxSteps", "maxConcurrency", "timeoutSeconds", "xUsageScope"]) else { throw Self.invalid() }
    var config = config
    config["definitionRoot"] = config["definitionRoot"] ?? .string("/app/workflows")
    config["variables"] = config["variables"] ?? .object([:])
    self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(config))
    try validate()
  }

  func validate() throws {
    if let xUsageScope, xUsageScope.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) == nil { throw Self.invalid() }
    guard workflowId.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil,
          workflowId != ".", workflowId != "..", definitionRoot.hasPrefix("/"), definitionRoot != "/",
          !definitionRoot.contains("\0"), URL(fileURLWithPath: definitionRoot).standardizedFileURL.path == definitionRoot,
          (1...10_000).contains(maxSteps ?? 1000), (1...16).contains(maxConcurrency ?? 4),
          (1...3600).contains(timeoutSeconds ?? 600),
          try JSONEncoder().encode(outputSchema).count <= 1_000_000,
          DefaultWorkflowOutputValidator().validateContractSchema(outputSchema) == nil else { throw Self.invalid() }
  }

  static func validateEnvironment(_ environment: [String: String]) throws {
    let reserved: Set<String> = ["HOME", "PATH", "TMPDIR", "TMP", "TEMP", "ENV", "BASH_ENV", "ZDOTDIR",
      "NODE_OPTIONS", "NODE_PATH", "PERL5OPT", "RUBYOPT", "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS"]
    guard environment.count <= 64 else { throw invalid() }
    for (name, value) in environment {
      guard name.range(of: #"^[A-Z][A-Z0-9_]{0,127}$"#, options: .regularExpression) != nil,
            !reserved.contains(name), !["RIELA_", "LD_", "DYLD_", "PYTHON", "SWIFT_"].contains(where: name.hasPrefix),
            !value.isEmpty, !value.contains("\0"), value.utf8.count <= 1_000_000 else { throw invalid() }
    }
  }

  static func invalid() -> AdapterExecutionError { .init(.invalidInput, "invalid private workflow configuration") }
}

struct PrivateWorkflowRequest: Codable, Sendable {
  var version = 1
  var plan: PrivateWorkflowPlan
  var deadline: Date
  var environment: [String: String]
  var credentials: [SandboxRuntimeCredential]
}
