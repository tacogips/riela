import Foundation
import RielaCore

/// Typed loop finding for the `--format json` output of `loop findings`.
public struct LoopFindingExport: Codable, Equatable, Sendable {
  public var gateId: String
  public var findingId: String
  public var severity: String
  public var level: String
  public var message: String
  public var filePath: String?
  public var line: Int?

  public init(
    gateId: String,
    findingId: String,
    severity: String,
    level: String,
    message: String,
    filePath: String?,
    line: Int?
  ) {
    self.gateId = gateId
    self.findingId = findingId
    self.severity = severity
    self.level = level
    self.message = message
    self.filePath = filePath
    self.line = line
  }
}

/// Exports loop blocking findings as SARIF 2.1.0 (and as typed findings).
///
/// One run, `tool.driver.name = "riela-loop"`, one rule per reported gateId, one
/// result per blocking finding. Severity maps high→error, medium→warning,
/// low|informational→note, and any unknown severity string→warning with the
/// original value preserved in `result.properties.severity`. A `physicalLocation`
/// is emitted only when the finding carries a file path. No environment or
/// variable values are ever included.
public enum LoopFindingsSARIFExporter {
  public static let sarifVersion = "2.1.0"

  public static func level(forSeverity severity: String) -> String {
    switch severity.lowercased() {
    case "high", "critical": return "error"
    case "medium": return "warning"
    case "low", "informational", "info", "note": return "note"
    default: return "warning"
    }
  }

  /// Flattened typed findings (deterministic order: by gateId, then finding id).
  public static func findings(manifest: LoopEvidenceManifest, gateId: String?) -> [LoopFindingExport] {
    var exports: [LoopFindingExport] = []
    for gate in manifest.gates where gateId == nil || gate.gateId == gateId {
      for finding in gate.blockingFindings {
        exports.append(LoopFindingExport(
          gateId: gate.gateId,
          findingId: finding.id,
          severity: finding.severity,
          level: level(forSeverity: finding.severity),
          message: finding.message,
          filePath: finding.filePath,
          line: finding.line
        ))
      }
    }
    return exports.sorted {
      $0.gateId != $1.gateId ? $0.gateId < $1.gateId : $0.findingId < $1.findingId
    }
  }

  public static func sarif(manifest: LoopEvidenceManifest, gateId: String?) -> JSONObject {
    let exports = findings(manifest: manifest, gateId: gateId)
    let ruleIds = orderedUnique(exports.map(\.gateId))
    let rules: [JSONValue] = ruleIds.map { id in
      .object([
        "id": .string(id),
        "name": .string(id)
      ])
    }
    let results: [JSONValue] = exports.map { finding in
      var properties: JSONObject = [
        "sessionId": .string(manifest.sessionId),
        "gateId": .string(finding.gateId),
        "severity": .string(finding.severity)
      ]
      if let filePath = finding.filePath {
        properties["filePath"] = .string(filePath)
      }
      var result: JSONObject = [
        "ruleId": .string(finding.gateId),
        "level": .string(finding.level),
        "message": .object(["text": .string(finding.message)]),
        "properties": .object(properties)
      ]
      if let filePath = finding.filePath {
        var region: JSONObject = [:]
        if let line = finding.line { region["startLine"] = .integer(Int64(line)) }
        var physical: JSONObject = ["artifactLocation": .object(["uri": .string(filePath)])]
        if !region.isEmpty { physical["region"] = .object(region) }
        result["locations"] = .array([.object(["physicalLocation": .object(physical)])])
      }
      return .object(result)
    }
    return [
      "version": .string(sarifVersion),
      "$schema": .string("https://json.schemastore.org/sarif-2.1.0.json"),
      "runs": .array([
        .object([
          "tool": .object([
            "driver": .object([
              "name": .string("riela-loop"),
              "informationUri": .string("https://github.com/tacogips/riela"),
              "rules": .array(rules)
            ])
          ]),
          "results": .array(results)
        ])
      ])
    ]
  }

  private static func orderedUnique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var ordered: [String] = []
    for value in values where !seen.contains(value) {
      seen.insert(value)
      ordered.append(value)
    }
    return ordered
  }
}
