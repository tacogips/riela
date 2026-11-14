import RielaAddonSupport
import RielaCore

enum XGatewayFailureCategory: String, Sendable {
  case spendCapReached = "spend-cap-reached"
  case rateLimited = "rate-limited"
  case auth
  case permission
  case invalidRequest = "invalid-request"
  case notFound = "not-found"
  case transient
  case unknown

  var retryable: Bool { self == .rateLimited || self == .transient }

  static func classify(_ diagnostics: JSONObject) -> XGatewayFailureCategory {
    let code = xGatewayDiagnosticString(diagnostics, key: "code")
    let problem = xGatewayDiagnosticString(diagnostics, key: "providerProblem")
    let reason = xGatewayDiagnosticString(diagnostics, key: "providerReason")
    let classification = xGatewayDiagnosticString(diagnostics, key: "classification")
    let status = diagnostics["httpStatus"]?.asInt64

    if ["spend-cap-reached", "usage-capped"].contains(problem) || reason == "usage-capped" {
      return .spendCapReached
    }
    if ["RATE_LIMITED", "PROVIDER_RATE_LIMITED"].contains(code) || problem == "rate-limit-exceeded"
      || classification == "rate_limit" || status == 429 {
      return .rateLimited
    }
    if code.hasPrefix("AUTH_") || code == "CREDENTIAL_NOT_FOUND" || classification == "auth" || status == 401 {
      return .auth
    }
    if ["PERMISSION_DENIED", "ACCESS_MODE_INSUFFICIENT"].contains(code) || classification == "permission"
      || ["client-forbidden", "not-authorized-for-resource", "unsupported-authentication", "insufficient-scope"]
        .contains(problem) || status == 403 {
      return .permission
    }
    if ["VALIDATION_ERROR", "INVALID_ARGUMENT", "CONFIG_INVALID"].contains(code) || classification == "validation"
      || problem == "invalid-request" || status == 400 || status == 422 {
      return .invalidRequest
    }
    if code == "RESOURCE_NOT_FOUND" || problem == "resource-not-found" || status == 404 { return .notFound }
    if code == "NETWORK_FAILURE"
      || (code == "UPSTREAM_FAILURE" && (status.map { $0 >= 500 } ?? true))
      || ["network", "upstream"].contains(classification) || diagnostics["retryable"] == .bool(true) {
      return .transient
    }
    return .unknown
  }
}

func xGatewayProviderFailureOutput(
  _ error: AdapterExecutionError,
  input: WorkflowAddonExecutionInput,
  provider: String
) -> AdapterExecutionOutput? {
  guard error.code == .providerError else { return nil }
  let diagnostics = GatewayFailureDiagnostics.fields(readerMessage: error.message)
  guard xGatewayDiagnosticString(diagnostics, key: "code").isEmpty == false else { return nil }
  let category = XGatewayFailureCategory.classify(diagnostics)
  return AdapterExecutionOutput(
    provider: provider,
    model: input.addon.name,
    promptText: "",
    completionPassed: true,
    when: [
      "providerFailed": true,
      "providerRetryable": category.retryable,
      "spendCapReached": category == .spendCapReached,
      "rateLimited": category == .rateLimited
    ],
    payload: [
      "status": .string("provider-failed"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "xGateway": .object(["failure": .object([
        "category": .string(category.rawValue),
        "retryable": .bool(category.retryable),
        "diagnostics": .object(diagnostics)
      ])])
    ]
  )
}

private func xGatewayDiagnosticString(_ diagnostics: JSONObject, key: String) -> String {
  guard case let .string(value)? = diagnostics[key] else { return "" }
  return value
}

func xGatewayMarkProviderSuccess(_ output: inout AdapterExecutionOutput) {
  output.when["providerFailed"] = false
  output.when["providerRetryable"] = false
  output.when["spendCapReached"] = false
  output.when["rateLimited"] = false
}
