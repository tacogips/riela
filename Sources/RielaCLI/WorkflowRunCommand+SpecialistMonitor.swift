import Foundation

extension WorkflowRunCommand {
  public func run(_ options: WorkflowRunOptions) async -> CLICommandResult {
    guard let control = specialistMonitorControl else { return await runWithoutSpecialistMonitor(options) }
    return await control.run(options: options) { await runWithoutSpecialistMonitor(options) }
  }
}
