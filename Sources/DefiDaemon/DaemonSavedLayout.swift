import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

@NavigationActor
extension Daemon {
  func handleSavedLayoutCommand(_ command: String) -> CommandResponse? {
    guard ["save-layout", "restore-layout", "close-extra-windows"].contains(command) else {
      return nil
    }
    guard desktopSessionActive, !state.monitors.isEmpty else {
      return .failure("desktop unavailable")
    }
    guard !overviewState.isOpen, commandFrameReadTask == nil,
      !platform.hasPendingMouseResizeGesture, !layoutWindowClosureInFlight
    else { return .failure("finish the current desktop interaction first") }
    if command == "save-layout" {
      var snapshotState = state
      for (id, frame) in floatingWindowFrames where snapshotState.windows[id]?.floating == true {
        snapshotState.windows[id]?.frame = frame
      }
      snapshotState.captureLayoutSnapshot()
      do {
        try topologyStore.saveLayout(snapshotState.savedLayout ?? [])
      } catch { return .failure("could not save layout: \(error)") }
      state = snapshotState
      persistTopology()
      updateMenuBar()
      return .success("saved layout for \(state.savedLayout?.count ?? 0) windows")
    }
    guard state.savedLayout != nil else { return .failure("save a layout first") }
    if command == "close-extra-windows" {
      let windows = state.extraWindowIDsForSavedLayout().compactMap { state.windows[$0] }
      guard !windows.isEmpty else { return .success("no extra managed windows") }
      layoutWindowClosureInFlight = true
      Task { [weak self] in
        guard let self else { return }
        defer { self.layoutWindowClosureInFlight = false }
        guard await confirmClosingLayoutWindows(windows) else { return }
        for window in windows {
          guard !self.shouldShutdown, !self.restorationInFlight, self.desktopSessionActive else {
            return
          }
          guard !self.state.windows.values.contains(where: { $0.isModal }) else {
            await presentSavedLayoutMessage("Finish the open dialog before closing more windows.")
            return
          }
          let extra = self.state.extraWindowIDsForSavedLayout()
          guard extra.contains(window.id), self.state.windows[window.id]?.appID == window.appID
          else { continue }
          guard await self.platform.requestClosingLayoutWindow(window.id) else {
            await presentSavedLayoutMessage(
              "Closing stopped at \(window.title). Save or cancel any pending document dialog, then try again. No further windows were closed."
            )
            return
          }
        }
        self.needsDesktopSync = true
        self.scheduleTick()
      }
      return .success("review the window list in Defi before closing")
    }
    cancelPendingCommandFrameRead()
    scrollAnimations.removeAll(keepingCapacity: true)
    focus.queueCommand(nil)
    focus.queueWorkspace(nil)
    invalidateSubmittedCommandFocus()
    invalidateSubmittedWorkspaceFocus()
    platform.cancelPendingFrameWrites()
    let count = state.restoreLayoutSnapshot(config: config)
    synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
    snapScrollOffsetsToTargets()
    for (id, window) in state.windows where window.floating {
      floatingWindowFrames[id] = window.frame
    }
    applyCurrentLayout(
      asynchronousPositions: true, updateVisibility: true,
      forceFloatingFrameWrites: true, source: "restore-layout")
    persistTopology()
    updateMenuBar()
    return .success("restored \(count) open windows")
  }
}
