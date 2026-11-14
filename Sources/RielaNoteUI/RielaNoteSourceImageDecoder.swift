import CoreGraphics
import Foundation
import ImageIO

public struct RielaNoteDecodedSourceImage: @unchecked Sendable {
  public let fileId: String
  public let cgImage: CGImage
  public let pixelWidth: Int
  public let pixelHeight: Int

  public init(fileId: String, cgImage: CGImage) {
    self.fileId = fileId
    self.cgImage = cgImage
    pixelWidth = cgImage.width
    pixelHeight = cgImage.height
  }
}

public enum RielaNoteSourceImageDecodeError: Error, Equatable, Sendable {
  case unsupportedImageData(fileId: String)
}

enum RielaNoteSourceImageDecoder {
  static let defaultMaxPixelDimension = 2_400

  static func decode(
    fileId: String,
    data: Data,
    maxPixelDimension: Int = defaultMaxPixelDimension
  ) throws -> RielaNoteDecodedSourceImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw RielaNoteSourceImageDecodeError.unsupportedImageData(fileId: fileId)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(maxPixelDimension, 1)
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw RielaNoteSourceImageDecodeError.unsupportedImageData(fileId: fileId)
    }
    return RielaNoteDecodedSourceImage(fileId: fileId, cgImage: cgImage)
  }
}
