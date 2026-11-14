import Foundation

/// Tuning for `VoiceActivitySegmenter`. Durations are in milliseconds of audio
/// at `sampleRate`; the segmenter never looks at wall-clock time, so a test can
/// drive it with synthetic buffers and get the exact same segmentation as a
/// live microphone.
struct VoiceActivitySegmenterConfiguration: Equatable, Sendable {
  var sampleRate: Int = 16_000
  var frameMs: Int = 20
  /// A frame whose RMS level reaches this dBFS value starts (or continues) speech.
  var thresholdDb: Double = -45
  /// Once speech started, a frame keeps counting as voiced down to
  /// `thresholdDb - hysteresisDb`, so trailing syllables do not chop an utterance.
  var hysteresisDb: Double = 6
  /// Utterances with less voiced audio than this are dropped (clicks, coughs).
  var minSpeechMs: Int = 300
  /// This much continuous silence ends an utterance.
  var silenceMs: Int = 700
  /// An utterance reaching this length is emitted and recording continues in a new one.
  var maxUtteranceMs: Int = 15_000
  /// Audio kept from before the speech onset (and the most trailing silence kept).
  var preRollMs: Int = 400

  var frameSamples: Int { max(1, sampleRate * frameMs / 1000) }

  func frames(forMs milliseconds: Int) -> Int {
    max(0, (milliseconds + frameMs - 1) / frameMs)
  }
}

/// One completed utterance: 16 kHz mono Float32 samples in `[-1, 1]`.
struct VoiceUtterance: Equatable, Sendable {
  var samples: [Float]
  var sampleRate: Int

  var durationMs: Int { sampleRate > 0 ? samples.count * 1000 / sampleRate : 0 }

  /// Peak sample level in dBFS (`-120` for digital silence).
  var peakDb: Double {
    let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
    return VoiceLevel.decibels(Double(peak))
  }
}

enum VoiceLevel {
  static let floorDb: Double = -120

  static func decibels(_ amplitude: Double) -> Double {
    guard amplitude > 0 else { return floorDb }
    return max(floorDb, 20 * log10(amplitude))
  }

  static func rmsDecibels<C: Collection>(_ samples: C) -> Double where C.Element == Float {
    guard !samples.isEmpty else { return floorDb }
    var sum = 0.0
    for sample in samples { sum += Double(sample) * Double(sample) }
    return decibels((sum / Double(samples.count)).squareRoot())
  }
}

/// Energy voice-activity segmenter: RMS dBFS per fixed-size frame with
/// hysteresis, a pre-roll ring buffer, minimum-speech / end-silence /
/// maximum-length rules. Pure value type, platform independent.
struct VoiceActivitySegmenter: Sendable {
  let configuration: VoiceActivitySegmenterConfiguration

  private var pending: [Float] = []
  private var preRoll: [[Float]] = []
  private var current: [[Float]] = []
  private var inSpeech = false
  private var voicedFrames = 0
  private var silentFrames = 0

  init(configuration: VoiceActivitySegmenterConfiguration = .init()) {
    self.configuration = configuration
  }

  /// Feeds samples of any length; returns utterances completed by them.
  mutating func process(_ samples: [Float]) -> [VoiceUtterance] {
    pending.append(contentsOf: samples)
    let size = configuration.frameSamples
    var utterances: [VoiceUtterance] = []
    var offset = 0
    while pending.count - offset >= size {
      let frame = Array(pending[offset..<(offset + size)])
      offset += size
      if let utterance = processFrame(frame) { utterances.append(utterance) }
    }
    pending.removeFirst(offset)
    return utterances
  }

  /// Ends the stream: an in-progress utterance with enough speech is returned.
  mutating func flush() -> [VoiceUtterance] {
    defer { reset() }
    guard inSpeech else { return [] }
    return finishUtterance(trimTrailingSilence: true).map { [$0] } ?? []
  }

  private mutating func processFrame(_ frame: [Float]) -> VoiceUtterance? {
    let level = VoiceLevel.rmsDecibels(frame)
    guard inSpeech else {
      if level >= configuration.thresholdDb {
        inSpeech = true
        current = preRoll + [frame]
        preRoll.removeAll()
        voicedFrames = 1
        silentFrames = 0
        return splitIfTooLong()
      }
      preRoll.append(frame)
      let keep = configuration.frames(forMs: configuration.preRollMs)
      if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
      return nil
    }
    current.append(frame)
    if level >= configuration.thresholdDb - configuration.hysteresisDb {
      voicedFrames += 1
      silentFrames = 0
    } else {
      silentFrames += 1
    }
    if silentFrames >= configuration.frames(forMs: configuration.silenceMs) {
      let utterance = finishUtterance(trimTrailingSilence: true)
      reset()
      return utterance
    }
    return splitIfTooLong()
  }

  /// Emits the current utterance when it reached `maxUtteranceMs` and keeps
  /// recording into a fresh one (no pre-roll; the audio is contiguous).
  private mutating func splitIfTooLong() -> VoiceUtterance? {
    guard current.count * configuration.frameMs >= configuration.maxUtteranceMs else { return nil }
    let utterance = finishUtterance(trimTrailingSilence: false)
    current.removeAll()
    voicedFrames = 0
    silentFrames = 0
    return utterance
  }

  private func finishUtterance(trimTrailingSilence: Bool) -> VoiceUtterance? {
    guard voicedFrames * configuration.frameMs >= configuration.minSpeechMs else { return nil }
    var frames = current
    if trimTrailingSilence {
      let drop = max(0, silentFrames - configuration.frames(forMs: configuration.preRollMs))
      frames.removeLast(min(drop, frames.count))
    }
    return VoiceUtterance(samples: frames.flatMap { $0 }, sampleRate: configuration.sampleRate)
  }

  private mutating func reset() {
    inSpeech = false
    current.removeAll()
    preRoll.removeAll()
    voicedFrames = 0
    silentFrames = 0
  }
}
