import ArgumentParser
import Foundation

enum VoiceClientAction: String, CaseIterable, Sendable {
  case listen
  case devices

  static var allRawValues: [String] { allCases.map(\.rawValue) }
}

struct ParsedVoiceListenOptions: ParsableArguments, Sendable {
  @Option(help: "Inbox directory that receives one WAV per utterance (watched by a file-change event source).")
  var inbox: String
  @Option(help: "Input device UID from `riela voice devices` (default: the system default input).")
  var device: String?
  @Option(name: .customLong("threshold-db"), parsing: .unconditional, help: "Speech onset level in RMS dBFS.")
  var thresholdDb: Double = -45
  @Option(name: .customLong("min-speech-ms"), help: "Utterances with less voiced audio are dropped.")
  var minSpeechMs: Int = 300
  @Option(name: .customLong("silence-ms"), help: "Silence that ends an utterance.")
  var silenceMs: Int = 700
  @Option(name: .customLong("max-utterance-ms"), help: "Longer speech is split into several files.")
  var maxUtteranceMs: Int = 15_000
  @Option(name: .customLong("pre-roll-ms"), help: "Audio kept from before the speech onset.")
  var preRollMs: Int = 400
  @Option(name: .customLong("retain-seconds"), help: "Delete inbox *.wav files older than this (0 keeps them).")
  var retainSeconds: Int = 600
  @Option(name: .customLong("voice-processing"), help: "Enable echo cancellation / noise suppression (true|false).")
  var voiceProcessing: Bool = true

  init() {}

  static func parseVoice(_ arguments: [String]) throws -> ParsedVoiceListenOptions {
    let parsed: ParsedVoiceListenOptions
    do {
      parsed = try parse(arguments)
    } catch {
      throw CLIUsageError(message(for: error))
    }
    try parsed.validateValues()
    return parsed
  }

  func validateValues() throws {
    guard !inbox.isEmpty else { throw CLIUsageError("voice listen requires --inbox <dir>") }
    guard thresholdDb.isFinite, thresholdDb > VoiceLevel.floorDb, thresholdDb < 0 else {
      throw CLIUsageError("--threshold-db must be between -120 and 0")
    }
    guard minSpeechMs >= 0, silenceMs > 0, preRollMs >= 0, retainSeconds >= 0 else {
      throw CLIUsageError("--min-speech-ms, --pre-roll-ms and --retain-seconds must be >= 0; --silence-ms must be > 0")
    }
    guard maxUtteranceMs > minSpeechMs, maxUtteranceMs > preRollMs else {
      throw CLIUsageError("--max-utterance-ms must be greater than --min-speech-ms and --pre-roll-ms")
    }
  }

  var segmenterConfiguration: VoiceActivitySegmenterConfiguration {
    VoiceActivitySegmenterConfiguration(
      thresholdDb: thresholdDb,
      minSpeechMs: minSpeechMs,
      silenceMs: silenceMs,
      maxUtteranceMs: maxUtteranceMs,
      preRollMs: preRollMs
    )
  }

  func inboxURL(workingDirectory: String = FileManager.default.currentDirectoryPath) -> URL {
    URL(fileURLWithPath: inbox, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
      .standardizedFileURL
  }
}

/// `riela voice listen|devices`: a thin microphone recorder that drops one
/// 16 kHz mono WAV per detected utterance into an inbox directory. It is not
/// an event source and never runs workflows; a `file-change` event source
/// watching the inbox does that.
struct VoiceCommand {
  typealias LineWriter = @Sendable (String) -> Void

  static func macOSOnlyMessage(for action: VoiceClientAction) -> String {
    "riela voice \(action.rawValue) is only available on macOS"
  }

  static var helpText: String {
    """
    Usage:
      riela voice listen --inbox <dir> [--device <uid>] [--threshold-db -45] [--min-speech-ms 300]
        [--silence-ms 700] [--max-utterance-ms 15000] [--pre-roll-ms 400] [--retain-seconds 600] [--voice-processing true|false]
      riela voice devices

    Records the microphone (macOS only), segments speech with an energy VAD and
    writes each utterance atomically as <inbox>/<UTC yyyyMMddTHHmmssZ>-<id>.wav
    (16-bit PCM, 16 kHz, mono). Pair it with a file-change event source that
    watches the inbox (filters.suffixes [".wav"], stabilityWindowMs 0). Prints
    one JSON line per written file: {"path":...,"durationMs":...,"peakDb":...}.
    Runs until SIGINT or SIGTERM. `riela voice devices` lists input device UIDs.
    See docs/voice.md.

    """ + "\n" + optionsHelp + "\n"
  }

  private static var optionsHelp: String {
    let generated = ParsedVoiceListenOptions.helpMessage(columns: 120)
    guard let range = generated.range(of: "OPTIONS:") else { return generated }
    return String(generated[range.lowerBound...])
  }

  var lineWriter: LineWriter = { line in FileHandle.standardOutput.write(Data(line.utf8)) }
  var diagnosticWriter: LineWriter = { line in FileHandle.standardError.write(Data(line.utf8)) }

  func run(_ arguments: [String]) async -> CLICommandResult {
    if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
      return CLICommandResult(exitCode: .success, stdout: Self.helpText)
    }
    guard let action = VoiceClientAction(rawValue: arguments[0]) else {
      return CLICommandResult(exitCode: .usage, stderr: "usage: riela voice listen|devices [options]")
    }
    #if !os(macOS)
    return CLICommandResult(exitCode: .usage, stderr: Self.macOSOnlyMessage(for: action))
    #else
    let rest = Array(arguments.dropFirst())
    do {
      switch action {
      case .listen:
        let options = try ParsedVoiceListenOptions.parseVoice(rest)
        return try await listen(options)
      case .devices:
        guard rest.isEmpty else { throw CLIUsageError("voice devices takes no options") }
        return try devices()
      }
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "voice \(action.rawValue) failed: \(error)")
    }
    #endif
  }

  static func recordLine(path: String, utterance: VoiceUtterance) -> String {
    let peak = (utterance.peakDb * 10).rounded() / 10
    let object: [String: Any] = ["path": path, "durationMs": utterance.durationMs, "peakDb": peak]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
      let text = String(data: data, encoding: .utf8) else { return "" }
    return text + "\n"
  }

  #if os(macOS)
  private func listen(_ options: ParsedVoiceListenOptions) async throws -> CLICommandResult {
    let writer = VoiceInboxWriter(inbox: options.inboxURL())
    try writer.prepare()
    VoiceInboxRetention.prune(inbox: writer.inbox, retainSeconds: options.retainSeconds)
    let capture = try await VoiceMicrophoneCapture.start(
      deviceUID: options.device,
      voiceProcessing: options.voiceProcessing,
      diagnostics: diagnosticWriter
    )
    defer { capture.stop() }
    var segmenter = VoiceActivitySegmenter(configuration: options.segmenterConfiguration)
    for await chunk in capture.chunks {
      for utterance in segmenter.process(chunk) {
        emit(utterance, writer: writer, retainSeconds: options.retainSeconds)
      }
    }
    for utterance in segmenter.flush() {
      emit(utterance, writer: writer, retainSeconds: options.retainSeconds)
    }
    return CLICommandResult(exitCode: .success)
  }

  private func emit(_ utterance: VoiceUtterance, writer: VoiceInboxWriter, retainSeconds: Int) {
    do {
      let url = try writer.write(utterance)
      lineWriter(Self.recordLine(path: url.path, utterance: utterance))
    } catch {
      diagnosticWriter("voice listen: failed to write utterance: \(error)\n")
    }
    VoiceInboxRetention.prune(inbox: writer.inbox, retainSeconds: retainSeconds)
  }

  private func devices() throws -> CLICommandResult {
    let lines = VoiceMicrophoneCapture.inputDevices().map { device -> String in
      let object: [String: Any] = ["uid": device.uid, "name": device.name, "isDefault": device.isDefault]
      let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
      return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }
    return CLICommandResult(exitCode: .success, stdout: lines.joined())
  }
  #endif
}
