import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteUIS3Tests: XCTestCase {
  func testNoteServiceClientResolvesS3SourcePageImage() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# S3 Page\n\nBody")
    let imageData = Data([5, 6, 7, 8])
    let attachment = try service.attachFile(
      noteId: note.noteId,
      data: imageData,
      role: .sourcePageImage,
      mediaType: "image/png",
      originalFilename: "s3-page.png"
    )
    let s3Client = InMemoryNoteUIS3HTTPClient()
    let profile = testS3Profile()
    let migrated = try service.migrateFileStorage(
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

    XCTAssertEqual(migrated.storageKind, .s3)
    XCTAssertEqual(viewModel.sourcePageImageAttachment?.file.storageKind, .s3)
    XCTAssertEqual(viewModel.resolvedSourceImage?.data, imageData)
  }
}

private func testS3Profile() -> S3StorageProfile {
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

private final class InMemoryNoteUIS3HTTPClient: S3HTTPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var objects: [String: Data] = [:]

  func send(_ request: S3HTTPRequest) throws -> S3HTTPResponse {
    lock.lock()
    defer { lock.unlock() }
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
