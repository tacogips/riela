import Foundation

public struct WorkflowValidateOptions: Equatable, Sendable {
  public var workflowName: String
  public var resolution: WorkflowResolutionOptions
  public var output: WorkflowOutputFormat
  public var executable: Bool
  public var nodePatch: String?
  public var host: String?
  public var strictHost: Bool

  public init(
    workflowName: String,
    resolution: WorkflowResolutionOptions,
    output: WorkflowOutputFormat = .jsonl,
    executable: Bool = false,
    nodePatch: String? = nil,
    host: String? = nil,
    strictHost: Bool = false
  ) {
    self.workflowName = workflowName
    self.resolution = resolution
    self.output = output
    self.executable = executable
    self.nodePatch = nodePatch
    self.host = host
    self.strictHost = strictHost
  }
}

public struct WorkflowInspectOptions: Equatable, Sendable {
  public var workflowName: String
  public var resolution: WorkflowResolutionOptions
  public var output: WorkflowOutputFormat
  public var structure: Bool
  public var host: String?
  public var strictHost: Bool

  public init(
    workflowName: String,
    resolution: WorkflowResolutionOptions,
    output: WorkflowOutputFormat = .jsonl,
    structure: Bool = false,
    host: String? = nil,
    strictHost: Bool = false
  ) {
    self.workflowName = workflowName
    self.resolution = resolution
    self.output = output
    self.structure = structure
    self.host = host
    self.strictHost = strictHost
  }
}
