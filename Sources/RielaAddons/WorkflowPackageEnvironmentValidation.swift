import Foundation

public extension WorkflowPackageManifestValidator {
  static func isValidEnvironmentVariableName(_ name: String) -> Bool {
    guard let first = name.first, first == "_" || first.isLetter else {
      return false
    }
    return name.allSatisfy { character in
      character == "_" || character.isLetter || character.isNumber
    }
  }

  static func validateEnvironmentVariables(
    _ variables: [WorkflowPackageEnvironmentVariable],
    into issues: inout [WorkflowPackageValidationIssue]
  ) {
    var seen = Set<String>()
    for (index, variable) in variables.enumerated() {
      if !isValidEnvironmentVariableName(variable.name) {
        issues.append(.init(
          code: "INVALID_MANIFEST",
          path: "environmentVariables[\(index)].name",
          message: "environment variable name is invalid"
        ))
      }
      if !seen.insert(variable.name).inserted {
        issues.append(.init(
          code: "INVALID_MANIFEST",
          path: "environmentVariables[\(index)].name",
          message: "environment variable name is duplicated"
        ))
      }
    }
  }
}
