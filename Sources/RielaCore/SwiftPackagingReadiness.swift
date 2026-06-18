public enum SwiftHomebrewReadinessTarget: String, CaseIterable, Codable, Equatable, Sendable {
  case darwinArm64 = "darwin-arm64"
  case darwinX64 = "darwin-x64"

  public var arch: String {
    switch self {
    case .darwinArm64:
      "arm64"
    case .darwinX64:
      "x64"
    }
  }
}

public struct SwiftHomebrewReadinessArchivePlan: Codable, Equatable, Sendable {
  public var version: String
  public var target: SwiftHomebrewReadinessTarget
  public var executableProduct: String
  public var releaseBinPathCommand: [String]
  public var stagedBinaryPath: String
  public var archivePath: String
  public var checksumPath: String
  public var publishSideEffects: Bool

  public init(
    version: String,
    target: SwiftHomebrewReadinessTarget,
    executableProduct: String,
    releaseBinPathCommand: [String],
    stagedBinaryPath: String,
    archivePath: String,
    checksumPath: String,
    publishSideEffects: Bool
  ) {
    self.version = version
    self.target = target
    self.executableProduct = executableProduct
    self.releaseBinPathCommand = releaseBinPathCommand
    self.stagedBinaryPath = stagedBinaryPath
    self.archivePath = archivePath
    self.checksumPath = checksumPath
    self.publishSideEffects = publishSideEffects
  }
}

// Existing public API name is intentionally descriptive.
// swiftlint:disable:next identifier_name
public let swiftHomebrewReadinessReleaseBinPathCommand: [String] = [
  "env",
  "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer",
  "SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
  "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
  "build",
  "-c",
  "release",
  "--product",
  "riela",
  "--show-bin-path"
]

public func makeSwiftHomebrewReadinessArchivePlan(
  version: String,
  target: SwiftHomebrewReadinessTarget,
  releaseDirectory: String = "dist/swift-homebrew"
) -> SwiftHomebrewReadinessArchivePlan {
  let packageName = "riela-\(version)-\(target.rawValue)"
  let archivePath = "\(releaseDirectory)/riela-swift-\(version)-\(target.rawValue).tar.gz"
  return SwiftHomebrewReadinessArchivePlan(
    version: version,
    target: target,
    executableProduct: "riela",
    releaseBinPathCommand: swiftHomebrewReadinessReleaseBinPathCommand,
    stagedBinaryPath: "\(releaseDirectory)/work/\(packageName)/bin/riela",
    archivePath: archivePath,
    checksumPath: "\(archivePath).sha256",
    publishSideEffects: false
  )
}

public enum SwiftHomebrewProductionTarget: String, CaseIterable, Codable, Equatable, Sendable {
  case darwinArm64 = "darwin-arm64"
  case darwinX64 = "darwin-x64"

  public var triple: String {
    switch self {
    case .darwinArm64:
      "arm64-apple-macosx"
    case .darwinX64:
      "x86_64-apple-macosx"
    }
  }
}

public struct SwiftHomebrewProductionArchivePlan: Codable, Equatable, Sendable {
  public var version: String
  public var target: SwiftHomebrewProductionTarget
  public var executableProduct: String
  public var releaseDirectory: String
  public var stagedBinaryPath: String
  public var archivePath: String
  public var checksumPath: String
  public var publishSideEffects: Bool

  public init(
    version: String,
    target: SwiftHomebrewProductionTarget,
    executableProduct: String,
    releaseDirectory: String,
    stagedBinaryPath: String,
    archivePath: String,
    checksumPath: String,
    publishSideEffects: Bool
  ) {
    self.version = version
    self.target = target
    self.executableProduct = executableProduct
    self.releaseDirectory = releaseDirectory
    self.stagedBinaryPath = stagedBinaryPath
    self.archivePath = archivePath
    self.checksumPath = checksumPath
    self.publishSideEffects = publishSideEffects
  }
}

public func makeSwiftHomebrewProductionArchivePlan(
  version: String,
  target: SwiftHomebrewProductionTarget,
  releaseDirectory: String = "dist/homebrew"
) -> SwiftHomebrewProductionArchivePlan {
  let packageName = "riela-\(version)-\(target.rawValue)"
  let archivePath = "\(releaseDirectory)/riela-\(version)-\(target.rawValue).tar.gz"
  return SwiftHomebrewProductionArchivePlan(
    version: version,
    target: target,
    executableProduct: "riela",
    releaseDirectory: releaseDirectory,
    stagedBinaryPath: "\(releaseDirectory)/work/\(packageName)/bin/riela",
    archivePath: archivePath,
    checksumPath: "\(archivePath).sha256",
    publishSideEffects: false
  )
}

public enum SwiftHomebrewCaskTarget: String, CaseIterable, Codable, Equatable, Sendable {
  case darwinArm64 = "darwin-arm64"
  case darwinX64 = "darwin-x64"

  public var triple: String {
    switch self {
    case .darwinArm64:
      "arm64-apple-macosx"
    case .darwinX64:
      "x86_64-apple-macosx"
    }
  }

  public var installPrefix: String {
    switch self {
    case .darwinArm64:
      "/opt/homebrew"
    case .darwinX64:
      "/usr/local"
    }
  }
}

public struct SwiftHomebrewCaskArchivePlan: Codable, Equatable, Sendable {
  public var version: String
  public var target: SwiftHomebrewCaskTarget
  public var executableProduct: String
  public var releaseDirectory: String
  public var stagedBinaryPath: String
  public var archiveRootPath: String
  public var dmgPath: String
  public var checksumPath: String
  public var installPrefix: String
  public var requiresAppleCredentials: Bool
  public var publishSideEffects: Bool

  public init(
    version: String,
    target: SwiftHomebrewCaskTarget,
    executableProduct: String,
    releaseDirectory: String,
    stagedBinaryPath: String,
    archiveRootPath: String,
    dmgPath: String,
    checksumPath: String,
    installPrefix: String,
    requiresAppleCredentials: Bool,
    publishSideEffects: Bool
  ) {
    self.version = version
    self.target = target
    self.executableProduct = executableProduct
    self.releaseDirectory = releaseDirectory
    self.stagedBinaryPath = stagedBinaryPath
    self.archiveRootPath = archiveRootPath
    self.dmgPath = dmgPath
    self.checksumPath = checksumPath
    self.installPrefix = installPrefix
    self.requiresAppleCredentials = requiresAppleCredentials
    self.publishSideEffects = publishSideEffects
  }
}

public func makeSwiftHomebrewCaskArchivePlan(
  version: String,
  target: SwiftHomebrewCaskTarget,
  releaseDirectory: String = "dist/homebrew-cask"
) -> SwiftHomebrewCaskArchivePlan {
  let archiveName = "riela-\(version)-\(target.rawValue)"
  let workDirectory = "\(releaseDirectory)/work/\(archiveName)"
  let dmgPath = "\(releaseDirectory)/\(archiveName).dmg"
  return SwiftHomebrewCaskArchivePlan(
    version: version,
    target: target,
    executableProduct: "riela",
    releaseDirectory: releaseDirectory,
    stagedBinaryPath: "\(workDirectory)/riela",
    archiveRootPath: workDirectory,
    dmgPath: dmgPath,
    checksumPath: "\(dmgPath).sha256",
    installPrefix: target.installPrefix,
    requiresAppleCredentials: true,
    publishSideEffects: false
  )
}
