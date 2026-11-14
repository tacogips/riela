import Foundation

public struct WorkflowVersionContentDiff: Codable, Equatable, Sendable {
  public var unified: String?
  public var binary: Bool
  public var tooLarge: Bool
  public var limitBytes: Int?

  public init(unified: String?, binary: Bool, tooLarge: Bool, limitBytes: Int?) {
    self.unified = unified
    self.binary = binary
    self.tooLarge = tooLarge
    self.limitBytes = limitBytes
  }

  private enum CodingKeys: String, CodingKey { case unified, binary, tooLarge, limitBytes }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    unified = try container.decodeIfPresent(String.self, forKey: .unified)
    binary = try container.decodeIfPresent(Bool.self, forKey: .binary) ?? false
    tooLarge = try container.decodeIfPresent(Bool.self, forKey: .tooLarge) ?? false
    limitBytes = try container.decodeIfPresent(Int.self, forKey: .limitBytes)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(unified, forKey: .unified)
    if binary { try container.encode(true, forKey: .binary) }
    if tooLarge { try container.encode(true, forKey: .tooLarge) }
    try container.encodeIfPresent(limitBytes, forKey: .limitBytes)
  }
}

public enum WorkflowUnifiedDiff {
  public static let maxBytesPerSide = 262_144

  private struct Line: Equatable {
    let text: String
    let terminated: Bool

    static func == (lhs: Line, rhs: Line) -> Bool {
      lhs.terminated == rhs.terminated && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
  }

  private struct Edit {
    let prefix: Character
    let line: Line
  }

  public static func render(path: String, before: Data?, after: Data?) -> WorkflowVersionContentDiff {
    let lhs = before ?? Data()
    let rhs = after ?? Data()
    if lhs.count > maxBytesPerSide || rhs.count > maxBytesPerSide {
      return WorkflowVersionContentDiff(unified: nil, binary: false, tooLarge: true, limitBytes: maxBytesPerSide)
    }
    guard !lhs.contains(0), !rhs.contains(0),
          let left = String(data: lhs, encoding: .utf8), let right = String(data: rhs, encoding: .utf8) else {
      return WorkflowVersionContentDiff(unified: nil, binary: true, tooLarge: false, limitBytes: nil)
    }
    guard lhs != rhs else {
      return WorkflowVersionContentDiff(unified: nil, binary: false, tooLarge: false, limitBytes: nil)
    }
    let old = lines(left)
    let new = lines(right)
    let difference = new.difference(from: old)
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in difference {
      switch change {
      case let .remove(offset, _, _): removed.insert(offset)
      case let .insert(offset, _, _): inserted.insert(offset)
      }
    }
    var edits: [Edit] = []
    var oldIndex = 0
    var newIndex = 0
    while oldIndex < old.count || newIndex < new.count {
      if oldIndex < old.count && removed.contains(oldIndex) {
        edits.append(Edit(prefix: "-", line: old[oldIndex])); oldIndex += 1
      } else if newIndex < new.count && inserted.contains(newIndex) {
        edits.append(Edit(prefix: "+", line: new[newIndex])); newIndex += 1
      } else {
        edits.append(Edit(prefix: " ", line: old[oldIndex])); oldIndex += 1; newIndex += 1
      }
    }
    return WorkflowVersionContentDiff(unified: unified(path: path, edits: edits), binary: false, tooLarge: false, limitBytes: nil)
  }

  private static func lines(_ text: String) -> [Line] {
    guard !text.isEmpty else { return [] }
    var parts = text.components(separatedBy: "\n")
    let terminated = parts.last == ""
    if terminated { parts.removeLast() }
    return parts.enumerated().map { index, value in
      Line(text: value, terminated: index < parts.count - 1 || terminated)
    }
  }

  private static func unified(path: String, edits: [Edit]) -> String {
    let changes = edits.indices.filter { edits[$0].prefix != " " }
    var ranges: [Range<Int>] = []
    for index in changes {
      let start = max(0, index - 3)
      let end = min(edits.count, index + 4)
      if let last = ranges.last, start <= last.upperBound {
        ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, end)
      } else { ranges.append(start..<end) }
    }
    var result = "--- a/\(path)\n+++ b/\(path)\n"
    for range in ranges {
      let prior = edits[..<range.lowerBound]
      let oldBefore = prior.filter { $0.prefix != "+" }.count
      let newBefore = prior.filter { $0.prefix != "-" }.count
      let hunk = edits[range]
      let oldCount = hunk.filter { $0.prefix != "+" }.count
      let newCount = hunk.filter { $0.prefix != "-" }.count
      let oldStart = oldBefore + (oldCount == 0 ? 0 : 1)
      let newStart = newBefore + (newCount == 0 ? 0 : 1)
      result += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"
      for edit in hunk {
        result += "\(edit.prefix)\(edit.line.text)\n"
        if !edit.line.terminated { result += "\\ No newline at end of file\n" }
      }
    }
    return result
  }
}
