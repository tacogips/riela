#!/usr/bin/env python3
"""Apply the Linux build adaptations to pinned gateway source snapshots.

These changes affect build-context copies only. Exact anchors make upstream
drift fail rather than silently producing a different gateway implementation.
"""

import argparse
import re
from pathlib import Path


def replace(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"Expected exactly one Linux adaptation anchor in {path.name}")
    path.write_text(text.replace(old, new, 1))


def add_crypto_dependency(root: Path, target: str, version: str) -> None:
    manifest = root / "Package.swift"
    replace(manifest, "\n  dependencies: [\n",
            f'\n  dependencies: [\n    .package(url: "https://github.com/apple/swift-crypto.git", exact: "{version}"),\n')
    anchor = f'      name: "{target}",\n      dependencies: ['
    replace(manifest, anchor, anchor + '.product(name: "Crypto", package: "swift-crypto"), ')


def local_package(root: Path, name: str) -> None:
    manifest = root / "Package.swift"
    pattern = (r'\.package\(\s*url: "https://github\.com/tacogips/'
               + re.escape(name) + r'\.git",\s*revision: "[0-9a-f]{40}"\s*\)')
    source, count = re.subn(pattern, f'.package(path: "/{name}")', manifest.read_text())
    if count != 1:
        raise SystemExit(f"Expected exactly one pinned {name} dependency")
    manifest.write_text(source)


def prepare_x(root: Path) -> None:
    executor = root / "Sources/XGatewayCore/XGatewayLiveExecutor.swift"
    replace(executor, "import Foundation\n",
            "import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n")
    text = executor.read_text()
    if text.count("URLResponse()") != 4:
        raise SystemExit("Expected exactly four URLResponse adaptations")
    text = text.replace("URLResponse()", 'URLResponse(url: URL(fileURLWithPath: "/"), mimeType: nil, expectedContentLength: 0, textEncodingName: nil)')
    executor.write_text(text)


def prepare_gmail(root: Path, crypto_version: str = "4.5.2") -> None:
    crypto_import = "#if canImport(CryptoKit)\nimport CryptoKit\n#else\nimport Crypto\n#endif\n"
    bootstrap = root / "Sources/GmailGatewayCore/GmailOAuthBootstrap.swift"
    replace(bootstrap, "import CryptoKit\n", crypto_import)
    replace(bootstrap, "import Darwin\n", "#if os(Linux)\nimport Glibc\n#else\nimport Darwin\n#endif\n")
    replace(bootstrap, "import Foundation\n", "import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n")
    replace(bootstrap, "import Security\n", "")
    replace(root / "Sources/GmailGatewayCore/GmailGatewayUtilities.swift", "import Foundation\n", "import Foundation\nimport CoreFoundation\n")
    replace(root / "Sources/GmailGatewayCore/MessageFileDownloads.swift", "import CryptoKit\n", crypto_import)
    for name in ("GmailCredentialResolution.swift", "GmailOAuthClientFingerprint.swift"):
        replace(root / "Sources/GmailGatewayCore" / name, "import CryptoKit\n", crypto_import)
    add_crypto_dependency(root, "GmailGatewayCore", crypto_version)
    replace(bootstrap, "    let descriptor = socket(addressFamily, SOCK_STREAM, 0)\n",
            "#if os(Linux)\n    let descriptor = socket(addressFamily, Int32(SOCK_STREAM.rawValue), 0)\n#else\n    let descriptor = socket(addressFamily, SOCK_STREAM, 0)\n#endif\n")
    replace(bootstrap, "        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)\n",
            "#if !os(Linux)\n        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)\n#endif\n")
    replace(bootstrap, "        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)\n",
            "#if !os(Linux)\n        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)\n#endif\n")
    replace(bootstrap, "Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))",
            "bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))")
    replace(bootstrap, "Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))",
            "bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))")
    for function in ("read", "write"):
        replace(bootstrap, f"Darwin.{function}(", f"{function}(")
    text = bootstrap.read_text()
    if text.count("Darwin.poll(") != 2:
        raise SystemExit("Expected exactly two poll adaptations")
    bootstrap.write_text(text.replace("Darwin.poll(", "poll("))
    replace(bootstrap, '    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")\n',
            '#if os(Linux)\n    process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")\n#else\n    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")\n#endif\n')
    replace(bootstrap, """    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
        throw authError("Failed to generate secure OAuth random value")
    }
    return base64URLString(Data(bytes))""", """    let key = SymmetricKey(size: SymmetricKeySize(bitCount: byteCount * 8))
    let bytes = key.withUnsafeBytes { Data($0) }
    return base64URLString(bytes)""")


def prepare_analytics(root: Path, crypto_version: str = "4.5.2") -> None:
    core = root / "Sources/GoogleAnalyticsGatewayCore"
    portable_posix = "#if os(Linux)\nimport Glibc\n#else\nimport Darwin\n#endif\n"
    loopback = core / "Auth/OAuthLoopback.swift"
    files = core / "Files/SecureLocalFiles.swift"
    for path in (loopback, files):
        replace(path, "import Darwin\n", portable_posix)
    replace(loopback, "    let fd = socket(AF_INET, SOCK_STREAM, 0)\n",
            "#if os(Linux)\n    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)\n#else\n    let fd = socket(AF_INET, SOCK_STREAM, 0)\n#endif\n")
    replace(loopback, "    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)\n",
            "#if !os(Linux)\n    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)\n#endif\n")
    replace(loopback, "Darwin.bind(", "bind(")
    replace(loopback, """      var noSigPipe: Int32 = 1
      guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw GatewayError(code: .transportFailed, message: "OAuth callback failed")
      }""", """#if !os(Linux)
      var noSigPipe: Int32 = 1
      guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw GatewayError(code: .transportFailed, message: "OAuth callback failed")
      }
#endif""")
    replace(loopback, "    _ = response.withCString { write(client, $0, strlen($0)) }\n",
            "#if os(Linux)\n    _ = response.withCString { send(client, $0, strlen($0), Int32(MSG_NOSIGNAL)) }\n#else\n    _ = response.withCString { write(client, $0, strlen($0)) }\n#endif\n")
    replace(files, """      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec""", "      nativeFileTimesMatch(before, after)")
    with files.open("a") as output:
        output.write("""
private func nativeFileTimesMatch(_ before: stat, _ after: stat) -> Bool {
#if os(Linux)
  return before.st_mtim.tv_sec == after.st_mtim.tv_sec && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec
    && before.st_ctim.tv_sec == after.st_ctim.tv_sec && before.st_ctim.tv_nsec == after.st_ctim.tv_nsec
#else
  return before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
#endif
}
""")
    replace(core / "Auth/OAuthClientConfiguration.swift", "import CryptoKit\n",
            "#if canImport(CryptoKit)\nimport CryptoKit\n#else\nimport Crypto\n#endif\n")
    add_crypto_dependency(root, "GoogleAnalyticsGatewayCore", crypto_version)


def prepare_documents(root: Path, crypto_version: str = "4.5.2") -> None:
    core = root / "Sources/GoogleDocumentsGatewayCore"
    replace(core / "GatewayCredentials.swift", "import CryptoKit\n",
            "#if canImport(CryptoKit)\nimport CryptoKit\n#else\nimport Crypto\n#endif\n")
    replace(core / "GatewayRuntime.swift", "@preconcurrency import Foundation\n",
            "@preconcurrency import Foundation\nimport CoreFoundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n")
    add_crypto_dependency(root, "GoogleDocumentsGatewayCore", crypto_version)
    loopback = core / "GatewayLoopbackOAuth.swift"
    replace(loopback, "import AppKit\n", "#if canImport(AppKit)\nimport AppKit\n#endif\n")
    replace(loopback, "    browserOpener: { NSWorkspace.shared.open($0) },", """    browserOpener: { url in
#if canImport(AppKit)
      return NSWorkspace.shared.open(url)
#else
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
      process.arguments = [url.absoluteString]
      do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
#endif
    },""")
    # OAuthCallbackServer now comes from portable GoogleGatewayAuth upstream.
    for relative in ("GatewaySecureTokenFilesystem.swift", "SDK/GatewaySDKFileAccessPolicy.swift",
                     "SDK/GatewaySDKCatalogFileSnapshots.swift", "SDK/GatewaySDKCommandRouter.swift",
                     "SDK/GatewaySDKCredentialLoading.swift"):
        path = core / relative
        replace(path, "import Darwin\n", "#if os(Linux)\nimport Glibc\n#else\nimport Darwin\n#endif\n")
        path.write_text(path.read_text().replace("RENAME_EXCL", "gatewayRenameExclusive").replace("RENAME_SWAP", "gatewayRenameExchange"))
    filesystem = core / "GatewaySecureTokenFilesystem.swift"
    filesystem.write_text(filesystem.read_text().replace("flock(", "gatewayFlock("))
    shim = Path(__file__).with_name("container-gateway-support") / "GoogleDocumentsPOSIX.swift"
    (core / shim.name).write_text(shim.read_text())


def prepare_riela(root: Path) -> None:
    replace(root / "Package.swift",
            '.product(name: "AnydocKit", package: "anydoc-swift", condition: .when(platforms: [.macOS])),',
            '.product(name: "AnydocKit", package: "anydoc-swift"),')
    local_package(root, "anydoc-swift")
    local_package(root, "google-documents-gateway")
    replace(root / "Package.swift", """          package: "google-documents-gateway",
          condition: .when(platforms: [.macOS])""", """          package: "google-documents-gateway",
          condition: .when(platforms: [.macOS, .linux])""")
    local_package(root, "google-analytics-gateway")
    replace(root / "Package.swift", """          package: "google-analytics-gateway",
          condition: .when(platforms: [.macOS])""", """          package: "google-analytics-gateway",
          condition: .when(platforms: [.macOS, .linux])""")
    local_package(root, "gmail-gateway")
    replace(root / "Package.swift",
            '.product(name: "GmailGatewayCore", package: "gmail-gateway", condition: .when(platforms: [.macOS])),',
            '.product(name: "GmailGatewayCore", package: "gmail-gateway", condition: .when(platforms: [.macOS, .linux])),')


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("gateway", choices=("x", "gmail", "analytics", "documents", "riela"))
    parser.add_argument("source", type=Path)
    parser.add_argument("--crypto-version", choices=("4.5.2",), default="4.5.2")
    arguments = parser.parse_args()
    if arguments.gateway in ("gmail", "analytics", "documents"):
        {"gmail": prepare_gmail, "analytics": prepare_analytics, "documents": prepare_documents}[arguments.gateway](arguments.source, arguments.crypto_version)
    else:
        {"x": prepare_x, "riela": prepare_riela}[arguments.gateway](arguments.source)
