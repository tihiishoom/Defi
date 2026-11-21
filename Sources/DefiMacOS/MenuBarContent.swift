import SwiftUI

public struct MenuBarContent: View {
  let state: MenuBarState
  let commandHandler: (String) -> Void

  public init(state: MenuBarState, commandHandler: @escaping (String) -> Void) {
    self.state = state
    self.commandHandler = commandHandler
  }

  public var body: some View {
    Group {
      if !state.workspaces.isEmpty {
        Menu("Workspaces", systemImage: "rectangle.3.group") {
          ForEach(state.workspaces, id: \.id) { workspace in
            Toggle(
              workspace.label,
              isOn: Binding(
                get: { workspace.id == state.activeWorkspace },
                set: { _ in commandHandler("workspace \(workspace.id)") }
              )
            )
          }
        }
        Divider()
      }
      if state.needsAccessibilityPermission {
        Button("Grant Accessibility Permission…", systemImage: "accessibility") {
          openDefiAccessibilitySettings()
        }
      }
      Menu("Windows", systemImage: "macwindow.on.rectangle") {
        Button("Recent Windows…") { commandHandler("toggle-recent-windows") }
        Button("Join Left Column as Tabs") { commandHandler("join-window-as-tabs left") }
        Button("Join Right Column as Tabs") { commandHandler("join-window-as-tabs right") }
        Button("Toggle Column Tabs") { commandHandler("toggle-column-tabbed-display") }
        Button("Cycle Window Height") { commandHandler("cycle-window-height next") }
        Button("Reset Stack Heights") { commandHandler("reset-window-height") }
      }
      Button("Save Layout", systemImage: "square.and.arrow.down") {
        commandHandler("save-layout")
      }
      Button("Restore Saved Layout", systemImage: "arrow.uturn.backward") {
        commandHandler("restore-layout")
      }
      .disabled(!state.hasSavedLayout)
      Button("Close Windows Outside Saved Layout…", systemImage: "xmark.rectangle") {
        commandHandler("close-extra-windows")
      }
      .disabled(!state.hasSavedLayout)
      Divider()
      if let version = AppUpdater.shared.availableVersion {
        Button("Update to Defi \(version)", systemImage: "arrow.down.circle") {
          AppUpdater.shared.install()
        }
        .disabled(AppUpdater.shared.status == .installing)
      } else if AppUpdater.shared.isEligible {
        Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
          Task { await AppUpdater.shared.check() }
        }
        .disabled(AppUpdater.shared.status == .checking)
      }
      SettingsLink {
        Text("Settings…")
      }
      .keyboardShortcut(",", modifiers: .command)
      Divider()
      Button("Quit Defi", systemImage: "power") {
        commandHandler("quit")
      }
      .keyboardShortcut("q")
    }
    .onAppear {
      state.refreshAccessibilityPermission()
    }
  }

}
