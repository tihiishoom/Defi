import DefiCore
import DefiModel

/// A continuous edge dwell belongs to one side of one workspace. Time spent on
/// another display or away from the edge never carries into a later dwell.
public struct DragEdgeScrollState: Sendable {
  private var monitorID: MonitorID?
  private var workspaceID: WorkspaceID?
  private var side = 0.0
  private var enteredAt = 0.0
  private var lastSampleAt = 0.0

  public init() {}

  public mutating func reset() { self = Self() }

  public mutating func delta(
    monitorID: MonitorID, workspaceID: WorkspaceID, pointerX: Double,
    pointerY: Double, frame: Rect, now: Double, zone: Double,
    delay: Double, maximumSpeed: Double
  ) -> Double {
    guard now.isFinite, pointerX.isFinite, pointerY.isFinite,
      frame.width > 0, frame.height > 0, zone.isFinite, zone > 0,
      maximumSpeed.isFinite, maximumSpeed > 0, delay.isFinite,
      pointerX >= frame.x, pointerX <= frame.x + frame.width,
      pointerY >= frame.y, pointerY <= frame.y + frame.height
    else { reset(); return 0 }
    let zone = min(zone, frame.width / 2)
    let left = pointerX - frame.x
    let right = frame.x + frame.width - pointerX
    let nextSide: Double = left < zone ? -1 : (right < zone ? 1 : 0)
    guard nextSide != 0 else { reset(); return 0 }
    if self.monitorID != monitorID || self.workspaceID != workspaceID || side != nextSide
      || now < lastSampleAt
    {
      self.monitorID = monitorID
      self.workspaceID = workspaceID
      side = nextSide
      enteredAt = now
      lastSampleAt = now
      return 0
    }
    defer { lastSampleAt = now }
    let elapsed = min(max(now - max(lastSampleAt, enteredAt + max(delay, 0)), 0), 0.05)
    let penetration = 1 - min(left, right) / zone
    return side * maximumSpeed * penetration * elapsed
  }
}

/// Scrolls the active ribbon only, in screen points, without changing focus or
/// writing native frames. Widths include constraints and gaps just as layout does.
@discardableResult
public func scrollWorkspaceForDrag(
  monitorID: MonitorID, delta: Double, viewport: Rect, state: inout RuntimeState
) -> WorkspaceScrollAnchor? {
  guard delta.isFinite, delta != 0,
    let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }),
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(where: {
      $0.id == state.monitors[monitorIndex].activeWorkspace
    })
  else { return nil }
  let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  let columns = workspace.columns.compactMap { column -> Column? in
    var column = column
    column.windows.removeAll { state.nativeFullscreenWindowIDs.contains($0) }
    return column.windows.isEmpty ? nil : column
  }
  let width = stripViewport(viewport, settings: state.layout).width
  guard width > 0 else { return nil }
  let total = columnLayoutWidths(columns, viewport: viewport,
    windowsByID: state.windows, settings: state.layout).reduce(0, +)
  guard total > width else { return nil }
  let offset = min(max(workspace.scrollOffset + delta / width, 0), max(total / width - 1, 0))
  guard abs(offset - workspace.scrollOffset) > 0.000_001 else { return nil }
  let anchor = WorkspaceScrollAnchor(monitorID: monitorID, workspaceID: workspace.id, scrollOffset: offset)
  restoreWorkspaceScroll(anchor, state: &state)
  return anchor
}
