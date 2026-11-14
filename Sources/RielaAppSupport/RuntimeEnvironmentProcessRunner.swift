import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// No shell, output files, stderr retention, or argv-bearing process errors.
public struct RuntimeEnvironmentProcessRunner: RuntimeEnvironmentCommandRunning {
  public init() {}
  public func run(source: RuntimeEnvironmentCommandSource, baseEnvironment: [String: String], maxOutputBytes: Int) async throws -> Data {
    let task = Task.detached { try Self.capture(source, environment: baseEnvironment, limit: maxOutputBytes) }
    return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
  }

  private static func capture(_ source: RuntimeEnvironmentCommandSource, environment: [String: String], limit: Int) throws -> Data {
    guard let first = source.command.first, !first.isEmpty, limit > 0,
      source.timeoutSeconds.isFinite, source.timeoutSeconds > 0,
      source.command.allSatisfy({ !$0.contains("\0") }),
      environment.allSatisfy({ isValidEnvironmentVariableName($0.key) && !$0.value.contains("\0") }) else { throw RuntimeEnvironmentError.invalidConfiguration }
    let executable: String
    if first.hasPrefix("/") { executable = first } else {
      guard let path = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map({ String($0) + "/" + first })
        .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw RuntimeEnvironmentError.sourceFailed }
      executable = path
    }
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else { throw RuntimeEnvironmentError.sourceFailed }
    defer { close(descriptors[0]); if descriptors[1] >= 0 { close(descriptors[1]) } }
    let null = open("/dev/null", O_RDWR)
    guard null >= 0 else { throw RuntimeEnvironmentError.sourceFailed }
    defer { close(null) }
    #if canImport(Glibc)
    var actions = posix_spawn_file_actions_t()
    var attributes = posix_spawnattr_t()
    #else
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    #endif
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw RuntimeEnvironmentError.sourceFailed }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { throw RuntimeEnvironmentError.sourceFailed }
    defer { posix_spawnattr_destroy(&attributes) }
    func check(_ result: Int32) throws { if result != 0 { throw RuntimeEnvironmentError.sourceFailed } }
    try check(posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO))
    try check(posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO))
    try check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO))
    for descriptor in [descriptors[0], descriptors[1], null] { try check(posix_spawn_file_actions_addclose(&actions, descriptor)) }
    #if canImport(Darwin)
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
    #else
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
    #endif
    var signals = sigset_t(); sigemptyset(&signals)
    for value in [SIGINT, SIGTERM, SIGPIPE] { sigaddset(&signals, value) }
    var mask = sigset_t(); sigemptyset(&mask)
    try check(posix_spawnattr_setsigdefault(&attributes, &signals))
    try check(posix_spawnattr_setsigmask(&attributes, &mask))
    try check(posix_spawnattr_setflags(&attributes, flags))
    try check(posix_spawnattr_setpgroup(&attributes, 0))
    var argv = source.command.map { strdup($0) } + [nil]
    var envp = environment.keys.sorted().map { strdup($0 + "=" + environment[$0]!) } + [nil]
    defer { for value in argv { free(value) }; for value in envp { free(value) } }
    var child: pid_t = 0
    let spawned = executable.withCString { path in
      argv.withUnsafeMutableBufferPointer { args in
        envp.withUnsafeMutableBufferPointer { env in posix_spawn(&child, path, &actions, &attributes, args.baseAddress!, env.baseAddress!) }
      }
    }
    try check(spawned)
    close(descriptors[1]); descriptors[1] = -1
    // The leader stays unreaped through group cleanup, so its PGID cannot be
    // recycled while we signal descendants, including on timeout/cancellation.
    var status: Int32 = 0
    var reaped = false
    defer {
      if !reaped {
        kill(-child, SIGKILL)
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
      }
    }
    try check(fcntl(descriptors[0], F_SETFL, O_NONBLOCK) < 0 ? -1 : 0)
    let end = ProcessInfo.processInfo.systemUptime + source.timeoutSeconds
    var output = Data(); var eof = false; var exited = false
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !eof || !exited {
      try Task.checkCancellation()
      if ProcessInfo.processInfo.systemUptime >= end { throw RuntimeEnvironmentError.sourceTimeout }
      if !eof {
        let count = buffer.withUnsafeMutableBytes { read(descriptors[0], $0.baseAddress, $0.count) }
        if count > 0 {
          guard output.count + count <= limit else { throw RuntimeEnvironmentError.outputTooLarge }
          output.append(contentsOf: buffer.prefix(count))
        } else if count == 0 { eof = true } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw RuntimeEnvironmentError.sourceFailed }
      }
      if !exited {
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT)
        if result < 0 && errno != EINTR { throw RuntimeEnvironmentError.sourceFailed }
        exited = info.si_signo != 0
      }
      if !eof || !exited { Thread.sleep(forTimeInterval: 0.005) }
    }
    kill(-child, SIGKILL)
    var waited: pid_t
    repeat { waited = waitpid(child, &status, 0) } while waited < 0 && errno == EINTR
    reaped = true
    guard waited == child, status & 0x7f == 0, (status >> 8) & 0xff == 0 else { throw RuntimeEnvironmentError.sourceFailed }
    return output
  }
}
