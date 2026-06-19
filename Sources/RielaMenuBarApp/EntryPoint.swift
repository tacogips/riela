#if os(macOS)
import AppKit
import Foundation
import RielaServer

@main
@MainActor
final class RielaMenuBarApp: NSObject, NSApplicationDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let controller = WorkflowServingController()
  private var selectedWorkflow: WorkflowServeSelection?
  private var selectedWorkingDirectory = FileManager.default.currentDirectoryPath
  private var status = "Stopped"

  static func main() {
    let app = NSApplication.shared
    let delegate = RielaMenuBarApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    configureStatusItem()
    rebuildMenu()
  }

  private func configureStatusItem() {
    statusItem.button?.title = "Riela"
    statusItem.button?.toolTip = "Riela workflow serving client"
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    menu.addItem(menuItem("Select Workflow...", action: #selector(selectWorkflow)))
    menu.addItem(menuItem("Serve", action: #selector(serveWorkflow), enabled: selectedWorkflow != nil))
    menu.addItem(menuItem("Stop", action: #selector(stopWorkflow)))
    menu.addItem(menuItem("Restart", action: #selector(restartWorkflow)))
    menu.addItem(menuItem("Update", action: #selector(updateWorkflow)))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Status: \(status)", action: nil, keyEquivalent: ""))
    if let selectedWorkflow {
      menu.addItem(NSMenuItem(title: "Workflow: \(selectedWorkflow.identifier)", action: nil, keyEquivalent: ""))
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("Quit", action: #selector(quit)))
    statusItem.menu = menu
  }

  private func menuItem(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
    return item
  }

  @objc private func selectWorkflow() {
    let panel = NSOpenPanel()
    panel.title = "Select Riela Workflow"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    selectedWorkflow = .directDirectory(url.path, identifier: url.lastPathComponent)
    selectedWorkingDirectory = url.deletingLastPathComponent().path
    status = "Selected"
    rebuildMenu()
  }

  @objc private func serveWorkflow() {
    guard let selectedWorkflow else {
      return
    }
    Task { @MainActor in
      do {
        let state = try await controller.start(WorkflowServeStartRequest(
          selection: selectedWorkflow,
          workingDirectory: selectedWorkingDirectory
        ))
        apply(state)
      } catch {
        status = "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func stopWorkflow() {
    Task { @MainActor in
      do {
        apply(try await controller.stop())
      } catch {
        status = "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func restartWorkflow() {
    Task { @MainActor in
      do {
        apply(try await controller.restart())
      } catch {
        status = "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func updateWorkflow() {
    Task { @MainActor in
      do {
        apply(try await controller.reload(WorkflowServeReloadRequest()))
      } catch {
        let current = await controller.currentState()
        status = current.status == .running ? "Update failed, still running" : "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  private func apply(_ state: WorkflowServeState) {
    switch state.status {
    case .running:
      status = "Running"
    case .stopped:
      status = "Stopped"
    case .starting:
      status = "Starting"
    case .reloading:
      status = "Updating"
    case .stopping:
      status = "Stopping"
    case .failed:
      status = state.diagnostics.first?.message ?? "Failed"
    }
    rebuildMenu()
  }
}
#else
@main
struct RielaMenuBarAppUnsupported {
  static func main() {
    print("RielaMenuBarApp is available on macOS only.")
  }
}
#endif
