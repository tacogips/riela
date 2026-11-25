struct BotsRequestGrant: Sendable {
  @TaskLocal static var current: Self?
  var targetsLocalByDefault = false
  let isStillValid: @Sendable () -> Bool
}
