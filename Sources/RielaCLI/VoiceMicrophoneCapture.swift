#if os(macOS)
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

struct VoiceInputDevice: Equatable, Sendable {
  var id: AudioDeviceID
  var uid: String
  var name: String
  var isDefault: Bool
}

/// AVAudioEngine microphone capture converted to 16 kHz mono Float32 chunks.
/// The tap callback runs on a realtime audio thread and only converts and
/// yields; segmentation and file writes happen on the consuming task.
final class VoiceMicrophoneCapture: @unchecked Sendable {
  static let targetSampleRate: Double = 16_000

  let chunks: AsyncStream<[Float]>
  private let engine: AVAudioEngine
  private let continuation: AsyncStream<[Float]>.Continuation

  private init(engine: AVAudioEngine, chunks: AsyncStream<[Float]>, continuation: AsyncStream<[Float]>.Continuation) {
    self.engine = engine
    self.chunks = chunks
    self.continuation = continuation
  }

  static func start(
    deviceUID: String?,
    voiceProcessing: Bool,
    diagnostics: @escaping @Sendable (String) -> Void
  ) async throws -> VoiceMicrophoneCapture {
    try await requireMicrophoneAccess()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    if let deviceUID {
      try select(deviceUID: deviceUID, on: input)
    }
    if voiceProcessing {
      do {
        try input.setVoiceProcessingEnabled(true)
      } catch {
        diagnostics("voice listen: voice processing unavailable (\(error.localizedDescription)); using raw input\n")
      }
    }
    let sourceFormat = input.outputFormat(forBus: 0)
    guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
      throw VoiceCaptureError("the selected input device reports no usable audio format")
    }
    guard let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false
    ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      throw VoiceCaptureError("cannot convert \(sourceFormat) to 16 kHz mono")
    }
    converter.downmix = true
    let (chunks, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(1_024))
    let resampler = VoiceResampler(converter: converter, targetFormat: targetFormat)
    input.installTap(onBus: 0, bufferSize: 4_096, format: sourceFormat) { buffer, _ in
      if let samples = resampler.convert(buffer), !samples.isEmpty {
        continuation.yield(samples)
      }
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      continuation.finish()
      throw VoiceCaptureError("failed to start audio input: \(error.localizedDescription)")
    }
    diagnostics("voice listen: capturing \(Int(sourceFormat.sampleRate)) Hz x\(sourceFormat.channelCount) -> 16 kHz mono\n")
    return VoiceMicrophoneCapture(engine: engine, chunks: chunks, continuation: continuation)
  }

  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    continuation.finish()
  }

  private static func requireMicrophoneAccess() async throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return
    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: .audio)
      if granted { return }
    default:
      break
    }
    throw VoiceCaptureError(
      "microphone access denied; allow it for the terminal (or riela) in System Settings > Privacy & Security > Microphone"
    )
  }

  // MARK: - CoreAudio devices

  static func inputDevices() -> [VoiceInputDevice] {
    let defaultID = defaultInputDeviceID()
    return allDeviceIDs().compactMap { id in
      guard inputChannelCount(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
      let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
      return VoiceInputDevice(id: id, uid: uid, name: name, isDefault: id == defaultID)
    }
  }

  private static func select(deviceUID: String, on input: AVAudioInputNode) throws {
    guard let device = inputDevices().first(where: { $0.uid == deviceUID }) else {
      throw CLIUsageError("unknown input device UID '\(deviceUID)'; run `riela voice devices`")
    }
    guard let unit = input.audioUnit else { throw VoiceCaptureError("audio input unit unavailable") }
    var id = device.id
    let status = AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else { throw VoiceCaptureError("cannot select input device '\(deviceUID)' (OSStatus \(status))") }
  }

  private static func address(_ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static func allDeviceIDs() -> [AudioDeviceID] {
    var address = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  private static func defaultInputDeviceID() -> AudioDeviceID? {
    var address = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else {
      return nil
    }
    return id
  }

  private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
    var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }
}

struct VoiceCaptureError: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}

/// The converter input block runs synchronously inside `convert`; this box
/// only satisfies the Sendable closure check.
private final class VoiceConsumedFlag: @unchecked Sendable {
  var value = false
}

/// Owns the converter; used only from the audio tap thread.
private final class VoiceResampler: @unchecked Sendable {
  private let converter: AVAudioConverter
  private let targetFormat: AVAudioFormat

  init(converter: AVAudioConverter, targetFormat: AVAudioFormat) {
    self.converter = converter
    self.targetFormat = targetFormat
  }

  func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
    let consumed = VoiceConsumedFlag()
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if consumed.value {
        inputStatus.pointee = .noDataNow
        return nil
      }
      consumed.value = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, let channel = output.floatChannelData?[0] else { return nil }
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
  }
}
#endif
