import Foundation
import RielaAddonSupport
import RielaCore

// `riela/utterance-match`: deterministic wake-phrase and intent matching over a
// transcribed utterance. No network, no model; every branch is reproducible from
// the configuration and the text alone.
extension BuiltinWorkflowAddonResolver {
  static let utteranceMatchRegistration = BuiltinAddonHandlerRegistration(
    name: "riela/utterance-match", bindsCLIVariablesAsInputs: false
  ) { resolver, input, _ in
    try resolver.executeUtteranceMatch(input)
  }

  func executeUtteranceMatch(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    guard (input.addon.env ?? [:]).isEmpty else {
      throw AdapterExecutionError(.policyBlocked, "riela/utterance-match does not accept addon.env values")
    }
    guard case let .object(config) = try renderAddonConfig(
      .object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["options", "context"]),
      case let .object(options)? = config["options"]
    else {
      throw AdapterExecutionError(.invalidInput, "riela/utterance-match config must be {\"options\": {...}, \"context\"?: ...}")
    }
    let matcher = try UtteranceMatcher(options: options)
    let text = try UtteranceMatcher.text(options)
    let result = matcher.match(text)

    var when: [String: Bool] = [
      "always": true,
      "wake": result.wake,
      "no_wake": !result.wake,
      "intent": result.intent != nil,
      "freeform": result.proceeds && result.intent == nil
    ]
    for intent in matcher.intents {
      when["intent_\(intent.id)"] = result.matchedIntents.contains(intent.id)
    }
    var payload: JSONObject = [
      "utterance": .object([
        "wake": .bool(result.wake),
        "wakePhrase": result.wakePhrase.map(JSONValue.string) ?? .null,
        "command": .string(result.command),
        "normalizedCommand": .string(result.normalizedCommand),
        "intent": result.intent.map(JSONValue.string) ?? .null,
        "intents": .array(result.matchedIntents.map(JSONValue.string)),
        "normalized": .string(result.normalized),
        "text": .string(text)
      ])
    ]
    if let context = config["context"] { payload["context"] = context }
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon", model: input.addon.name, promptText: "",
      completionPassed: true, when: when, payload: payload)
  }
}

struct UtteranceIntent: Equatable {
  let id: String
  let patterns: [NSRegularExpression]
}

struct UtteranceMatchResult: Equatable {
  var wake: Bool
  var wakePhrase: String?
  /// Original-text remainder after the wake phrase, trimmed of separators.
  var command: String
  var normalizedCommand: String
  var intent: String?
  var matchedIntents: [String]
  var normalized: String
  /// Whether intent matching ran (a wake phrase matched, or none is required).
  var proceeds: Bool
}

struct UtteranceMatcher {
  static let maxTextBytes = 8 * 1024
  static let maxIntents = 64
  static let maxPatternsPerIntent = 16
  static let maxPatternLength = 256
  static let maxWakePhrases = 16

  let wakePhrases: [(original: String, normalized: String)]
  let requireWakePhrase: Bool
  let intents: [UtteranceIntent]

  init(options: JSONObject) throws {
    let allowed: Set<String> = ["text", "wakePhrases", "requireWakePhrase", "intents"]
    let unknown = Set(options.keys).subtracting(allowed)
    guard unknown.isEmpty else {
      throw Self.invalid("unknown option(s): \(unknown.sorted().joined(separator: ", "))")
    }
    switch options["requireWakePhrase"] {
    case nil: requireWakePhrase = true
    case let .bool(value)?: requireWakePhrase = value
    default: throw Self.invalid("options.requireWakePhrase must be a boolean")
    }

    var phrases: [(String, String)] = []
    switch options["wakePhrases"] {
    case nil: break
    case let .array(values)? where values.count <= Self.maxWakePhrases:
      for value in values {
        guard case let .string(phrase) = value, phrase.count <= Self.maxPatternLength else {
          throw Self.invalid("options.wakePhrases entries must be strings of at most \(Self.maxPatternLength) characters")
        }
        let normalized = UtteranceNormalizer.normalize(phrase)
        guard !normalized.isEmpty else { throw Self.invalid("options.wakePhrases entry '\(phrase)' normalizes to an empty string") }
        phrases.append((phrase, normalized))
      }
    default:
      throw Self.invalid("options.wakePhrases must be an array of at most \(Self.maxWakePhrases) strings")
    }
    if requireWakePhrase, phrases.isEmpty {
      throw Self.invalid("options.wakePhrases must be non-empty when requireWakePhrase is true")
    }
    // Longest phrase first so "ねえリエラ" wins over "リエラ"-style overlaps.
    wakePhrases = phrases.enumerated()
      .sorted { lhs, rhs in
        lhs.element.1.unicodeScalars.count != rhs.element.1.unicodeScalars.count
          ? lhs.element.1.unicodeScalars.count > rhs.element.1.unicodeScalars.count
          : lhs.offset < rhs.offset
      }
      .map { (original: $0.element.0, normalized: $0.element.1) }

    var parsed: [UtteranceIntent] = []
    switch options["intents"] {
    case nil: break
    case let .array(values)? where values.count <= Self.maxIntents:
      var seen = Set<String>()
      for value in values {
        guard case let .object(object) = value, Set(object.keys).isSubset(of: ["id", "patterns"]),
          case let .string(id)? = object["id"],
          id.range(of: #"^[a-z0-9_]{1,64}$"#, options: .regularExpression) != nil
        else {
          throw Self.invalid("options.intents entries must be {\"id\": ^[a-z0-9_]{1,64}$, \"patterns\": [...]}")
        }
        guard seen.insert(id).inserted else { throw Self.invalid("duplicate intent id '\(id)'") }
        guard case let .array(rawPatterns)? = object["patterns"],
          (1...Self.maxPatternsPerIntent).contains(rawPatterns.count)
        else {
          throw Self.invalid("intent '\(id)' patterns must be an array of 1-\(Self.maxPatternsPerIntent) strings")
        }
        let patterns = try rawPatterns.map { raw -> NSRegularExpression in
          guard case let .string(pattern) = raw, !pattern.isEmpty, pattern.count <= Self.maxPatternLength else {
            throw Self.invalid("intent '\(id)' patterns must be non-empty strings of at most \(Self.maxPatternLength) characters")
          }
          do {
            return try NSRegularExpression(
              pattern: UtteranceNormalizer.normalizePattern(pattern), options: [.caseInsensitive])
          } catch {
            throw Self.invalid("intent '\(id)' pattern '\(pattern)' is not a valid regular expression")
          }
        }
        parsed.append(UtteranceIntent(id: id, patterns: patterns))
      }
    default:
      throw Self.invalid("options.intents must be an array of at most \(Self.maxIntents) intents")
    }
    intents = parsed
  }

  static func text(_ options: JSONObject) throws -> String {
    switch options["text"] {
    case let .string(text)?:
      guard text.utf8.count <= maxTextBytes else { throw invalid("options.text exceeds \(maxTextBytes) bytes") }
      return text
    case .null?:
      return ""
    default:
      throw invalid("options.text is required and must be a string")
    }
  }

  func match(_ text: String) -> UtteranceMatchResult {
    let mapped = UtteranceNormalizer.normalizeWithBoundaries(text)
    let normalized = mapped.normalized
    var wakePhrase: String?
    var wakeScalarCount = 0
    for phrase in wakePhrases where normalized.unicodeScalars.starts(with: phrase.normalized.unicodeScalars) {
      wakePhrase = phrase.original
      wakeScalarCount = phrase.normalized.unicodeScalars.count
      break
    }
    let wake = wakePhrase != nil
    let proceeds = wake || !requireWakePhrase
    guard proceeds else {
      return .init(
        wake: false, wakePhrase: nil, command: "", normalizedCommand: "", intent: nil,
        matchedIntents: [], normalized: normalized, proceeds: false)
    }
    let normalizedCommand = String(String.UnicodeScalarView(normalized.unicodeScalars.dropFirst(wakeScalarCount)))
    let command = mapped.originalRemainder(afterNormalizedScalars: wakeScalarCount)
    let range = NSRange(normalizedCommand.startIndex..<normalizedCommand.endIndex, in: normalizedCommand)
    let matched = intents.filter { intent in
      intent.patterns.contains { $0.firstMatch(in: normalizedCommand, options: [], range: range) != nil }
    }.map(\.id)
    return .init(
      wake: wake, wakePhrase: wakePhrase, command: command, normalizedCommand: normalizedCommand,
      intent: matched.first, matchedIntents: matched, normalized: normalized, proceeds: true)
  }

  private static func invalid(_ message: String) -> AdapterExecutionError {
    AdapterExecutionError(.invalidInput, "riela/utterance-match \(message)")
  }
}

enum UtteranceNormalizer {
  /// Japanese full-width punctuation removed from patterns before NFKC, because
  /// NFKC would otherwise turn `？`/`！` into regex syntax.
  private static let patternStripped: Set<Unicode.Scalar> = ["、", "。", "・", "！", "？", "，", "．", "「", "」"]

  /// NFKC, katakana → hiragana, lowercase, whitespace and punctuation removed.
  /// The long-vowel mark `ー` is a letter modifier and is kept.
  static func normalize(_ text: String) -> String {
    normalizeWithBoundaries(text).normalized
  }

  static func normalizeWithBoundaries(_ text: String) -> UtteranceNormalization {
    var normalized = String.UnicodeScalarView()
    var boundaries: [(originalEnd: String.Index, normalizedCount: Int)] = []
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(after: index)
      for scalar in fold(String(text[index..<next])).unicodeScalars where keep(scalar) {
        normalized.append(scalar)
      }
      boundaries.append((next, normalized.count))
      index = next
    }
    return .init(original: text, normalized: String(normalized), boundaries: boundaries)
  }

  /// Patterns share NFKC, kana folding and whitespace removal with the text;
  /// ASCII punctuation stays because it is regular-expression syntax, and case
  /// is handled with a case-insensitive match instead of lowercasing escapes.
  static func normalizePattern(_ pattern: String) -> String {
    let stripped = String(String.UnicodeScalarView(pattern.unicodeScalars.filter { !patternStripped.contains($0) }))
    var result = String.UnicodeScalarView()
    for scalar in katakanaToHiragana(stripped.precomposedStringWithCompatibilityMapping).unicodeScalars
    where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
      result.append(scalar)
    }
    return String(result)
  }

  private static func fold(_ text: String) -> String {
    katakanaToHiragana(text.precomposedStringWithCompatibilityMapping).lowercased()
  }

  private static func keep(_ scalar: Unicode.Scalar) -> Bool {
    !CharacterSet.whitespacesAndNewlines.contains(scalar)
      && !CharacterSet.punctuationCharacters.contains(scalar)
      && !CharacterSet.controlCharacters.contains(scalar)
  }

  static func katakanaToHiragana(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x30A1...0x30F6, 0x30FD...0x30FE:
        result.append(Unicode.Scalar(scalar.value - 0x60) ?? scalar)
      default:
        result.append(scalar)
      }
    }
    return String(result)
  }
}

struct UtteranceNormalization {
  let original: String
  let normalized: String
  let boundaries: [(originalEnd: String.Index, normalizedCount: Int)]

  /// The original text after the first `count` normalized scalars, with leading
  /// and trailing separators removed, so a freeform command keeps its spaces.
  func originalRemainder(afterNormalizedScalars count: Int) -> String {
    var start = original.startIndex
    if count > 0 {
      guard let boundary = boundaries.first(where: { $0.normalizedCount >= count }) else { return "" }
      start = boundary.originalEnd
    }
    let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    return String(original[start...]).trimmingCharacters(in: separators)
  }
}
