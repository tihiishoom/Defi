import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct DragEdgeScrollingTests {
  let monitor = MonitorID(rawValue: 1)
  let workspace = WorkspaceID(rawValue: "one")
  let frame = Rect(x: 0, y: 0, width: 1_000, height: 700)

  @Test func dwellSpeedAndDelayedSamplesAreBounded() {
    var edge = DragEdgeScrollState()
    func sample(_ now: Double, _ x: Double = 1_000) -> Double {
      edge.delta(monitorID: monitor, workspaceID: workspace, pointerX: x, pointerY: 100,
        frame: frame, now: now, zone: 32, delay: 0.25, maximumSpeed: 1_000)
    }
    #expect(sample(1) == 0)
    #expect(sample(1.2) == 0)
    #expect(abs(sample(1.27) - 20) < 0.0001)
    #expect(abs(sample(1.29, 984) - 10) < 0.0001)
    // A blocked AX snapshot must not cause a large catch-up jump.
    #expect(abs(sample(3) - 50) < 0.0001)
    #expect(sample(3.1, 900) == 0)
    #expect(sample(3.2) == 0)
    #expect(sample(3.3) == 0)
  }

  @Test func changingSideDisplayWorkspaceOrTimeRestartsDwell() {
    var edge = DragEdgeScrollState()
    func sample(_ now: Double, _ x: Double = 1_000,
      _ monitorID: MonitorID? = nil, _ workspaceID: WorkspaceID? = nil) -> Double {
      edge.delta(monitorID: monitorID ?? monitor, workspaceID: workspaceID ?? workspace,
        pointerX: x, pointerY: 100, frame: frame, now: now, zone: 32,
        delay: 0.25, maximumSpeed: 1_000)
    }
    #expect(sample(1) == 0)
    #expect(sample(2) > 0)
    #expect(sample(2.01, 0) == 0)
    #expect(sample(2.4, 0) < 0)
    #expect(sample(2.5, 0, MonitorID(rawValue: 2)) == 0)
    #expect(sample(2.9, 0, MonitorID(rawValue: 2), WorkspaceID(rawValue: "two")) == 0)
    #expect(sample(2.8, 0, MonitorID(rawValue: 2), WorkspaceID(rawValue: "two")) == 0)
    edge.reset()
    #expect(sample(4) == 0)
  }

  @Test func fittingRibbonNeverMovesFromItsCenteredPosition() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitor)
    let index = try #require(state.monitors[0].workspaces.firstIndex {
      $0.id == state.monitors[0].activeWorkspace
    })
    let id = WindowID(rawValue: 1)
    state.windows[id] = Window(id: id, appID: "fixture", title: "", frame: frame)
    state.monitors[0].workspaces[index].columns = [Column(window: id, width: .fraction(0.5))]
    state.monitors[0].workspaces[index].scrollOffset = -0.25
    let original = state
    #expect(scrollWorkspaceForDrag(monitorID: monitor, delta: 100, viewport: frame, state: &state) == nil)
    #expect(state == original)
  }

  @Test func ribbonScrollClampsAndLeavesOtherMonitorAndFocusUntouched() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitor)
    let otherMonitor = MonitorID(rawValue: 2)
    state.attachMonitor(otherMonitor)
    let ids = (1...4).map { WindowID(rawValue: UInt64($0)) }
    for id in ids {
      state.windows[id] = Window(id: id, appID: "fixture", title: "", frame: frame)
    }
    let workspaceIndex = try #require(state.monitors[0].workspaces.firstIndex {
      $0.id == state.monitors[0].activeWorkspace
    })
    state.monitors[0].workspaces[workspaceIndex].columns = ids.map { Column(window: $0, width: .fraction(0.5)) }
    state.monitors[0].workspaces[workspaceIndex].focusedColumn = 0
    let untouched = state.monitors[1]
    let selected = state.selectedWindowID(on: monitor)
    let anchor = try #require(scrollWorkspaceForDrag(monitorID: monitor, delta: 100_000,
      viewport: frame, state: &state))
    #expect(anchor.scrollOffset > 0)
    #expect(anchor.scrollOffset < 1.5)
    #expect(state.selectedWindowID(on: monitor) == selected)
    #expect(state.monitors[1] == untouched)
    #expect(scrollWorkspaceForDrag(monitorID: monitor, delta: 100_000, viewport: frame, state: &state) == nil)
    let left = try #require(scrollWorkspaceForDrag(monitorID: monitor, delta: -100_000,
      viewport: frame, state: &state))
    #expect(left.scrollOffset == 0)
  }
}
