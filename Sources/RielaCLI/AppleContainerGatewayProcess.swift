import Foundation
import RielaAdapters
import RielaCore

/// Apple Container persists init stdio. Run the reader only through attached exec,
/// whose streams are direct pipes, and never put credentials in init configuration.
struct AppleContainerGatewayProcess: Sendable {
  var executable: String
  var environment: [String: String]
  var workingDirectory: URL
  var runner: any LocalProcessRunning

  func run(image: String, mounts: [ContainerRuntimeMount], networkAllowed: Bool,
           gateway: ContainerGatewayAddon, document: String, bindings: [String: String],
           deadline: Date?) async throws -> LocalProcessResult {
    let frame = try Self.bindingFrame(bindings)
    let name = "riela-gateway-" + UUID().uuidString.lowercased()
    let effectiveDeadline = deadline ?? Date().addingTimeInterval(600)
    let lifetime = max(1, Int(ceil(effectiveDeadline.timeIntervalSinceNow)) + 30)
    var start = ["run", "-d", "--rm", "--name", name, "--read-only", "--cap-drop", "ALL",
                 "--user", "10001:10001", "--cpus", "2", "--memory", "1G", "--shm-size", "256M",
                 "--ulimit", "nproc=256:256", "--ulimit", "core=0:0"]
    if networkAllowed {
      // The current Apple default network uses IPv4. Avoid failed AAAA resolution
      // suppressing a usable A response, without replacing the host DNS resolver.
      start += ["--dns-option", "no-aaaa"]
    } else {
      start += ["--network", "none", "--no-dns"]
    }
    for mount in mounts.sorted(by: { $0.volumeArgument < $1.volumeArgument }) {
      start += ["--mount", mount.mountArgument]
    }
    start += ["--entrypoint", "/bin/sleep", image, String(lifetime)]
    let result: LocalProcessResult
    do {
      let started = try await runner.run(configuration: configuration(start), stdin: "", deadline: effectiveDeadline)
      guard started.terminationStatus == 0 else {
        throw AdapterExecutionError(.providerError, "Apple Container gateway initialization failed (gatewayStage=container-initialization, containerExitCode=\(started.terminationStatus))")
      }
      var execute = ["exec", "-i"]
      execute += [name, "/usr/local/bin/riela-gateway-guard", gateway.entrypoint]
      execute += gateway.arguments(document: document)
      result = try await runner.run(configuration: configuration(execute), stdin: frame, deadline: effectiveDeadline)
    } catch {
      await cleanup(name)
      throw error
    }
    await cleanup(name)
    return result
  }

  static func bindingFrame(_ bindings: [String: String]) throws -> String {
    guard bindings.count <= 128 else { throw AdapterExecutionError(.policyBlocked, "too many gateway environment bindings") }
    var frame = "RIELAENV1\n\(bindings.count)\n"
    for key in bindings.keys.sorted() {
      let value = bindings[key] ?? ""
      guard !value.contains("\0"), key.utf8.count <= 255 else {
        throw AdapterExecutionError(.policyBlocked, "invalid gateway environment binding")
      }
      frame += "\(key.utf8.count)\n\(value.utf8.count)\n\(key)\(value)"
    }
    guard frame.utf8.count <= 1_048_576 else {
      throw AdapterExecutionError(.policyBlocked, "gateway environment exceeds private transport limit")
    }
    return frame
  }

  private func configuration(_ arguments: [String]) -> LocalProcessConfiguration {
    LocalProcessConfiguration(
      executableURL: URL(fileURLWithPath: executable.hasPrefix("/") ? executable : "/usr/bin/env"),
      arguments: executable.hasPrefix("/") ? arguments : [executable] + arguments,
      environment: environment,
      unsetEnvironmentKeys: ["RIELA_WORKFLOW_INPUT", "RIELA_WORKFLOW_OUTPUT"],
      workingDirectoryURL: workingDirectory, inheritEnvironment: false)
  }

  private func cleanup(_ name: String) async {
    // Cancellation of the invoking workflow must not cancel container removal.
    let configuration = configuration(["delete", "--force", name])
    let runner = runner
    await Task.detached {
      _ = try? await runner.run(configuration: configuration, stdin: "", deadline: Date().addingTimeInterval(10))
    }.value
  }
}
