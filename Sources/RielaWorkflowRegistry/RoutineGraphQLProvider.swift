import Foundation
import RielaCore
import RielaGraphQL

/// Local provider for the routine GraphQL domain, delegating to
/// `RoutineService` (SQLite record + event source/binding files + workflow
/// deactivation on completion).
public struct FileRoutineGraphQLProvider: RoutineGraphQLProviding, Sendable {
  public var workingDirectory: String
  public var environment: [String: String]

  public init(
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.workingDirectory = workingDirectory
    self.environment = environment
  }

  private var service: RoutineService {
    RoutineService(workingDirectory: workingDirectory, environment: environment)
  }

  public func routines(filter: GraphQLRoutineFilterInput?) async throws -> [GraphQLRoutine] {
    try mapServiceError {
      try service.list(
        filter: RoutineListFilter(
          status: filter?.status?.routineStatus,
          workflowName: filter?.workflowName,
          limit: filter?.limit
        ),
        routineStoreRoot: filter?.routineStoreRoot
      ).map(GraphQLRoutine.init)
    }
  }

  public func routine(routineId: String, routineStoreRoot: String?) async throws -> GraphQLRoutine {
    try mapServiceError {
      GraphQLRoutine(try service.get(routineId: routineId, routineStoreRoot: routineStoreRoot))
    }
  }

  public func createRoutine(input: GraphQLCreateRoutineInput) async throws -> GraphQLRoutineMutationPayload {
    try mapServiceError {
      payload(try service.create(RoutineCreateRequest(
        name: input.name,
        instruction: input.instruction,
        task: input.task,
        schedule: input.schedule,
        every: input.every,
        timezone: input.timezone,
        workflowName: input.workflowName,
        completionCriteria: input.completionCriteria,
        eventRoot: input.eventRoot,
        routineStoreRoot: input.routineStoreRoot,
        deactivateWorkflowOnCompletion: input.deactivateWorkflowOnCompletion,
        origin: input.origin
      )))
    }
  }

  public func completeRoutine(input: GraphQLCompleteRoutineInput) async throws -> GraphQLRoutineMutationPayload {
    try mapServiceError {
      payload(try service.complete(
        routineId: input.routineId,
        note: input.note,
        routineStoreRoot: input.routineStoreRoot
      ))
    }
  }

  public func setRoutineStatus(input: GraphQLSetRoutineStatusInput) async throws -> GraphQLRoutineMutationPayload {
    try mapServiceError {
      payload(try service.setStatus(
        routineId: input.routineId,
        status: input.status.routineStatus,
        routineStoreRoot: input.routineStoreRoot
      ))
    }
  }

  public func deleteRoutine(input: GraphQLDeleteRoutineInput) async throws -> GraphQLRoutineMutationPayload {
    try mapServiceError {
      payload(try service.delete(
        routineId: input.routineId,
        routineStoreRoot: input.routineStoreRoot
      ))
    }
  }

  private func payload(_ result: RoutineMutationResult) -> GraphQLRoutineMutationPayload {
    GraphQLRoutineMutationPayload(
      accepted: true,
      routine: GraphQLRoutine(result.routine),
      diagnostics: result.diagnostics
    )
  }

  private func mapServiceError<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as RoutineGraphQLError {
      throw error
    } catch let error as RoutineServiceError {
      throw RoutineGraphQLError(code: "INVALID_ROUTINE", message: error.message)
    } catch let error as RoutineStoreError {
      throw RoutineGraphQLError(code: "ROUTINE_IO_FAILURE", message: error.message)
    } catch {
      throw RoutineGraphQLError(code: "ROUTINE_IO_FAILURE", message: "\(error)")
    }
  }
}
