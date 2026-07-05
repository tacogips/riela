import Foundation

public struct AgentJSONLByteLineSplitter: Sendable {
  public static let defaultMaximumPendingBytes = 1024 * 1024

  public var maximumPendingBytes: Int
  private var pending = Data()

  public init(maximumPendingBytes: Int = Self.defaultMaximumPendingBytes) {
    self.maximumPendingBytes = max(1, maximumPendingBytes)
  }

  public var pendingByteCount: Int {
    pending.count
  }

  public mutating func feed(_ data: Data) -> [String] {
    guard !data.isEmpty else {
      return []
    }
    pending.append(data)
    var lines: [String] = []
    while let newlineIndex = pending.firstIndex(of: 10) {
      var lineData = Data(pending[..<newlineIndex])
      pending.removeSubrange(...newlineIndex)
      if lineData.last == 13 {
        lineData.removeLast()
      }
      // Process JSONL can contain invalid UTF-8; keep replacement-character decoding for complete lines.
      // swiftlint:disable:next optional_data_string_conversion
      let line = String(decoding: lineData, as: UTF8.self)
      guard !line.isEmpty else {
        continue
      }
      lines.append(line)
    }
    if pending.count > maximumPendingBytes {
      // swiftlint:disable:next optional_data_string_conversion
      let line = String(decoding: pending, as: UTF8.self)
      pending.removeAll(keepingCapacity: true)
      if !line.isEmpty {
        lines.append(line)
      }
    }
    return lines
  }

  public mutating func flush(allowLossyUTF8: Bool = true) -> String? {
    guard !pending.isEmpty else {
      return nil
    }
    var lineData = pending
    if lineData.last == 13 {
      lineData.removeLast()
    }
    let line: String
    if allowLossyUTF8 {
      // swiftlint:disable:next optional_data_string_conversion
      line = String(decoding: lineData, as: UTF8.self)
    } else if let decoded = String(data: lineData, encoding: .utf8) {
      line = decoded
    } else {
      return nil
    }
    guard !line.isEmpty else {
      return nil
    }
    pending.removeAll(keepingCapacity: true)
    return line
  }
}
