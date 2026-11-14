struct DynamicCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}

func rejectUnsupportedKeys(_ decoder: Decoder, allowed: [String], label: String) throws {
  let allowed = Set(allowed)
  let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
  for key in dynamic.allKeys where !allowed.contains(key.stringValue) {
    throw DecodingError.dataCorruptedError(
      forKey: key,
      in: dynamic,
      debugDescription: "\(label) has unsupported key '\(key.stringValue)'"
    )
  }
}
