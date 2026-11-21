import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

@NavigationActor
extension Daemon {
  func toggleRecentWindows() -> CommandResponse {
    guard desktopSessionActive, !overviewState.isOpen else {
      return .failure("recent windows unavailable during Overview or an inactive session")
    }
    let selected = activeMonitorID.flatMap { state.selectedWindowID(on: $0) }
    let entries = state.recentWindows(selected: selected).compactMap { id -> RecentWindowEntry? in
      guard let window = state.windows[id], let location = state.location(containing: id) else { return nil }
      guard let monitor = state.monitors.first(where: { $0.id == location.monitorID }),
        let index = monitor.workspaces.firstIndex(where: { $0.id == location.workspaceID }) else { return nil }
      let workspace = monitor.workspaces[index].name ?? "Workspace \(index + 1)"
      return RecentWindowEntry(window: window, workspace: workspace)
    }
    guard !entries.isEmpty else { return .success() }
    let previews = config.overview.windowPreviews
    let generation = recentWindowsGeneration.withLock { value in value &+= 1; return value }
    DispatchQueue.main.async { [weak self] in
      guard let self, recentWindowsGeneration.withLock({ $0 == generation }) else { return }
      if let controller = recentWindowsController, controller.isOpen {
        controller.advance(backward: false)
        return
      }
      let controller = RecentWindowsController(inputMode: recentWindowsInputMode) { [weak self] entry in
        NavigationActor.enqueue { [weak self] in
          guard let self, desktopSessionActive, !overviewState.isOpen, let location = state.location(containing: entry.window.id),
            state.windows[entry.window.id]?.appID == entry.window.appID else { return }
          focusFromOverview(windowID: entry.window.id, appID: entry.window.appID,
            monitorID: location.monitorID, workspaceID: location.workspaceID,
            overviewGeneration: nil, offsets: [:], requiresOverviewSession: false)
        }
      }
      recentWindowsController = controller
      controller.open(entries: entries, previews: previews)
    }
    return .success()
  }
  func closeRecentWindows() {
    recentWindowsGeneration.withLock { $0 &+= 1 }
    DispatchQueue.main.async { [weak self] in self?.recentWindowsController?.close() }
  }

}
