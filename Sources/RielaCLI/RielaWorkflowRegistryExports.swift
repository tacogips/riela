@_exported import RielaWorkflowRegistry
import RielaCore

public typealias WorkflowActivationState = RielaCore.WorkflowActivationState
public typealias WorkflowOriginIdentity = RielaCore.WorkflowOriginIdentity
public typealias WorkflowProvenance = RielaCore.WorkflowProvenance
public typealias WorkflowScope = RielaCore.WorkflowScope
public typealias WorkflowSourceKind = RielaCore.WorkflowSourceKind
public typealias CLIUsageError = RielaWorkflowRegistry.CLIUsageError
public typealias CLIRuntimeEnvironment = RielaWorkflowRegistry.CLIRuntimeEnvironment
public typealias FileWorkflowRegistryGraphQLProvider =
  RielaWorkflowRegistry.FileWorkflowRegistryGraphQLProvider
public typealias ResolvedWorkflowBundle = RielaWorkflowRegistry.ResolvedWorkflowBundle
public typealias WorkflowBundleResolving = RielaWorkflowRegistry.WorkflowBundleResolving
public typealias WorkflowCatalogEntry = RielaWorkflowRegistry.WorkflowCatalogEntry
public typealias WorkflowMutableRegistry = RielaWorkflowRegistry.WorkflowMutableRegistry
public typealias WorkflowRegistryBundleLoader = RielaWorkflowRegistry.WorkflowRegistryBundleLoader
public typealias WorkflowRegistryMutationResult = RielaWorkflowRegistry.WorkflowRegistryMutationResult
public typealias WorkflowRegistryService = RielaWorkflowRegistry.WorkflowRegistryService
public typealias WorkflowResolutionError = RielaWorkflowRegistry.WorkflowResolutionError
public typealias WorkflowResolutionOptions = RielaWorkflowRegistry.WorkflowResolutionOptions
public typealias WorkflowSharedNodeActivationPolicy =
  RielaWorkflowRegistry.WorkflowSharedNodeActivationPolicy
public typealias WorkflowTransactionStableMetadata =
  RielaWorkflowRegistry.WorkflowTransactionStableMetadata
public typealias WorkflowInjectedInterruption = RielaWorkflowRegistry.WorkflowInjectedInterruption

package typealias WorkflowActivationRecord = RielaWorkflowRegistry.WorkflowActivationRecord
package typealias WorkflowActivationStore = RielaWorkflowRegistry.WorkflowActivationStore
package typealias WorkflowDescriptorRelativeRead =
  RielaWorkflowRegistry.WorkflowDescriptorRelativeRead
package typealias WorkflowDescriptorRelativeReader =
  RielaWorkflowRegistry.WorkflowDescriptorRelativeReader
package typealias WorkflowDetachedOwnershipPinnedRoot =
  RielaWorkflowRegistry.WorkflowDetachedOwnershipPinnedRoot
package typealias WorkflowDetachedOwnershipRoot =
  RielaWorkflowRegistry.WorkflowDetachedOwnershipRoot
package typealias WorkflowHistoryPinnedRoot = RielaWorkflowRegistry.WorkflowHistoryPinnedRoot
package typealias WorkflowMutableRegistryPinnedRoot =
  RielaWorkflowRegistry.WorkflowMutableRegistryPinnedRoot
package typealias WorkflowSharedNodeDependencyInventory =
  RielaWorkflowRegistry.WorkflowSharedNodeDependencyInventory
package typealias WorkflowSharedNodeDependencyReader =
  RielaWorkflowRegistry.WorkflowSharedNodeDependencyReader

package func workflowOriginIdentity(
  name: String,
  workflowId: String,
  scope: WorkflowScope,
  sourceKind: WorkflowSourceKind,
  provenance: WorkflowProvenance,
  locator: String
) -> WorkflowOriginIdentity {
  RielaWorkflowRegistry.workflowOriginIdentity(
    name: name,
    workflowId: workflowId,
    scope: scope,
    sourceKind: sourceKind,
    provenance: provenance,
    locator: locator
  )
}

package func workflowHistoryExclusiveRename(
  oldDirectory: Int32,
  oldName: UnsafePointer<CChar>,
  newDirectory: Int32,
  newName: UnsafePointer<CChar>
) -> Int32 {
  RielaWorkflowRegistry.workflowHistoryExclusiveRename(
    oldDirectory: oldDirectory,
    oldName: oldName,
    newDirectory: newDirectory,
    newName: newName
  )
}
