#if os(macOS)
import XCTest
@testable import RielaAppSupport

final class RielaAppLaunchOptionsTests: XCTestCase {
  func testRelativePathOptionsResolveAgainstLaunchWorkingDirectory() {
    let options = RielaAppLaunchOptions(
      arguments: [
        "--home-root", "homes/app",
        "--app-root", "state/app",
        "--project-root", "projects/demo",
        "--import-workflow-or-package", "archives/demo.rielapkg",
        "--import-workflow-or-package=workflows/local-demo",
        "--open-viewer", "workflows/view-demo",
        "--session-store-root", "sessions/view-demo"
      ],
      environment: [:],
      workingDirectory: "/tmp/riela-launch"
    )

    XCTAssertEqual(options.homeDirectory(defaultHome: "fallback-home").path, "/tmp/riela-launch/homes/app")
    XCTAssertEqual(options.appRoot?.path, "/tmp/riela-launch/state/app")
    XCTAssertEqual(options.projectRoot?.path, "/tmp/riela-launch/projects/demo")
    XCTAssertEqual(options.importSources.map(\.path), [
      "/tmp/riela-launch/archives/demo.rielapkg",
      "/tmp/riela-launch/workflows/local-demo"
    ])
    XCTAssertEqual(options.initialViewer, RielaAppLaunchOptions.InitialViewer(
      workflowPath: "/tmp/riela-launch/workflows/view-demo",
      sessionStoreRoot: "/tmp/riela-launch/sessions/view-demo"
    ))
  }

  func testEnvironmentPathFallbacksResolveAgainstLaunchWorkingDirectory() {
    let options = RielaAppLaunchOptions(
      arguments: [],
      environment: [
        "HOME": "env/home",
        "RIELA_APP_HOME": "env/app-home",
        "RIELA_APP_ROOT": "env/app-root"
      ],
      workingDirectory: "/tmp/riela-launch"
    )

    XCTAssertEqual(options.homeDirectory(defaultHome: "fallback-home").path, "/tmp/riela-launch/env/app-home")
    XCTAssertEqual(options.appRoot?.path, "/tmp/riela-launch/env/app-root")
  }

  func testDefaultHomeFallbackResolvesAgainstLaunchWorkingDirectory() {
    let options = RielaAppLaunchOptions(
      arguments: [],
      environment: [:],
      workingDirectory: "/tmp/riela-launch"
    )

    XCTAssertEqual(options.homeDirectory(defaultHome: "fallback-home").path, "/tmp/riela-launch/fallback-home")
  }
}
#endif
