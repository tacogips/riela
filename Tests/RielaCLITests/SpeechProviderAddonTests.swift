import Foundation
import RielaAdapters
import RielaCore
import XCTest

@testable import RielaCLI

final class SpeechProviderAddonTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "riela-speech-providers-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func audioFile(_ name: String, _ contents: String = "RIFFfixture") throws -> URL {
    let file = root.appendingPathComponent(name)
    try Data(contents.utf8).write(to: file)
    return file
  }

  private func resolver(
    _ environment: [String: String], http: SpeechHTTPRecorder? = nil,
    runner: (any LocalProcessRunning)? = nil
  ) -> BuiltinWorkflowAddonResolver {
    let recorder = http ?? SpeechHTTPRecorder()
    return BuiltinWorkflowAddonResolver(
      environment: environment, workingDirectory: root,
      containerProcessRunner: runner ?? SpeechFakeRunner(),
      mediaPipelineHTTP: { request in await recorder.send(request) })
  }

  // MARK: speech-to-text

  func testOpenAIUploadFollowsFileExtensionAndKeepsOutputContract() async throws {
    let audio = try audioFile("clip.wav")
    let http = SpeechHTTPRecorder(responses: [#"{"text":"hello"}"#])
    let output = try await resolver(["OPENAI_API_KEY": "k"], http: http).execute(
      sttInput(["path": .string(audio.path)], env: ["OPENAI_API_KEY"]), context: .init())
    let fields = try XCTUnwrap(payloadObject(output, "speechToText"))
    XCTAssertEqual(fields["provider"], .string("openai"))
    XCTAssertEqual(fields["model"], .string("gpt-4o-transcribe"))
    XCTAssertEqual(fields["text"], .string("hello"))
    XCTAssertEqual(fields["status"], .string("completed"))
    let request = try await firstRequest(http)
    XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    let body = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    XCTAssertTrue(body.contains(#"filename="audio.wav""#), body)
    XCTAssertTrue(body.contains("Content-Type: audio/wav"), body)
  }

  func testDeepgramRequestShapeAndParsing() async throws {
    let audio = try audioFile("clip.flac")
    let http = SpeechHTTPRecorder(responses: [
      #"{"results":{"channels":[{"alternatives":[{"transcript":"deep words"}]}]}}"#
    ])
    let output = try await resolver(["DEEPGRAM_API_KEY": "dg"], http: http).execute(
      sttInput(
        ["path": .string(audio.path), "provider": .string("deepgram"), "language": .string("ja")],
        env: ["DEEPGRAM_API_KEY"]), context: .init())
    let fields = try XCTUnwrap(payloadObject(output, "speechToText"))
    XCTAssertEqual(fields["text"], .string("deep words"))
    XCTAssertEqual(fields["provider"], .string("deepgram"))
    XCTAssertEqual(fields["model"], .string("nova-3"))
    let request = try await firstRequest(http)
    let url = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    XCTAssertEqual(url.host, "api.deepgram.com")
    XCTAssertEqual(url.path, "/v1/listen")
    let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(query["model"], "nova-3")
    XCTAssertEqual(query["language"], "ja")
    XCTAssertEqual(query["smart_format"], "true")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token dg")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/flac")
    XCTAssertEqual(request.httpBody, try Data(contentsOf: audio))
  }

  func testElevenLabsRequestShapeAndParsing() async throws {
    let audio = try audioFile("clip.m4a")
    let http = SpeechHTTPRecorder(responses: [#"{"text":"eleven words","language_code":"en"}"#])
    let output = try await resolver(
      ["ELEVENLABS_API_KEY": "xi", "ELEVENLABS_BASE_URL": "https://eleven.example.test/"], http: http
    ).execute(
      sttInput(
        ["path": .string(audio.path), "provider": .string("elevenlabs"), "language": .string("en")],
        env: ["ELEVENLABS_API_KEY", "ELEVENLABS_BASE_URL"]), context: .init())
    XCTAssertEqual(payloadObject(output, "speechToText")?["text"], .string("eleven words"))
    let request = try await firstRequest(http)
    XCTAssertEqual(request.url?.absoluteString, "https://eleven.example.test/v1/speech-to-text")
    XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "xi")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let body = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    XCTAssertTrue(body.contains("name=\"model_id\"\r\n\r\nscribe_v1"), body)
    XCTAssertTrue(body.contains("name=\"language_code\"\r\n\r\nen"), body)
    XCTAssertTrue(body.contains(#"name="file"; filename="audio.m4a""#), body)
    XCTAssertTrue(body.contains("Content-Type: audio/mp4"), body)
  }

  func testGoogleRequestShapeAndParsing() async throws {
    let audio = try audioFile("clip.wav")
    let http = SpeechHTTPRecorder(responses: [
      #"{"results":[{"alternatives":[{"transcript":"first part"}]},{"alternatives":[{"transcript":" second"}]}]}"#
    ])
    let output = try await resolver(["GOOGLE_SPEECH_API_KEY": "gk"], http: http).execute(
      sttInput(
        ["path": .string(audio.path), "provider": .string("google"), "language": .string("ja-JP")],
        env: ["GOOGLE_SPEECH_API_KEY"]), context: .init())
    XCTAssertEqual(payloadObject(output, "speechToText")?["text"], .string("first part second"))
    XCTAssertEqual(payloadObject(output, "speechToText")?["model"], .null)
    let request = try await firstRequest(http)
    XCTAssertEqual(
      request.url?.absoluteString, "https://speech.googleapis.com/v1/speech:recognize?key=gk")
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    XCTAssertEqual((json["config"] as? [String: Any])?["languageCode"] as? String, "ja-JP")
    XCTAssertEqual(
      (json["audio"] as? [String: Any])?["content"] as? String,
      try Data(contentsOf: audio).base64EncodedString())
    XCTAssertEqual(try SpeechToTextResponse.google(Data("{}".utf8)), "")
  }

  func testGoogleRejectsNonLinearAudio() async throws {
    let audio = try audioFile("clip.mp3")
    do {
      _ = try await resolver(["GOOGLE_SPEECH_API_KEY": "gk"]).execute(
        sttInput(
          ["path": .string(audio.path), "provider": .string("google")],
          env: ["GOOGLE_SPEECH_API_KEY"]), context: .init())
      XCTFail("google should reject mp3")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertTrue(error.message.contains("WAV"), error.message)
    }
  }

  func testProviderEnvironmentAllowlists() async throws {
    let audio = try audioFile("clip.wav")
    let cases: [(String, [String])] = [
      ("openai", ["DEEPGRAM_API_KEY"]),
      ("deepgram", ["OPENAI_API_KEY"]),
      ("elevenlabs", ["GOOGLE_SPEECH_API_KEY"]),
      ("google", ["ELEVENLABS_API_KEY"]),
      ("apple", ["OPENAI_API_KEY"]),
      ("command", ["OPENAI_API_KEY"])
    ]
    for (provider, env) in cases {
      var options: JSONObject = ["path": .string(audio.path), "provider": .string(provider)]
      if provider == "command" { options["command"] = .array([.string("/bin/echo")]) }
      do {
        _ = try await resolver(Dictionary(uniqueKeysWithValues: env.map { ($0, "v") })).execute(
          sttInput(options, env: env), context: .init())
        XCTFail("\(provider) should reject \(env)")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .policyBlocked, provider)
        XCTAssertTrue(error.message.contains("provider '\(provider)'"), error.message)
      }
    }
  }

  func testRemoteProviderRequiresItsKey() async throws {
    let audio = try audioFile("clip.wav")
    do {
      _ = try await resolver([:]).execute(
        sttInput(["path": .string(audio.path), "provider": .string("deepgram")], env: []),
        context: .init())
      XCTFail("deepgram needs a key")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("DEEPGRAM_API_KEY"), error.message)
    }
  }

  func testCommandProviderRendersPlaceholdersAndCachesByProvider() async throws {
    let audio = try audioFile("clip.wav")
    let runner = SpeechFakeRunner(stdout: "  local transcript \n")
    let http = SpeechHTTPRecorder(responses: [#"{"text":"remote"}"#])
    let local = resolver(["COMMAND_MODEL_DIR": "/models", "OPENAI_API_KEY": "k"], http: http, runner: runner)
    let options: JSONObject = [
      "path": .string(audio.path), "provider": .string("command"), "language": .string("ja"),
      "command": .array([
        .string("/opt/whisper/bin/whisper-cli"), .string("-f"), .string("{{path}}"),
        .string("-l"), .string("{{language}}")
      ])
    ]
    let first = try await local.execute(
      sttInput(options, env: ["COMMAND_MODEL_DIR"]), context: .init())
    XCTAssertEqual(payloadObject(first, "speechToText")?["text"], .string("local transcript"))
    XCTAssertEqual(payloadObject(first, "speechToText")?["provider"], .string("command"))
    let calls = await runner.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls[0].executableURL.path, "/opt/whisper/bin/whisper-cli")
    XCTAssertEqual(calls[0].arguments, ["-f", audio.standardizedFileURL.path, "-l", "ja"])
    XCTAssertEqual(calls[0].environment["COMMAND_MODEL_DIR"], "/models")
    XCTAssertNil(calls[0].environment["OPENAI_API_KEY"])
    let replay = try await local.execute(
      sttInput(options, env: ["COMMAND_MODEL_DIR"]), context: .init())
    XCTAssertEqual(payloadObject(replay, "speechToText")?["cached"], .bool(true))
    // Switching provider on the same file must not reuse the command transcript.
    let remote = try await local.execute(
      sttInput(["path": .string(audio.path), "language": .string("ja")], env: ["OPENAI_API_KEY"]),
      context: .init())
    XCTAssertEqual(payloadObject(remote, "speechToText")?["text"], .string("remote"))
    XCTAssertEqual(payloadObject(remote, "speechToText")?["cached"], .bool(false))
  }

  func testCommandProviderFailureIsProviderError() async throws {
    let audio = try audioFile("clip.wav")
    do {
      _ = try await resolver([:], runner: SpeechFakeRunner(status: 3)).execute(
        sttInput(
          [
            "path": .string(audio.path), "provider": .string("command"),
            "command": .array([.string("/bin/false")])
          ], env: []), context: .init())
      XCTFail("non-zero exit should fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertTrue(error.message.contains("status 3"), error.message)
    }
  }

  func testCommandOptionRequiresCommandProvider() async throws {
    let audio = try audioFile("clip.wav")
    do {
      _ = try await resolver([:]).execute(
        sttInput(["path": .string(audio.path), "provider": .string("command")], env: []),
        context: .init())
      XCTFail("command provider requires command")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("command"), error.message)
    }
  }

  func testUploadMetadataFollowsExtension() {
    let cases: [[String]] = [
      ["a.wav", "audio.wav", "audio/wav"], ["a.MP3", "audio.mp3", "audio/mpeg"],
      ["a.m4a", "audio.m4a", "audio/mp4"], ["a.flac", "audio.flac", "audio/flac"],
      ["a.ogg", "audio.ogg", "audio/ogg"], ["a.webm", "audio.webm", "audio/webm"],
      ["a", "audio.mp3", "audio/mpeg"]
    ]
    for item in cases {
      let (name, filename, type) = (item[0], item[1], item[2])
      let upload = SpeechAudioUpload(URL(fileURLWithPath: "/tmp/\(name)"))
      XCTAssertEqual(upload.filename, filename, name)
      XCTAssertEqual(upload.contentType, type, name)
    }
  }

  // MARK: text-to-speech

  func testTextToSpeechIsRegistered() {
    XCTAssertTrue(
      BuiltinStatefulAddonRegistry.registrations.map(\.name).contains("riela/text-to-speech"))
  }

  func testOpenAISpeechRequestShapeAndOutput() async throws {
    let http = SpeechHTTPRecorder(responses: ["ID3fake-mp3"])
    let out = root.appendingPathComponent("out", isDirectory: true)
    let output = try await resolver(["OPENAI_API_KEY": "k"], http: http).execute(
      ttsInput(
        [
          "provider": .string("openai"), "text": .string("こんにちは"), "voice": .string("nova"),
          "outputDir": .string(out.path)
        ], env: ["OPENAI_API_KEY"]), context: .init())
    let fields = try XCTUnwrap(payloadObject(output, "textToSpeech"))
    XCTAssertEqual(fields["status"], .string("completed"))
    XCTAssertEqual(fields["provider"], .string("openai"))
    XCTAssertEqual(fields["played"], .bool(false))
    XCTAssertEqual(output.when, ["always": true, "spoken": true])
    let path = try XCTUnwrap(fields["path"]?.stringValue)
    XCTAssertTrue(path.hasPrefix(out.path) && path.hasSuffix(".mp3"), path)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("ID3fake-mp3".utf8))
    let request = try await firstRequest(http)
    XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    XCTAssertEqual(json["model"] as? String, "gpt-4o-mini-tts")
    XCTAssertEqual(json["voice"] as? String, "nova")
    XCTAssertEqual(json["input"] as? String, "こんにちは")
    XCTAssertEqual(json["response_format"] as? String, "mp3")
    // Same request is served from the produced file.
    let replay = try await resolver(["OPENAI_API_KEY": "k"], http: http).execute(
      ttsInput(
        [
          "provider": .string("openai"), "text": .string("こんにちは"), "voice": .string("nova"),
          "outputDir": .string(out.path)
        ], env: ["OPENAI_API_KEY"]), context: .init())
    XCTAssertEqual(payloadObject(replay, "textToSpeech")?["cached"], .bool(true))
    let count = await http.requests.count
    XCTAssertEqual(count, 1)
  }

  func testElevenLabsSpeechRequestShape() async throws {
    let http = SpeechHTTPRecorder(responses: ["mp3-bytes"])
    _ = try await resolver(["ELEVENLABS_API_KEY": "xi"], http: http).execute(
      ttsInput(
        ["provider": .string("elevenlabs"), "text": .string("hi"), "voice": .string("voice123")],
        env: ["ELEVENLABS_API_KEY"]), context: .init())
    let request = try await firstRequest(http)
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://api.elevenlabs.io/v1/text-to-speech/voice123?output_format=mp3_44100_128")
    XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "xi")
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    XCTAssertEqual(json["text"] as? String, "hi")
    XCTAssertEqual(json["model_id"] as? String, "eleven_multilingual_v2")
  }

  func testVoicevoxQueriesThenSynthesizes() async throws {
    let http = SpeechHTTPRecorder(responses: [#"{"accent_phrases":[],"speedScale":1.0}"#, "RIFFwav"])
    let output = try await resolver(
      ["VOICEVOX_BASE_URL": "http://voicevox.test:50021"], http: http
    ).execute(
      ttsInput(
        ["provider": .string("voicevox"), "text": .string("やあ"), "speaker": .integer(3)],
        env: ["VOICEVOX_BASE_URL"]), context: .init())
    let path = try XCTUnwrap(payloadObject(output, "textToSpeech")?["path"]?.stringValue)
    XCTAssertTrue(path.hasSuffix(".wav"))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("RIFFwav".utf8))
    let requests = await http.requests
    XCTAssertEqual(requests.count, 2)
    let query = try XCTUnwrap(
      requests[0].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    XCTAssertEqual(query.host, "voicevox.test")
    XCTAssertEqual(query.path, "/audio_query")
    XCTAssertEqual(query.queryItems?.first { $0.name == "text" }?.value, "やあ")
    XCTAssertEqual(query.queryItems?.first { $0.name == "speaker" }?.value, "3")
    XCTAssertEqual(
      requests[1].url?.absoluteString, "http://voicevox.test:50021/synthesis?speaker=3")
    XCTAssertEqual(
      requests[1].httpBody, Data(#"{"accent_phrases":[],"speedScale":1.0}"#.utf8))
  }

  func testAppleSayAndPlayUseProcessRunner() async throws {
    #if os(macOS)
      let runner = SpeechFakeRunner()
      let output = try await resolver([:], runner: runner).execute(
        ttsInput(
          [
            "provider": .string("apple"), "text": .string("hello"), "voice": .string("Kyoko"),
            "rate": .integer(200), "play": .bool(true)
          ], env: []), context: .init())
      let fields = try XCTUnwrap(payloadObject(output, "textToSpeech"))
      XCTAssertEqual(fields["played"], .bool(true))
      XCTAssertEqual(output.when, ["always": true, "spoken": true])
      let calls = await runner.calls
      XCTAssertEqual(calls.map(\.executableURL.path), ["/usr/bin/say", "/usr/bin/afplay"])
      XCTAssertEqual(Array(calls[0].arguments.prefix(4)), ["-v", "Kyoko", "-r", "200"])
      XCTAssertTrue(calls[0].arguments.contains("--file-format=AIFF"))
      XCTAssertTrue(calls[0].arguments.contains("-f"))
      XCTAssertEqual(calls[1].arguments, [try XCTUnwrap(fields["path"]?.stringValue)])
      XCTAssertTrue(fields["path"]?.stringValue?.hasSuffix(".aiff") == true)
    #else
      throw XCTSkip("apple provider is macOS only")
    #endif
  }

  func testCommandSpeechRendersTextAndOutput() async throws {
    let runner = SpeechFakeRunner()
    let output = try await resolver([:], runner: runner).execute(
      ttsInput(
        [
          "provider": .string("command"), "text": .string("read me"),
          "command": .array([
            .string("/usr/local/bin/piper"), .string("--text"), .string("{{text}}"),
            .string("--output_file"), .string("{{output}}")
          ])
        ], env: []), context: .init())
    let calls = await runner.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls[0].arguments[1], "read me")
    let path = try XCTUnwrap(payloadObject(output, "textToSpeech")?["path"]?.stringValue)
    XCTAssertTrue(path.hasSuffix(".wav"), path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
  }

  func testEmptyTextSkipsAndExpiredNotAfterDoesNotSynthesize() async throws {
    let runner = SpeechFakeRunner()
    let skipped = try await resolver([:], runner: runner).execute(
      ttsInput(["provider": .string("command"), "text": .string("  "),
        "command": .array([.string("/bin/tts"), .string("{{output}}")])], env: []),
      context: .init())
    XCTAssertEqual(payloadObject(skipped, "textToSpeech")?["status"], .string("skipped"))
    XCTAssertEqual(payloadObject(skipped, "textToSpeech")?["path"], .null)
    XCTAssertEqual(skipped.when, ["always": true, "skipped": true])

    let expired = try await resolver([:], runner: runner).execute(
      ttsInput(["provider": .string("command"), "text": .string("late"),
        "notAfter": .string("2000-01-01T00:00:00.123+09:00"),
        "command": .array([.string("/bin/tts"), .string("{{output}}")])], env: []),
      context: .init())
    XCTAssertEqual(payloadObject(expired, "textToSpeech")?["status"], .string("expired"))
    XCTAssertEqual(expired.when, ["always": true, "expired": true])
    let callsAfterExpired = await runner.calls.count
    XCTAssertEqual(callsAfterExpired, 0)

    let future = try await resolver([:], runner: runner).execute(
      ttsInput(["provider": .string("command"), "text": .string("on time"),
        "notAfter": .string("2999-01-01T00:00:00Z"),
        "command": .array([.string("/bin/tts"), .string("{{output}}")])], env: []),
      context: .init())
    XCTAssertEqual(future.when, ["always": true, "spoken": true])
    XCTAssertNotNil(parseTextToSpeechInstant("2026-10-31T12:00:00+09:00"))
    XCTAssertNotNil(parseTextToSpeechInstant("2026-10-31T03:00:00.5Z"))
    XCTAssertNil(parseTextToSpeechInstant("tomorrow"))

    do {
      _ = try await resolver([:], runner: runner).execute(
        ttsInput(["provider": .string("apple"), "text": .string("x"), "notAfter": .string("soon")],
          env: []), context: .init())
      XCTFail("invalid notAfter must fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("notAfter"), error.message)
    }
  }

  func testTextToSpeechEnvironmentAllowlist() async throws {
    for (provider, env) in [("apple", "OPENAI_API_KEY"), ("voicevox", "OPENAI_API_KEY"), ("openai", "ELEVENLABS_API_KEY")] {
      do {
        _ = try await resolver([env: "v"]).execute(
          ttsInput(["provider": .string(provider), "text": .string("x"), "voice": .string("v")], env: [env]),
          context: .init())
        XCTFail("\(provider) should reject \(env)")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .policyBlocked, provider)
        XCTAssertTrue(error.message.contains("provider '\(provider)'"), error.message)
      }
    }
  }

  func testOtherMediaStagesStillRejectAddonEnv() async throws {
    let input = WorkflowAddonExecutionInput(
      workflowId: "speech", stepId: "frames", nodeId: "frames",
      addon: .init(
        name: "riela/video-frames", version: "1",
        config: ["options": .object(["path": .string("x.mp4")])],
        env: ["OPENAI_API_KEY": .object(["fromEnv": .string("OPENAI_API_KEY")])]),
      variables: [:])
    do {
      _ = try await resolver(["OPENAI_API_KEY": "k"]).execute(input, context: .init())
      XCTFail("video-frames must reject addon.env")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
  }
}

private func sttInput(_ options: JSONObject, env: [String]) -> WorkflowAddonExecutionInput {
  addonInput("riela/speech-to-text", options, env: env)
}

private func ttsInput(_ options: JSONObject, env: [String]) -> WorkflowAddonExecutionInput {
  addonInput("riela/text-to-speech", options, env: env)
}

private func addonInput(_ name: String, _ options: JSONObject, env: [String])
  -> WorkflowAddonExecutionInput {
  var bindings: JSONObject = [:]
  for key in env { bindings[key] = .object(["fromEnv": .string(key)]) }
  return WorkflowAddonExecutionInput(
    workflowId: "speech", stepId: "stage", nodeId: "stage",
    addon: .init(name: name, version: "1", config: ["options": .object(options)], env: bindings),
    variables: [:])
}

private func payloadObject(_ output: AdapterExecutionOutput, _ key: String) -> JSONObject? {
  guard case .object(let fields)? = output.payload[key] else { return nil }
  return fields
}

private func firstRequest(
  _ recorder: SpeechHTTPRecorder, file: StaticString = #filePath, line: UInt = #line
) async throws -> URLRequest {
  let requests = await recorder.requests
  return try XCTUnwrap(requests.first, file: file, line: line)
}

actor SpeechHTTPRecorder {
  private(set) var requests: [URLRequest] = []
  private var responses: [String]

  init(responses: [String] = [#"{"text":"fixture"}"#]) { self.responses = responses }

  func send(_ request: URLRequest) -> MediaPipelineHTTPResponse {
    requests.append(request)
    let body = responses.count > 1 ? responses.removeFirst() : (responses.first ?? "{}")
    return .init(status: 200, body: Data(body.utf8), retryAfter: nil)
  }
}

/// Records process invocations; writes a fake audio file to `-o` / output-like arguments.
actor SpeechFakeRunner: LocalProcessRunning {
  private(set) var calls: [LocalProcessConfiguration] = []
  let stdout: String
  let status: Int32

  init(stdout: String = "", status: Int32 = 0) {
    self.stdout = stdout
    self.status = status
  }

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws
    -> LocalProcessResult {
    calls.append(configuration)
    let args = configuration.arguments
    var targets: [String] = []
    if let index = args.firstIndex(of: "-o"), index + 1 < args.count { targets.append(args[index + 1]) }
    targets += args.filter { $0.contains("/.partial-") }
    for target in targets { try? Data("audio".utf8).write(to: URL(fileURLWithPath: target)) }
    return .init(stdout: stdout, stderr: status == 0 ? "" : "boom", terminationStatus: status)
  }
}
