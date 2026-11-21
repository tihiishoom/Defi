import CoreGraphics
import DefiCore
import DefiModel
import DefiRuntime
import Foundation

@NavigationActor
extension Daemon {
  func restoreDragEdgeScrollIfCurrent() {
    guard let anchor = dragEdgeScrollAnchor else { return }
    guard config.input.dragEdgeScrollEnabled, !overviewState.isOpen,
      commandGeneration == dragEdgeScrollCommandGeneration,
      platform.userInputTracker.latestEventTimestamp <= dragEdgeScrollInputTimestamp,
      let monitor = state.monitors.first(where: { $0.id == anchor.monitorID }),
      monitor.activeWorkspace == anchor.workspaceID,
      state.selectedWindowID(on: anchor.monitorID) == dragEdgeScrollSelection
    else {
      dragEdgeScrollAnchor = nil
      return
    }
    restoreWorkspaceScroll(anchor, state: &state)
  }

  func updateDragEdgeScroll(now: TimeInterval) {
    restoreDragEdgeScrollIfCurrent()
    let held = platform.isLeftMouseButtonDown
    let movedWindow = held && mouseGestureChangedWindowFrame
      && !platform.windowProxyStretching
      && activelyResizedWindowID.flatMap { id in
        mouseGestureInitialFrame.flatMap { initial in
          state.windows[id].map { window in
            let current = window.frame
            return mouseFrameWasTranslated(from: initial, to: current)
              && !mouseFrameWasResized(from: initial, to: current)
          }
        }
      } == true
    guard config.input.dragEdgeScrollEnabled, held, !overviewState.isOpen,
      !displayReconciliationInFlight, !mouseGesturePreempted,
      movedWindow || platform.isFileDragActive,
      let pointer = CGEvent(source: nil)?.location,
      let display = latestMonitors.first(where: {
        Double(pointer.x) >= $0.physicalFrame.x && Double(pointer.x) <= $0.physicalFrame.x + $0.physicalFrame.width
          && Double(pointer.y) >= $0.physicalFrame.y && Double(pointer.y) <= $0.physicalFrame.y + $0.physicalFrame.height
      }),
      let monitor = state.monitors.first(where: { $0.id == display.id }),
      let viewport = viewportsByMonitor[display.id]
    else { dragEdgeScroll.reset(); return }
    let delta = dragEdgeScroll.delta(monitorID: display.id, workspaceID: monitor.activeWorkspace,
      pointerX: Double(pointer.x), pointerY: Double(pointer.y), frame: display.physicalFrame,
      now: now, zone: config.input.dragEdgeScrollZone,
      delay: Double(config.input.dragEdgeScrollDelayMS) / 1_000,
      maximumSpeed: config.input.dragEdgeScrollMaxSpeed)
    guard let anchor = scrollWorkspaceForDrag(monitorID: display.id, delta: delta,
      viewport: viewport, state: &state) else { return }
    // Keep desktop reconciliation from revealing the old keyboard focus again.
    // A new command, native selection, workspace or Overview ends this manual view.
    dragEdgeScrollAnchor = anchor
    dragEdgeScrollSelection = state.selectedWindowID(on: display.id)
    dragEdgeScrollCommandGeneration = commandGeneration
    dragEdgeScrollInputTimestamp = now
    if mouseGestureScrollAnchor?.monitorID == display.id {
      mouseGestureScrollAnchor = anchor
    }
    dragEdgeScrollPreviewDirty = true
    needsDesktopSync = true
    // The native dragged window stays under the pointer. Other windows continue
    // through the normal diffed public-AX path, without a focus write or input grab.
    applyCurrentLayout(monitorIDs: [display.id], asynchronousPositions: true,
      updateVisibility: true, skipping: Set([movedWindow ? activelyResizedWindowID : nil].compactMap { $0 }),
      positionsOnly: true, source: "drag-edge-scroll")
  }
}
