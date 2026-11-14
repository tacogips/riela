import XGatewayCore

/// The X SDK exposes its read schema as an in-process, credential-free CLI
/// command. Keep only Query root names here; the SDK remains the type authority.
enum XGatewayOperationCatalog {
  private static let maximumSDLBytes = 2 * 1_024 * 1_024
  private static let maximumOperationCount = 1_024

  static let queryOperationNames: Set<String>? = {
    let cli = XGatewayCLI(commandName: "x-gateway-reader", surface: .read)
    let result = cli.run(arguments: ["graphql", "schema"], environment: [:])
    guard result.exitCode == 0 else { return nil }
    return parseQueryOperationNames(result.stdout)
  }()

  static func parseQueryOperationNames(_ sdl: String) -> Set<String>? {
    guard sdl.utf8.count <= maximumSDLBytes else { return nil }
    let lines = sdl.split(separator: "\n", omittingEmptySubsequences: false)
    var insideQuery = false
    var names = Set<String>()

    for rawLine in lines {
      let indentationCount = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
      let line = rawLine.drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" })
      if !insideQuery {
        guard line == "type Query {" else { continue }
        insideQuery = true
        continue
      }
      if line == "}" {
        return names.isEmpty ? nil : names
      }
      guard indentationCount == 2 else { continue }
      guard let fieldName = rootFieldName(in: line) else { continue }
      names.insert(fieldName)
      guard names.count <= maximumOperationCount else { return nil }
    }
    return nil
  }

  private static func rootFieldName(in line: Substring) -> String? {
    let bytes = Array(line.utf8)
    guard let first = bytes.first, isNameStart(first) else { return nil }
    var end = 1
    while end < bytes.count, isNameByte(bytes[end]) { end += 1 }
    var suffix = end
    while suffix < bytes.count && (bytes[suffix] == 32 || bytes[suffix] == 9) { suffix += 1 }
    guard suffix < bytes.count, bytes[suffix] == 40 || bytes[suffix] == 58 else { return nil }
    return String(bytes: bytes[..<end], encoding: .utf8)
  }

  private static func isNameStart(_ byte: UInt8) -> Bool {
    byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
  }

  private static func isNameByte(_ byte: UInt8) -> Bool {
    isNameStart(byte) || (48...57).contains(byte)
  }
}
