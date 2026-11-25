public struct BotRunContext: Equatable, Sendable {
  public var botId: String
  public var permissionWaitMs: Int
  public var memoryBlock: String?
  public var forceReadOnlySandbox: Bool

  public init(botId: String, permissionWaitMs: Int, memoryBlock: String? = nil, forceReadOnlySandbox: Bool = false) {
    self.botId = botId
    self.permissionWaitMs = permissionWaitMs
    self.memoryBlock = memoryBlock
    self.forceReadOnlySandbox = forceReadOnlySandbox
  }
}
