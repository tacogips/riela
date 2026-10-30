import Foundation
import RielaCore

enum MediaPipelineOptions {
  static func number(
    _ values: JSONObject, _ key: String, default defaultValue: Double, range: ClosedRange<Double>
  ) throws -> Double {
    guard let value = values[key] else { return defaultValue }
    let number: Double
    switch value {
    case .integer(let int): number = Double(int)
    case .number(let double): number = double
    default: throw MediaPipelineError.invalidOption(key)
    }
    guard number.isFinite, range.contains(number) else {
      throw MediaPipelineError.invalidOption(key)
    }
    return number
  }
}

enum MediaPipelineError: Error {
  case invalidOption(String)
  case stage(String, String)
}
