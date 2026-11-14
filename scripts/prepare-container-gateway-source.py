#!/usr/bin/env python3
"""Apply the Linux build adaptations to pinned gateway source snapshots.

These changes affect build-context copies only. Exact anchors make upstream
drift fail rather than silently producing a different gateway implementation.
"""

import argparse
import textwrap
from pathlib import Path


def replace(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"Expected exactly one Linux adaptation anchor in {path.name}")
    path.write_text(text.replace(old, new, 1))


def prepare_x(root: Path) -> None:
    executor = root / "Sources/XGatewayCore/XGatewayLiveExecutor.swift"
    replace(executor, "import Foundation\n",
            "import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n")
    text = executor.read_text()
    if text.count("URLResponse()") != 4:
        raise SystemExit("Expected exactly four URLResponse adaptations")
    text = text.replace("URLResponse()", 'URLResponse(url: URL(fileURLWithPath: "/"), mimeType: nil, expectedContentLength: 0, textEncodingName: nil)')
    executor.write_text(text)


def prepare_gmail(root: Path, crypto_version: str = "3.15.1") -> None:
    crypto_import = "#if canImport(CryptoKit)\nimport CryptoKit\n#else\nimport Crypto\n#endif\n"
    bootstrap = root / "Sources/GmailGatewayCore/GmailOAuthBootstrap.swift"
    replace(bootstrap, "import CryptoKit\nimport Darwin\nimport Foundation\nimport Security\n",
            crypto_import + "#if os(Linux)\nimport Glibc\n#else\nimport Darwin\n#endif\nimport Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n")
    replace(root / "Sources/GmailGatewayCore/GmailGatewayUtilities.swift", "import Foundation\n", "import Foundation\nimport CoreFoundation\n")
    replace(root / "Sources/GmailGatewayCore/MessageFileDownloads.swift", "import CryptoKit\n", crypto_import)
    replace(root / "Package.swift", "  targets: [\n",
            f'  dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "{crypto_version}")],\n  targets: [\n')
    replace(root / "Package.swift", '.target(name: "GmailGatewayCore"),',
            '.target(name: "GmailGatewayCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),')
    replace(bootstrap, "        let fd = socket(AF_INET, SOCK_STREAM, 0)\n",
            "#if os(Linux)\n        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)\n#else\n        let fd = socket(AF_INET, SOCK_STREAM, 0)\n#endif\n")
    replace(bootstrap, "        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)\n",
            "#if !os(Linux)\n        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)\n#endif\n")
    for function in ("bind", "read", "write"):
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


def prepare_analytics(root: Path, crypto_version: str = "4.5.1") -> None:
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
    replace(root / "Package.swift", "  ],\n  targets: [\n",
            f'  ],\n  dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "{crypto_version}")],\n  targets: [\n')
    replace(root / "Package.swift", '.target(name: "GoogleAnalyticsGatewayCore"),',
            '.target(name: "GoogleAnalyticsGatewayCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),')


def prepare_documents(root: Path, crypto_version: str = "4.5.1") -> None:
    core = root / "Sources/GoogleDocumentsGatewayCore"
    replace(core / "GatewayCredentials.swift", "import CryptoKit\n",
            "#if canImport(CryptoKit)\nimport CryptoKit\n#else\nimport Crypto\n#endif\n")
    replace(core / "GatewayRuntime.swift", "@preconcurrency import Foundation\n",
            "@preconcurrency import Foundation\nimport CoreFoundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n")
    replace(root / "Package.swift", "  ],\n  targets: [\n",
            f'  ],\n  dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "{crypto_version}")],\n  targets: [\n')
    replace(root / "Package.swift", '.target(name: "GoogleDocumentsGatewayCore"),',
            '.target(name: "GoogleDocumentsGatewayCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),')
    loopback = core / "GatewayLoopbackOAuth.swift"
    replace(loopback, "import AppKit\nimport Foundation\nimport Network\n",
            "import Foundation\n#if canImport(AppKit)\nimport AppKit\n#endif\n#if canImport(Network)\nimport Network\n#else\nimport Glibc\n#endif\n")
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
    source = loopback.read_text()
    marker = "private final class LoopbackCallback: @unchecked Sendable {"
    parser_marker = "  private static func parseRequest(_ data: Data) -> LoopbackResult? {"
    if source.count(marker) != 1 or source.count(parser_marker) != 1 or not source.endswith("}\n"):
        raise SystemExit("Expected fixed Documents loopback implementation")
    class_start = source.index(marker)
    parser_start = source.index(parser_marker)
    parser = textwrap.dedent(source[parser_start:-2]).replace("private static func parseRequest", "private func parseLoopbackRequest", 1)
    native_class = source[class_start:parser_start].replace("data.flatMap(Self.parseRequest)", "data.flatMap(parseLoopbackRequest)") + "}\n"
    linux_class = Path(__file__).with_name("container-gateway-support").joinpath("GoogleDocumentsLoopbackLinux.swift").read_text()
    loopback.write_text(source[:class_start] + "#if canImport(Network)\n" + native_class + "#else\n" + linux_class + "\n#endif\n" + parser)


def prepare_riela(root: Path) -> None:
    replace(root / "Package.swift",
            '.product(name: "AnydocKit", package: "anydoc-swift", condition: .when(platforms: [.macOS])),',
            '.product(name: "AnydocKit", package: "anydoc-swift"),')
    replace(root / "Package.swift", """    .package(
      url: "https://github.com/tacogips/anydoc-swift.git",
      revision: "d957c08372786b7062553e83fe9c29880fdee7a4"
    ),""", '    .package(path: "/anydoc-swift"),')
    replace(root / "Package.swift", """    .package(
      url: "https://github.com/tacogips/google-documents-gateway.git",
      revision: "cda93cdd770a51f6f9d1bc63b1db555884824606"
    )""", '    .package(path: "/google-documents-gateway")')
    replace(root / "Package.swift", """          package: "google-documents-gateway",
          condition: .when(platforms: [.macOS])""", """          package: "google-documents-gateway",
          condition: .when(platforms: [.macOS, .linux])""")
    replace(root / "Package.swift", """    .package(
      url: "https://github.com/tacogips/google-analytics-gateway.git",
      revision: "c46443a5e8f744244cb9825d3238958a797c4f2b"
    ),""", '    .package(path: "/google-analytics-gateway"),')
    replace(root / "Package.swift", """          package: "google-analytics-gateway",
          condition: .when(platforms: [.macOS])""", """          package: "google-analytics-gateway",
          condition: .when(platforms: [.macOS, .linux])""")
    replace(root / "Package.swift", """    .package(
      url: "https://github.com/tacogips/gmail-gateway.git",
      revision: "2761f3bccf30ead78de5d6968d827929925eae80"
    ),""", '    .package(path: "/gmail-gateway"),')
    replace(root / "Package.swift",
            '.product(name: "GmailGatewayCore", package: "gmail-gateway", condition: .when(platforms: [.macOS])),',
            '.product(name: "GmailGatewayCore", package: "gmail-gateway", condition: .when(platforms: [.macOS, .linux])),')


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("gateway", choices=("x", "gmail", "analytics", "documents", "riela"))
    parser.add_argument("source", type=Path)
    parser.add_argument("--crypto-version", choices=("3.15.1", "4.5.1"), default="3.15.1")
    arguments = parser.parse_args()
    if arguments.gateway in ("gmail", "analytics", "documents"):
        {"gmail": prepare_gmail, "analytics": prepare_analytics, "documents": prepare_documents}[arguments.gateway](arguments.source, arguments.crypto_version)
    else:
        {"x": prepare_x, "riela": prepare_riela}[arguments.gateway](arguments.source)
