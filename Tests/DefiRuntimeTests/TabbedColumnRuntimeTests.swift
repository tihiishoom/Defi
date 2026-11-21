import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct TabbedColumnRuntimeTests {
  @Test func `Manual snapshots restore tabbed column membership and display`() throws {
    let config = Config()
    let monitor = MonitorID(rawValue: 1)
    var state = RuntimeState(config: config)
    state.attachMonitor(monitor)
    for rawID in 1...2 {
      let window = Window(id: WindowID(rawValue: UInt64(rawID)), appID: "app\(rawID)",
        title: "Window \(rawID)", frame: Rect(x: 0, y: 0, width: 500, height: 600),
        monitorID: monitor)
      try discoverWindow(window, decision: config.decision(for: window), state: &state)
    }
    try reduce(.focusColumn(.last), on: monitor, state: &state)
    try reduce(.joinWindow(.left), on: monitor, state: &state)
    try reduce(.toggleColumnTabbedDisplay, on: monitor, state: &state)
    state.captureLayoutSnapshot()
    #expect(state.savedLayout?.allSatisfy { $0.columnDisplay == .tabbed } == true)
    try reduce(.unjoinWindows, on: monitor, state: &state)
    #expect(state.monitors[0].workspaces[0].columns.count == 2)
    #expect(state.restoreLayoutSnapshot(config: config) == 2)
    #expect(state.monitors[0].workspaces[0].columns.count == 1)
    #expect(state.monitors[0].workspaces[0].columns[0].isTabbed)
    #expect(state.monitors[0].workspaces[0].columns[0].windows.count == 2)
  }
}
