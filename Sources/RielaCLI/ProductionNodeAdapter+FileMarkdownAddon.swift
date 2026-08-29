#if canImport(AnydocKit)
import AnydocKit
#endif
import Foundation
import RielaAddonSupport
import RielaCore

/// Built-in worker add-on that converts local documents (pdf, docx, pptx,
/// xlsx, odt, rtf, epub, csv, ...) to GitHub-Flavored Markdown.
///
/// The converter is the sibling `anydoc-swift` package's `AnydocKit` library,
/// called inside this process — the same native library kaiba's document
/// intake already links, so no `anydoc-swift` executable has to be installed.
/// Failures arrive as a typed `AnydocError.Kind`, so a failed document keeps
/// its machine-readable kind instead of a prose message.
enum FileMarkdownAddon {
  static let name = "riela/file-markdown-convert"
  static let provider = "anydoc-swift"

  /// Documents larger than this are rejected before the converter starts.
  static let defaultMaxInputBytes = 25_000_000
  static let maxInputBytesCeiling = 256_000_000
  /// Markdown beyond this size is truncated so a single document cannot
  /// exhaust the session store.
  static let defaultMaxMarkdownBytes = 1_000_000
  static let maxMarkdownBytesCeiling = 8_000_000
  static let defaultMaxDocuments = 10
  static let maxDocumentsCeiling = 50
  static let documentSeparator = "\n\n---\n\n"
}

extension BuiltinWorkflowAddonResolver {
  func executeFileMarkdownConvert(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    #if !canImport(AnydocKit)
    // The converter's Linux route is a pkg-config staticlib built from Rust,
    // which riela does not require; refuse rather than half-convert.
    throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires macOS")
    #else
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(
        .policyBlocked,
        "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'"
      )
    }
    guard input.addon.env?.isEmpty != false else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) does not support addon.env")
    }
    // The converter is linked in, so there is no executable to point at.
    // Failing loudly beats silently ignoring a build the author chose.
    guard (input.addon.config ?? [:])["binaryPath"] == nil else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(input.addon.name) config.binaryPath is not supported; the converter runs in-process, remove it"
      )
    }

    let config = input.addon.config ?? [:]
    let request = try FileMarkdownConvertRequest(
      input: input,
      config: config,
      environment: environment,
      workingDirectory: workingDirectory
    )
    let converterVersion = Anydoc.version

    var documents: [JSONObject] = []
    var markdownSections: [String] = []
    var failedCount = 0
    for entry in request.entries {
      switch entry {
      case let .unresolved(document, failure):
        failedCount += 1
        documents.append(document.failurePayload(kind: failure.kind, message: failure.message))
      case let .resolved(document):
        do {
          let converted = try await convertDocumentToMarkdown(
            document,
            addonName: input.addon.name,
            format: request.format,
            maxMarkdownBytes: request.maxMarkdownBytes,
            deadline: context.deadline
          )
          markdownSections.append(converted.markdown)
          documents.append(converted.payload)
        } catch let failure as FileMarkdownDocumentFailure {
          guard request.continueOnError else {
            throw failure.adapterError(addonName: input.addon.name)
          }
          failedCount += 1
          documents.append(document.failurePayload(kind: failure.kind, message: failure.message))
        }
      }
    }

    let markdown = markdownSections.joined(separator: FileMarkdownAddon.documentSeparator)
    let converted = documents.count - failedCount
    let payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "markdown": .string(markdown),
      "documentCount": .integer(Int64(documents.count)),
      "convertedCount": .integer(Int64(converted)),
      "failedCount": .integer(Int64(failedCount)),
      "fileMarkdown": .object([
        "documents": .array(documents.map(JSONValue.object)),
        "documentCount": .integer(Int64(documents.count)),
        "convertedCount": .integer(Int64(converted)),
        "failedCount": .integer(Int64(failedCount)),
        "markdown": .string(markdown),
        // The converter is linked in, so there is no resolved binary to
        // report; the pinned native library version is the useful fact.
        "converter": .object([
          "mode": .string("in-process"),
          "library": .string(FileMarkdownAddon.provider),
          "version": .string(converterVersion)
        ])
      ]),
      "replyText": .string(
        failedCount == 0
          ? "Converted \(converted) document(s) to Markdown."
          : "Converted \(converted) document(s) to Markdown; \(failedCount) failed."
      )
    ]

    return AdapterExecutionOutput(
      provider: FileMarkdownAddon.provider,
      model: "\(input.addon.name)@1",
      promptText: "",
      completionPassed: true,
      when: [
        "always": true,
        "has_markdown": !markdown.isEmpty,
        "has_failures": failedCount > 0
      ],
      payload: payload
    )
    #endif
  }

  #if canImport(AnydocKit)
  private func convertDocumentToMarkdown(
    _ document: FileMarkdownConvertDocument,
    addonName: String,
    format: String?,
    maxMarkdownBytes: Int,
    deadline: Date?
  ) async throws -> (markdown: String, payload: JSONObject) {
    // `config.format` is validated against the alias set on the way in, so an
    // unrecognized name here would be a runtime mismatch rather than authoring
    // error; treat it the way the converter treats an unusable input.
    let requestedFormat = try format.map { name -> AnydocFormat in
      guard let resolved = AnydocFormat(fileExtension: name) ?? AnydocFormat(rawValue: name) else {
        throw FileMarkdownDocumentFailure(
          kind: AnydocError.Kind.unsupported.rawValue,
          message: "unsupported format '\(name)'",
          code: .policyBlocked
        )
      }
      return resolved
    }
    let path = document.path
    let conversion: AnydocConversion
    do {
      conversion = try await withAnydocDeadline(deadline, addonName: addonName) {
        try Anydoc.convert(contentsOf: URL(fileURLWithPath: path), format: requestedFormat)
      }
    } catch let error as AnydocError {
      throw FileMarkdownDocumentFailure(
        kind: error.kind.rawValue,
        message: appleGatewayCompactText(error.message),
        code: .providerError
      )
    }
    let truncated = truncatedMarkdown(conversion.markdown, maxBytes: maxMarkdownBytes)
    return (
      truncated.text,
      document.successPayload(
        markdown: truncated.text,
        markdownByteCount: truncated.text.utf8.count,
        truncated: truncated.wasTruncated,
        format: conversion.format.rawValue
      )
    )
  }
  #endif

  private func truncatedMarkdown(_ markdown: String, maxBytes: Int) -> (text: String, wasTruncated: Bool) {
    guard markdown.utf8.count > maxBytes else {
      return (markdown, false)
    }
    // Cut at the byte limit, then step back to the nearest character boundary
    // so the payload never carries a split scalar.
    var cut = markdown.utf8.index(markdown.utf8.startIndex, offsetBy: maxBytes)
    while cut > markdown.utf8.startIndex, String.Index(cut, within: markdown) == nil {
      cut = markdown.utf8.index(before: cut)
    }
    guard let boundary = String.Index(cut, within: markdown) else {
      return ("", true)
    }
    return (String(markdown[markdown.startIndex..<boundary]), true)
  }
}

/// One local document the add-on was asked to convert. `path` is the
/// symlink-resolved location that is handed to the converter; `requestedPath`
/// is what the workflow authored, kept for traceability.
struct FileMarkdownConvertDocument {
  var path: String
  var requestedPath: String
  var fileName: String
  var byteCount: Int

  func successPayload(
    markdown: String,
    markdownByteCount: Int,
    truncated: Bool,
    format: String
  ) -> JSONObject {
    [
      "status": .string("ok"),
      "path": .string(path),
      "requestedPath": .string(requestedPath),
      "fileName": .string(fileName),
      "format": .string(format),
      "inputByteCount": .integer(Int64(byteCount)),
      "markdown": .string(markdown),
      "markdownByteCount": .integer(Int64(markdownByteCount)),
      "truncated": .bool(truncated)
    ]
  }

  func failurePayload(kind: String, message: String) -> JSONObject {
    [
      "status": .string("failed"),
      "path": .string(path),
      "requestedPath": .string(requestedPath),
      "fileName": .string(fileName),
      "inputByteCount": .integer(Int64(byteCount)),
      "error": .object([
        "kind": .string(kind),
        "message": .string(message)
      ])
    ]
  }
}

/// One entry of a request: a document ready to convert, or one that failed
/// path resolution and is reported as a failed document under
/// `config.continueOnError`.
enum FileMarkdownConvertEntry {
  case resolved(FileMarkdownConvertDocument)
  case unresolved(FileMarkdownConvertDocument, FileMarkdownDocumentFailure)
}

/// Validated add-on request: the documents to convert plus the authored limits.
struct FileMarkdownConvertRequest {
  var entries: [FileMarkdownConvertEntry]
  var format: String?
  var maxMarkdownBytes: Int
  var continueOnError: Bool

  init(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    environment: [String: String],
    workingDirectory: URL
  ) throws {
    let addonName = input.addon.name
    let variables = addonVariables(for: input)
    let inputs = renderAddonInputs(input.addon.inputs, variables: variables)
    let continueOnError = boolValue(config["continueOnError"]) ?? false
    self.format = try Self.validatedFormat(config["format"], addonName: addonName)
    self.continueOnError = continueOnError
    self.maxMarkdownBytes = try Self.validatedLimit(
      config["maxMarkdownBytes"],
      defaultValue: FileMarkdownAddon.defaultMaxMarkdownBytes,
      ceiling: FileMarkdownAddon.maxMarkdownBytesCeiling,
      field: "maxMarkdownBytes",
      addonName: addonName
    )
    let maxInputBytes = try Self.validatedLimit(
      config["maxInputBytes"],
      defaultValue: FileMarkdownAddon.defaultMaxInputBytes,
      ceiling: FileMarkdownAddon.maxInputBytesCeiling,
      field: "maxInputBytes",
      addonName: addonName
    )
    let maxDocuments = try Self.validatedLimit(
      config["maxDocuments"],
      defaultValue: FileMarkdownAddon.defaultMaxDocuments,
      ceiling: FileMarkdownAddon.maxDocumentsCeiling,
      field: "maxDocuments",
      addonName: addonName
    )
    let allowedRoots = try Self.validatedAllowedRoots(
      config["allowedRoots"],
      addonName: addonName,
      environment: environment,
      workingDirectory: workingDirectory
    )

    let requestedPaths = try Self.requestedPaths(inputs, addonName: addonName)
    guard !requestedPaths.isEmpty else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(addonName) requires addon.inputs.path or addon.inputs.paths"
      )
    }
    guard requestedPaths.count <= maxDocuments else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(addonName) received \(requestedPaths.count) paths, above config.maxDocuments \(maxDocuments)"
      )
    }
    self.entries = try requestedPaths.map { requested in
      do {
        return .resolved(try Self.resolvedDocument(
          requested,
          environment: environment,
          workingDirectory: workingDirectory,
          allowedRoots: allowedRoots,
          maxInputBytes: maxInputBytes
        ))
      } catch let failure as FileMarkdownDocumentFailure {
        guard continueOnError else {
          throw failure.adapterError(addonName: addonName)
        }
        return .unresolved(
          FileMarkdownConvertDocument(
            path: requested,
            requestedPath: requested,
            fileName: URL(fileURLWithPath: requested).lastPathComponent,
            byteCount: 0
          ),
          failure
        )
      }
    }
  }

  private static func requestedPaths(_ inputs: JSONObject, addonName: String) throws -> [String] {
    var paths: [String] = []
    // An unset workflow input renders to an empty string, so empty and null
    // resolutions mean "not provided" rather than a malformed input.
    if let single = inputs["path"], !isAbsentInput(single) {
      guard case let .string(path) = single else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) addon.inputs.path must resolve to a string")
      }
      paths.append(path)
    }
    if let multiple = inputs["paths"], !isAbsentInput(multiple) {
      guard case let .array(values) = multiple else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) addon.inputs.paths must resolve to an array")
      }
      for value in values {
        guard case let .string(path) = value, !path.isEmpty else {
          throw AdapterExecutionError(
            .policyBlocked,
            "\(addonName) addon.inputs.paths entries must be non-empty strings"
          )
        }
        paths.append(path)
      }
    }
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  private static func isAbsentInput(_ value: JSONValue) -> Bool {
    switch value {
    case .null:
      return true
    case let .string(text):
      return text.isEmpty
    case let .array(values):
      return values.isEmpty
    default:
      return false
    }
  }

  /// Resolves one requested path to the file the converter will actually read.
  /// Symlinks are followed first, so a symlinked document converts and so the
  /// size, type, and `allowedRoots` checks all apply to the same target file.
  private static func resolvedDocument(
    _ requested: String,
    environment: [String: String],
    workingDirectory: URL,
    allowedRoots: [String],
    maxInputBytes: Int
  ) throws -> FileMarkdownConvertDocument {
    let url = try resolvedDocumentURL(
      requested,
      environment: environment,
      workingDirectory: workingDirectory
    )
    .resolvingSymlinksInPath()
    .standardizedFileURL
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
      throw FileMarkdownDocumentFailure(.io, "cannot read '\(requested)'", code: .policyBlocked)
    }
    guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
      throw FileMarkdownDocumentFailure(.unsupported, "requires a regular file: '\(requested)'", code: .policyBlocked)
    }
    let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard byteCount <= maxInputBytes else {
      throw FileMarkdownDocumentFailure(
        .resourceLimit,
        "input '\(url.lastPathComponent)' is \(byteCount) bytes, above config.maxInputBytes \(maxInputBytes)",
        code: .policyBlocked
      )
    }
    if !allowedRoots.isEmpty {
      guard allowedRoots.contains(where: { isContained(url.path, in: $0) }) else {
        throw FileMarkdownDocumentFailure(
          .policyBlocked,
          "input '\(url.lastPathComponent)' is outside config.allowedRoots",
          code: .policyBlocked
        )
      }
    }
    return FileMarkdownConvertDocument(
      path: url.path,
      requestedPath: requested,
      fileName: url.lastPathComponent,
      byteCount: byteCount
    )
  }

  private static func resolvedDocumentURL(
    _ requested: String,
    environment: [String: String],
    workingDirectory: URL
  ) throws -> URL {
    guard !requested.contains("\0") else {
      throw FileMarkdownDocumentFailure(.policyBlocked, "input path contains an invalid character", code: .policyBlocked)
    }
    var path = requested
    if path == "~" || path.hasPrefix("~/") {
      guard let home = environmentValue("HOME", environment: environment) else {
        throw FileMarkdownDocumentFailure(.io, "cannot expand '~' without HOME", code: .policyBlocked)
      }
      path = home + String(path.dropFirst(1))
    }
    let url = path.hasPrefix("/")
      ? URL(fileURLWithPath: path)
      : workingDirectory.appendingPathComponent(path)
    return url.standardizedFileURL
  }

  private static func isContained(_ path: String, in root: String) -> Bool {
    path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }

  private static func validatedFormat(_ value: JSONValue?, addonName: String) throws -> String? {
    guard let value else { return nil }
    guard let format = nonEmptyString(value) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.format must be a non-empty string")
    }
    let normalized = format.lowercased()
    // The converter's own extension aliases (`xlsx` -> `excel`,
    // `docm` -> `docx`, ...) decide what is supported, so the add-on has no
    // second list to keep in sync.
    #if canImport(AnydocKit)
    guard AnydocFormat(fileExtension: normalized) != nil || AnydocFormat(rawValue: normalized) != nil else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.format '\(format)' is not supported")
    }
    #endif
    return normalized
  }

  private static func validatedLimit(
    _ value: JSONValue?,
    defaultValue: Int,
    ceiling: Int,
    field: String,
    addonName: String
  ) throws -> Int {
    guard let value, value != .null else { return defaultValue }
    guard let limit = intValue(value), limit > 0, limit <= ceiling else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(addonName) config.\(field) must be an integer between 1 and \(ceiling)"
      )
    }
    return limit
  }

  private static func validatedAllowedRoots(
    _ value: JSONValue?,
    addonName: String,
    environment: [String: String],
    workingDirectory: URL
  ) throws -> [String] {
    guard let value, value != .null else { return [] }
    guard case let .array(values) = value else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.allowedRoots must be an array")
    }
    return try values.map { entry in
      guard let root = nonEmptyString(entry) else {
        throw AdapterExecutionError(
          .policyBlocked,
          "\(addonName) config.allowedRoots entries must be non-empty strings"
        )
      }
      do {
        return try resolvedDocumentURL(
          root,
          environment: environment,
          workingDirectory: workingDirectory
        )
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
      } catch let failure as FileMarkdownDocumentFailure {
        throw failure.adapterError(addonName: addonName)
      }
    }
  }
}

/// A document that could not be converted, carrying a machine-readable kind so
/// workflows can branch on it. Conversion failures reuse the converter's own
/// kinds (`unsupported`, `malformed`, `encrypted`, `resourceLimit`,
/// `missingPart`, `io`); path-resolution failures add `policyBlocked`.
struct FileMarkdownDocumentFailure: Error {
  enum Kind: String {
    case io
    case unsupported
    case resourceLimit
    case policyBlocked
  }

  var kind: String
  var message: String
  var code: AdapterExecutionErrorCode

  init(kind: String, message: String, code: AdapterExecutionErrorCode) {
    self.kind = kind
    self.message = message
    self.code = code
  }

  init(_ kind: Kind, _ message: String, code: AdapterExecutionErrorCode) {
    self.init(kind: kind.rawValue, message: message, code: code)
  }

  func adapterError(addonName: String) -> AdapterExecutionError {
    guard code == .providerError else {
      return AdapterExecutionError(code, "\(addonName) \(message)")
    }
    return AdapterExecutionError(code, "\(addonName) conversion failed (\(kind)): \(message)")
  }
}

/// `anydoc-swift convert <path> --json` result envelope.

#if canImport(AnydocKit)
/// Applies the step deadline to one native conversion.
///
/// The converter is a synchronous FFI call, so unlike the old child process it
/// cannot be killed: when the deadline wins, the step fails on time and the
/// worker thread finishes the document it already started before going away.
/// A workflow therefore still sees its timeout, and at most one document's
/// work outlives it.
private func withAnydocDeadline(
  _ deadline: Date?,
  addonName: String,
  operation: @escaping @Sendable () throws -> AnydocConversion
) async throws -> AnydocConversion {
  guard let deadline else {
    return try operation()
  }
  let remaining = deadline.timeIntervalSinceNow
  guard remaining > 0 else {
    throw AdapterExecutionError(.timeout, "\(addonName) exceeded deadline before conversion started")
  }
  return try await withThrowingTaskGroup(of: AnydocConversion.self) { group in
    group.addTask { try operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(remaining))
      throw AdapterExecutionError(.timeout, "\(addonName) exceeded deadline while converting")
    }
    defer { group.cancelAll() }
    guard let first = try await group.next() else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) produced no conversion result")
    }
    return first
  }
}
#endif
