import RielaWorkflowRegistry

// Retain the CLI's module-qualified public source API after moving persistence
// to the registry layer shared by CLI, editor and API publication.
public typealias WorkflowHistoryStore = RielaWorkflowRegistry.WorkflowHistoryStore
public typealias WorkflowSnapshotReference = RielaWorkflowRegistry.WorkflowSnapshotReference
