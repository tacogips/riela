// Remove macOS-only package pins from a copy of Package.resolved before a
// Linux build. SwiftPM can fetch every pinned package before it evaluates the
// Linux manifest, so a stale macOS-only pin to a private repository would need
// credentials that Linux builds must not receive.
//
// Usage: swift scripts/strip-macos-only-pins.swift [Package.resolved]
// Runs with the Swift toolchain alone (no Python in the Swift build images).
import Foundation

/// Packages that Package.swift links only on macOS.
let macOSOnlyIdentities: Set<String> = ["notion-gateway"]

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count <= 1 else {
  FileHandle.standardError.write(Data("usage: swift scripts/strip-macos-only-pins.swift [Package.resolved]\n".utf8))
  exit(2)
}
let file = URL(fileURLWithPath: arguments.first ?? "Package.resolved")
do {
  guard var lock = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
        let pins = lock["pins"] as? [[String: Any]] else {
    FileHandle.standardError.write(Data("\(file.path): not a Package.resolved pins file\n".utf8))
    exit(1)
  }
  let kept = pins.filter { !macOSOnlyIdentities.contains(($0["identity"] as? String ?? "").lowercased()) }
  lock["pins"] = kept
  // The origin hash covers the removed pins; SwiftPM recomputes it.
  lock.removeValue(forKey: "originHash")
  try JSONSerialization.data(withJSONObject: lock, options: [.prettyPrinted, .sortedKeys]).write(to: file)
  print("removed \(pins.count - kept.count) macOS-only pin(s) from \(file.path)")
} catch {
  FileHandle.standardError.write(Data("\(file.path): \(error)\n".utf8))
  exit(1)
}
