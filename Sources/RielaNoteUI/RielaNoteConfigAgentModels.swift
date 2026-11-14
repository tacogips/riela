import Foundation
import RielaNote

public struct RielaNoteConfigTagClassDraft: Codable, Equatable, Sendable {
  public var classId: String
  public var label: String
  public var description: String?

  public init(classId: String, label: String, description: String? = nil) {
    self.classId = classId
    self.label = label
    self.description = description
  }
}

public struct RielaNoteConfigTagDraft: Codable, Equatable, Sendable {
  public var name: String
  public var classId: String?

  public init(name: String, classId: String? = nil) {
    self.name = name
    self.classId = classId
  }
}

public struct RielaNoteConfigAutoActionDraft: Codable, Equatable, Sendable {
  public var actionId: String
  public var trigger: String
  public var workflowId: String
  public var filterJSON: String?
  public var enabled: Bool
  public var position: Int

  public init(
    actionId: String,
    trigger: String,
    workflowId: String,
    filterJSON: String? = nil,
    enabled: Bool = true,
    position: Int = 0
  ) {
    self.actionId = actionId
    self.trigger = trigger
    self.workflowId = workflowId
    self.filterJSON = filterJSON
    self.enabled = enabled
    self.position = position
  }
}

public struct RielaNoteConfigIngestionWorkflowDraft: Codable, Equatable, Sendable {
  public var workflowId: String
  public var notebookKindTag: String
  public var translationEnabled: Bool

  public init(
    workflowId: String,
    notebookKindTag: String = "notebook-kind:imported-material",
    translationEnabled: Bool = false
  ) {
    self.workflowId = workflowId
    self.notebookKindTag = notebookKindTag
    self.translationEnabled = translationEnabled
  }
}

public struct RielaNoteConfigAgentProposal: Equatable, Identifiable, Sendable {
  public var id: String
  public var requestMarkdown: String
  public var assistantMarkdown: String
  public var tagClass: RielaNoteConfigTagClassDraft
  public var tag: RielaNoteConfigTagDraft
  public var autoAction: RielaNoteConfigAutoActionDraft
  public var ingestionWorkflow: RielaNoteConfigIngestionWorkflowDraft
  public var appliedResult: RielaNoteConfigAgentApplyResult?

  public init(
    id: String = UUID().uuidString,
    requestMarkdown: String,
    assistantMarkdown: String,
    tagClass: RielaNoteConfigTagClassDraft,
    tag: RielaNoteConfigTagDraft,
    autoAction: RielaNoteConfigAutoActionDraft,
    ingestionWorkflow: RielaNoteConfigIngestionWorkflowDraft,
    appliedResult: RielaNoteConfigAgentApplyResult? = nil
  ) {
    self.id = id
    self.requestMarkdown = requestMarkdown
    self.assistantMarkdown = assistantMarkdown
    self.tagClass = tagClass
    self.tag = tag
    self.autoAction = autoAction
    self.ingestionWorkflow = ingestionWorkflow
    self.appliedResult = appliedResult
  }
}

public struct RielaNoteConfigAgentApplyResult: Equatable, Sendable {
  public var tagClass: TagClass
  public var tag: Tag
  public var autoAction: AutoAction
  public var workflowScaffold: NoteIngestionWorkflowScaffoldResult

  public init(
    tagClass: TagClass,
    tag: Tag,
    autoAction: AutoAction,
    workflowScaffold: NoteIngestionWorkflowScaffoldResult
  ) {
    self.tagClass = tagClass
    self.tag = tag
    self.autoAction = autoAction
    self.workflowScaffold = workflowScaffold
  }
}
