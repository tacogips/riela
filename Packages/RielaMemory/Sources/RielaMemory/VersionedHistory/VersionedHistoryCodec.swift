import Foundation
import Crypto
import CZlib

public enum VersionedHistoryCodec {
  static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  static func compressed(_ data: Data) throws -> (Data, String) {
    if data.isEmpty { return (data, "none") }
    var output = Data(count: Int(compressBound(uLong(data.count))))
    var outputLength = uLongf(output.count)
    let status = data.withUnsafeBytes { input in
      output.withUnsafeMutableBytes { destination in
        compress2(destination.bindMemory(to: Bytef.self).baseAddress!, &outputLength,
                  input.bindMemory(to: Bytef.self).baseAddress!, uLong(data.count), 6)
      }
    }
    guard status == Z_OK else { throw VersionedHistoryError.historyCorrupt("zlib compression failed: \(status)") }
    output.count = Int(outputLength)
    return output.count < data.count ? (output, "zlib") : (data, "none")
  }

  static func decompressed(_ data: Data, codec: String, byteCount: Int64, exact: Bool = true) throws -> Data {
    guard byteCount >= 0, byteCount <= Int64(Int.max) else { throw VersionedHistoryError.historyCorrupt("invalid byte count") }
    guard codec == "zlib" else {
      let validSize = exact ? Int64(data.count) == byteCount : Int64(data.count) <= byteCount
      guard codec == "none", validSize else { throw VersionedHistoryError.historyCorrupt("invalid uncompressed blob") }
      return data
    }
    var output = Data(count: Int(byteCount))
    var length = uLongf(output.count)
    let status = data.withUnsafeBytes { input in
      output.withUnsafeMutableBytes { destination in
        uncompress(destination.bindMemory(to: Bytef.self).baseAddress, &length,
                   input.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
      }
    }
    let validLength = exact ? length == uLong(byteCount) : length <= uLong(byteCount)
    guard status == Z_OK, validLength else { throw VersionedHistoryError.historyCorrupt("zlib decompression failed: \(status)") }
    output.count = Int(length)
    return output
  }

  static func splice(_ anchor: Data, _ value: Data) -> Data {
    var prefix = 0
    while prefix < min(anchor.count, value.count), anchor[prefix] == value[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < min(anchor.count - prefix, value.count - prefix), anchor[anchor.count - suffix - 1] == value[value.count - suffix - 1] { suffix += 1 }
    var result = Data()
    appendLE(UInt64(prefix), to: &result)
    appendLE(UInt64(suffix), to: &result)
    result.append(value[prefix..<(value.count - suffix)])
    return result
  }

  static func apply(_ splice: Data, to anchor: Data) throws -> Data {
    guard splice.count >= 16 else { throw VersionedHistoryError.historyCorrupt("truncated splice") }
    let prefix = readLE(splice, 0), suffix = readLE(splice, 8)
    guard prefix <= UInt64(anchor.count), suffix <= UInt64(anchor.count) - prefix else { throw VersionedHistoryError.historyCorrupt("invalid splice bounds") }
    var result = Data(anchor.prefix(Int(prefix)))
    result.append(splice.dropFirst(16))
    result.append(anchor.suffix(Int(suffix)))
    return result
  }

  private static func appendLE(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8((value >> UInt64(shift)) & 0xff)) }
  }
  private static func readLE(_ data: Data, _ offset: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | (UInt64(data[offset + $1]) << UInt64($1 * 8)) }
  }
}
