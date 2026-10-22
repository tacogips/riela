#if os(macOS)
import Foundation
import RielaCore
import RielaServer

private struct WorkerSettingsUpdate: Decodable {
  let expectedProfile: String
  let expectedConfiguration: DistributedControllerConfiguration?
  let configuration: DistributedControllerConfiguration
}

extension RielaApp {
  func workerSettingsResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse? {
    if request.path == "/api/v1/settings/workers/start" || request.path == "/api/v1/settings/workers/stop" {
      return await workerControllerToggleResponse(for: request)
    }
    guard request.path == "/api/v1/settings/workers" else { return nil }
    return await distributedControllerOperations.run { [self] in
      let url = distributedControllerConfigurationURL
      do {
        let saved = FileManager.default.fileExists(atPath: url.path)
          ? try DistributedControllerConfiguration.load(from: url) : nil
        if request.method == "GET" {
          let configuration = saved ?? .init(
            host: "127.0.0.1", port: 8788, storePath: "distributed/jobs.json",
            workers: [.init(id: "worker-1", groups: [], maxCapacity: 1)]
          )
          let encoder = JSONEncoder()
          let encoded = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(configuration))
          let original = try saved.map { try JSONDecoder().decode(JSONValue.self, from: encoder.encode($0)) }
          return .json(status: 200, .object([
            "profile": .string(daemonProfileName.rawValue), "configuration": encoded,
            "savedConfiguration": original ?? .null,
            "status": .string(distributedControllerStatus),
            "running": .bool(distributedController != nil),
            "workers": .array(await distributedWorkerStatusJSON())
          ]))
        }
        guard request.method == "PUT" else { return .text(status: 405, "Method not allowed") }
        let update = try JSONDecoder().decode(WorkerSettingsUpdate.self, from: request.body)
        guard update.expectedProfile == daemonProfileName.rawValue,
              update.expectedConfiguration == saved else {
          return .json(status: 409, .object(["message": .string("Settings changed. Refresh before saving again.")]))
        }
        guard !terminationShutdownStarted else { return .text(status: 503, "The app is shutting down.") }
        try update.configuration.validate()
        let message = await performDistributedControllerConfigurationSave(update.configuration, at: url)
        return .json(status: message.hasPrefix("Settings saved.") ? 200 : 409, .object(["message": .string(message)]))
      } catch {
        return .json(status: 400, .object([
          "message": .string("Cannot read or save controller settings. Check the address, port, storage path, unique worker IDs.")
        ]))
      }
    }
  }

  /// Start/stop moved from the menu-bar menu into console Settings.
  private func workerControllerToggleResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    guard request.method == "POST" else { return .text(status: 405, "Method not allowed") }
    let starts = request.path.hasSuffix("/start")
    return await distributedControllerOperations.run { [self] in
      guard !terminationShutdownStarted else { return .text(status: 503, "The app is shutting down.") }
      if starts {
        await performDistributedControllerStart()
      } else {
        await performDistributedControllerStop()
      }
      let succeeded = (distributedController != nil) == starts
      return .json(status: succeeded ? 200 : 409, .object([
        "message": .string(distributedControllerStatus),
        "running": .bool(distributedController != nil)
      ]))
    }
  }

  private func distributedWorkerStatusJSON() async -> [JSONValue] {
    guard let host = distributedController,
          let workers = try? await host.controller.workers(now: Date()) else { return [] }
    return host.configuration.workers.sorted { $0.id < $1.id }.map { configured in
      guard let worker = workers.first(where: { $0.workerId == configured.id }) else {
        return .object(["id": .string(configured.id), "connected": .bool(false)])
      }
      return .object([
        "id": .string(worker.workerId),
        "connected": .bool(true),
        "online": .bool(worker.online),
        "running": .number(Double(worker.activeJobIds.count)),
        "capacity": .number(Double(worker.capacity)),
        "groups": .array(worker.groups.sorted().map(JSONValue.string))
      ])
    }
  }
}
#endif
