import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteUIAsyncS3Tests: XCTestCase {
  func testNoteServiceClientResolvesS3SourcePageImageThroughAsyncHTTPClient() async throws {
    let service = try makeAsyncS3Service()
    let note = try service.createNote(bodyMarkdown: "# S3 Page\n\nBody")
    let imageData = Data([9, 8, 7, 6])
    let attachment = try service.attachFile(
      noteId: note.noteId,
      data: imageData,
      role: .sourcePageImage,
      mediaType: "image/png",
      originalFilename: "s3-page.png"
    )
    let s3Client = AsyncPathRecordingS3HTTPClient()
    let profile = asyncS3Profile()
    _ = try service.migrateFileStorage(
      fileId: attachment.file.fileId,
      to: profile,
      httpClient: s3Client
    )
    let viewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(
      service: service,
      s3Profiles: [profile],
      s3HTTPClient: s3Client
    ))

    await viewModel.selectNote(note.noteId)
    await viewModel.setContentMode(.sourceImage)

    XCTAssertEqual(viewModel.sourcePageImageAttachment?.file.storageKind, .s3)
    XCTAssertEqual(viewModel.resolvedSourceImage?.data, imageData)
    XCTAssertEqual(s3Client.syncMethods(), ["PUT"])
    XCTAssertEqual(s3Client.asyncMethods(), ["GET"])
  }
}

private func makeAsyncS3Service(function: String = #function) throws -> NoteService {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteUIAsyncS3Tests", isDirectory: true)
    .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
}

private func asyncS3Profile() -> S3StorageProfile {
  S3StorageProfile(
    name: "test-s3",
    endpoint: URL(string: "https://s3.example.test")!,
    region: "ap-northeast-1",
    bucket: "notes",
    accessKeyId: "access-key",
    secretAccessKey: "secret-key",
    keyPrefix: "riela"
  )
}

private final class AsyncPathRecordingS3HTTPClient: S3HTTPClient, AsyncS3HTTPClient, @unchecked Sendable {
  private let queue = DispatchQueue(label: "AsyncPathRecordingS3HTTPClient")
  private var objects: [String: Data] = [:]
  private var syncRequestMethods: [String] = []
  private var asyncRequestMethods: [String] = []

  func send(_ request: S3HTTPRequest) throws -> S3HTTPResponse {
    queue.sync {
      syncRequestMethods.append(request.method)
      return response(for: request)
    }
  }

  func send(_ request: S3HTTPRequest) async throws -> S3HTTPResponse {
    queue.sync {
      asyncRequestMethods.append(request.method)
      return response(for: request)
    }
  }

  func syncMethods() -> [String] {
    queue.sync {
      syncRequestMethods
    }
  }

  func asyncMethods() -> [String] {
    queue.sync {
      asyncRequestMethods
    }
  }

  private func response(for request: S3HTTPRequest) -> S3HTTPResponse {
    switch request.method {
    case "PUT":
      objects[request.url.path] = request.body
      return S3HTTPResponse(statusCode: 200)
    case "GET":
      guard let data = objects[request.url.path] else {
        return S3HTTPResponse(statusCode: 404)
      }
      return S3HTTPResponse(statusCode: 200, body: data)
    case "DELETE":
      objects.removeValue(forKey: request.url.path)
      return S3HTTPResponse(statusCode: 204)
    default:
      return S3HTTPResponse(statusCode: 400)
    }
  }
}
