import Foundation
import XCTest
@testable import RielaCLI

final class VoiceActivitySegmenterTests: XCTestCase {
  private let rate = 16_000

  private func silence(ms: Int) -> [Float] {
    [Float](repeating: 0, count: rate * ms / 1000)
  }

  /// 440 Hz sine at amplitude 0.5 (about -9 dBFS RMS).
  private func tone(ms: Int, amplitude: Float = 0.5) -> [Float] {
    (0..<(rate * ms / 1000)).map { amplitude * sin(2 * .pi * 440 * Float($0) / Float(rate)) }
  }

  private func run(_ samples: [Float], configuration: VoiceActivitySegmenterConfiguration = .init(),
                   chunk: Int = 1_000) -> [VoiceUtterance] {
    var segmenter = VoiceActivitySegmenter(configuration: configuration)
    var utterances: [VoiceUtterance] = []
    var index = 0
    while index < samples.count {
      let end = min(samples.count, index + chunk)
      utterances += segmenter.process(Array(samples[index..<end]))
      index = end
    }
    return utterances + segmenter.flush()
  }

  func testSilenceOnlyProducesNothing() {
    XCTAssertTrue(run(silence(ms: 5_000)).isEmpty)
    XCTAssertTrue(run(tone(ms: 5_000, amplitude: 0.001)).isEmpty, "-69 dBFS stays below -45")
  }

  func testToneBurstProducesOneUtteranceWithPreRoll() throws {
    let marker: Float = 0.0001
    var leading = silence(ms: 1_000)
    for index in leading.indices { leading[index] = marker }
    let utterances = run(leading + tone(ms: 1_000) + silence(ms: 2_000))
    XCTAssertEqual(utterances.count, 1)
    let utterance = try XCTUnwrap(utterances.first)
    // 400 ms pre-roll + 1000 ms speech + at most 400 ms kept trailing silence.
    XCTAssertEqual(utterance.durationMs, 1_800)
    XCTAssertEqual(Array(utterance.samples.prefix(rate * 400 / 1000)), [Float](repeating: marker, count: rate * 400 / 1000))
    XCTAssertGreaterThan(abs(utterance.samples[rate * 400 / 1000 + 10]), 0.01)
    XCTAssertEqual(utterance.peakDb, -6.0, accuracy: 0.1)
  }

  func testLongToneSplitsAtMaxUtterance() {
    var configuration = VoiceActivitySegmenterConfiguration()
    configuration.maxUtteranceMs = 3_000
    let utterances = run(tone(ms: 7_000) + silence(ms: 2_000), configuration: configuration)
    XCTAssertEqual(utterances.map(\.durationMs), [3_000, 3_000, 1_400])
  }

  func testShortBlipBelowMinSpeechIsDropped() {
    XCTAssertTrue(run(silence(ms: 500) + tone(ms: 100) + silence(ms: 2_000)).isEmpty)
  }

  func testTwoBurstsSeparatedByLongSilenceProduceTwoUtterances() {
    let samples = silence(ms: 500) + tone(ms: 600) + silence(ms: 1_500) + tone(ms: 800) + silence(ms: 1_500)
    let utterances = run(samples)
    XCTAssertEqual(utterances.count, 2)
    XCTAssertEqual(utterances.map(\.durationMs), [1_400, 1_600])
  }

  func testShortPauseInsideSpeechKeepsOneUtterance() {
    let samples = tone(ms: 600) + silence(ms: 300) + tone(ms: 600) + silence(ms: 1_500)
    XCTAssertEqual(run(samples).count, 1)
  }

  func testFlushEmitsInProgressUtterance() {
    var segmenter = VoiceActivitySegmenter()
    XCTAssertTrue(segmenter.process(tone(ms: 800)).isEmpty)
    XCTAssertEqual(segmenter.flush().map(\.durationMs), [800])
    XCTAssertTrue(segmenter.flush().isEmpty)
  }
}

final class VoiceInboxTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/voice-listen-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testWAVHeaderBytes() {
    let data = WAVWriter.encode(samples: [0, 1, -1, 0.5], sampleRate: 16_000)
    XCTAssertEqual(data.count, 44 + 8)
    let expectedHeader: [UInt8] = [
      0x52, 0x49, 0x46, 0x46, 0x2C, 0x00, 0x00, 0x00, // "RIFF", 36 + 8
      0x57, 0x41, 0x56, 0x45, // "WAVE"
      0x66, 0x6D, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00, // "fmt ", 16
      0x01, 0x00, 0x01, 0x00, // PCM, mono
      0x80, 0x3E, 0x00, 0x00, // 16000 Hz
      0x00, 0x7D, 0x00, 0x00, // 32000 bytes/s
      0x02, 0x00, 0x10, 0x00, // block align 2, 16 bits
      0x64, 0x61, 0x74, 0x61, 0x08, 0x00, 0x00, 0x00 // "data", 8
    ]
    XCTAssertEqual(Array(data.prefix(44)), expectedHeader)
    XCTAssertEqual(Array(data.suffix(8)), [0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80, 0x00, 0x40])
  }

  func testAtomicNamingWritesFinalFileOnly() throws {
    let inbox = root.appendingPathComponent("office")
    let writer = VoiceInboxWriter(inbox: inbox)
    try writer.prepare()
    let date = Date(timeIntervalSince1970: 1_793_442_645) // 2026-10-31T10:30:45Z
    XCTAssertEqual(VoiceInboxWriter.fileName(date: date, id: "abc123"), "20261031T103045Z-abc123.wav")
    let url = try writer.write(VoiceUtterance(samples: [0.1, 0.2], sampleRate: 16_000), date: date, id: "abc123")
    XCTAssertEqual(url.lastPathComponent, "20261031T103045Z-abc123.wav")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), ["20261031T103045Z-abc123.wav"])
    XCTAssertEqual(try Data(contentsOf: url).count, 48)
    XCTAssertEqual(VoiceInboxWriter.makeIdentifier().count, 12)
  }

  func testRetentionDeletesOnlyOldWAVFiles() throws {
    let now = Date()
    let fileManager = FileManager.default
    func make(_ name: String, age: TimeInterval) throws {
      let url = root.appendingPathComponent(name)
      try Data([1]).write(to: url)
      try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }
    try make("old.wav", age: 1_000)
    try make("OLD2.WAV", age: 1_000)
    try make("fresh.wav", age: 10)
    try make("old.txt", age: 1_000)
    try make("old.wav.json", age: 1_000)
    try fileManager.createDirectory(at: root.appendingPathComponent("nested.wav"), withIntermediateDirectories: true)
    XCTAssertTrue(VoiceInboxRetention.prune(inbox: root, retainSeconds: 0, now: now).isEmpty)
    let removed = VoiceInboxRetention.prune(inbox: root, retainSeconds: 600, now: now)
    XCTAssertEqual(Set(removed.map(\.lastPathComponent)), ["old.wav", "OLD2.WAV"])
    XCTAssertEqual(
      Set(try fileManager.contentsOfDirectory(atPath: root.path)),
      ["fresh.wav", "old.txt", "old.wav.json", "nested.wav"]
    )
  }
}

final class VoiceCommandTests: XCTestCase {
  func testListenOptionsDefaultsAndValidation() throws {
    let options = try ParsedVoiceListenOptions.parseVoice(["--inbox", "inbox/office", "--threshold-db", "-50"])
    XCTAssertEqual(options.thresholdDb, -50)
    XCTAssertEqual(options.segmenterConfiguration.silenceMs, 700)
    XCTAssertEqual(options.segmenterConfiguration.maxUtteranceMs, 15_000)
    XCTAssertTrue(options.voiceProcessing)
    XCTAssertEqual(options.inboxURL(workingDirectory: "/work").path, "/work/inbox/office")
    let off = try ParsedVoiceListenOptions.parseVoice(["--inbox", "/x", "--voice-processing", "false"])
    XCTAssertFalse(off.voiceProcessing)
    XCTAssertThrowsError(try ParsedVoiceListenOptions.parseVoice([]))
    XCTAssertThrowsError(try ParsedVoiceListenOptions.parseVoice(["--inbox", "/x", "--threshold-db", "3"]))
    XCTAssertThrowsError(try ParsedVoiceListenOptions.parseVoice(["--inbox", "/x", "--silence-ms", "0"]))
    XCTAssertThrowsError(try ParsedVoiceListenOptions.parseVoice(["--inbox", "/x", "--max-utterance-ms", "100"]))
  }

  func testHelpIsServedForVoicePaths() async {
    for arguments in [["voice", "--help"], ["voice", "listen", "--help"], ["voice", "listen", "-h"], ["voice", "devices", "--help"]] {
      let result = await RielaCLIApplication().run(arguments)
      XCTAssertEqual(result.exitCode, .success, "\(arguments)")
      XCTAssertTrue(result.stdout.contains("riela voice listen --inbox <dir>"), "\(arguments): \(result.stdout)")
      XCTAssertTrue(result.stdout.contains("--retain-seconds"), "\(arguments)")
    }
  }

  func testUnknownVoiceActionIsUsageError() async {
    let result = await RielaCLIApplication().run(["voice", "speak"])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("riela voice listen|devices"))
  }

  func testListenRequiresInboxOrReportsPlatform() async {
    let result = await VoiceCommand().run(["listen"])
    XCTAssertEqual(result.exitCode, .usage)
    #if os(macOS)
    XCTAssertTrue(result.stderr.contains("--inbox"), result.stderr)
    #else
    XCTAssertEqual(result.stderr, "riela voice listen is only available on macOS")
    #endif
  }

  func testRecordLineShape() throws {
    let line = VoiceCommand.recordLine(
      path: "/inbox/a.wav",
      utterance: VoiceUtterance(samples: [Float](repeating: 0.5, count: 16_000), sampleRate: 16_000)
    )
    XCTAssertEqual(line, #"{"durationMs":1000,"path":"/inbox/a.wav","peakDb":-6}"# + "\n")
  }
}
