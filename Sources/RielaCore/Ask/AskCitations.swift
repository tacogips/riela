public enum AskCitations {
  public static func extract(text: String, knownRefs: [AskRef]) -> [AskRef] {
    let pairs = knownRefs.compactMap { ref in marker(for: ref).map { ($0, ref) } }
    var remaining = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    return text.matches(of: /\[\[[^\[\]\r\n]+\]\]/).compactMap { match in
      remaining.removeValue(forKey: String(match.output))
    }
  }

  private static func marker(for ref: AskRef) -> String? {
    guard !ref.id.isEmpty else { return nil }
    if ref.kind == .step {
      guard let sessionId = ref.sessionId, !sessionId.isEmpty else { return nil }
      return "[[step:\(sessionId)/\(ref.id)]]"
    }
    return "[[\(ref.kind.rawValue):\(ref.id)]]"
  }
}
