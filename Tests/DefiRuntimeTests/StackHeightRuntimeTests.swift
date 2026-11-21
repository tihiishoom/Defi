import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Foundation
import Testing

struct StackHeightRuntimeTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let ids = (1...3).map { WindowID(rawValue: UInt64($0)) }
  private let viewport = Rect(x: 0, y: 0, width: 1000, height: 1000)

  private func initialState() -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.layout = LayoutSettings(
      innerHorizontalGap: 0, innerVerticalGap: 0,
      outerTopGap: 0, outerRightGap: 0, outerBottomGap: 0, outerLeftGap: 0)
    for id in ids {
      state.windows[id] = Window(id: id, appID: "app-\(id.rawValue)", title: "Test", frame: viewport)
    }
    state.monitors[0].workspaces[0].columns = [
      Column(windows: ids, focusedWindow: 0, width: .fraction(0.5))
    ]
    return state
  }

  private func heights(_ state: RuntimeState) -> [Double] {
    computeLayout(workspace: state.monitors[0].workspaces[0], viewport: viewport,
      windows: Array(state.windows.values), settings: state.layout).map(\.frame.height)
  }

  @Test
  func percentagesRescalePeersAndResetBalancesColumn() throws {
    var state = initialState()
    try reduce(try parseCommand("set-window-height 75%"), on: monitorID, state: &state)
    #expect(heights(state) == [750, 125, 125])
    state.monitors[0].workspaces[0].columns[0].focusedWindow = 1
    try reduce(.setWindowHeight(0.5), on: monitorID, state: &state)
    let result = heights(state)
    #expect(abs(result[0] - 1000 * 3 / 7) < 0.001)
    #expect(abs(result[1] - 500) < 0.001)
    #expect(abs(result.reduce(0, +) - 1000) < 0.001)
    try reduce(.resetWindowHeight, on: monitorID, state: &state)
    #expect(state.windows.values.allSatisfy { $0.stackHeightFraction == nil })
    #expect(heights(state).allSatisfy { abs($0 - 1000 / 3) < 0.001 })
  }

  @Test
  func newSiblingReceivesUsableSpaceBesideSavedFractions() throws {
    var state = initialState()
    state.windows[ids[0]]?.stackHeightFraction = 0.75
    state.windows[ids[1]]?.stackHeightFraction = 0.25
    let result = heights(state)
    #expect(abs(result[0] - 500) < 0.001)
    #expect(abs(result[1] - 1000 / 6) < 0.001)
    #expect(abs(result[2] - 1000 / 3) < 0.001)
  }

  @Test
  func preferredHeightsRespectNativeMinimumAndMaximum() throws {
    var state = initialState()
    try reduce(.setWindowHeight(0.75), on: monitorID, state: &state)
    state.windows[ids[1]]?.minimumTiledHeight = 300
    state.windows[ids[0]]?.maximumTiledHeight = 500
    let result = heights(state)
    #expect(result == [500, 300, 200])
    #expect(result.reduce(0, +) == 1000)
  }

  @Test
  func cyclesUsePresetDirectionsAndRejectInvalidInput() throws {
    var state = initialState()
    try reduce(.cycleWindowHeight(.next), on: monitorID, state: &state)
    #expect(state.windows[ids[0]]?.stackHeightFraction == 0.5)
    try reduce(.cycleWindowHeight(.previous), on: monitorID, state: &state)
    #expect(state.windows[ids[0]]?.stackHeightFraction == 0.33)
    for input in ["set-window-height nan", "set-window-height 100%", "set-window-height -1", "cycle-window-height left"] {
      #expect(throws: (any Error).self) { try parseCommand(input) }
    }
  }

  @Test
  func nativeSnapshotsDoNotEraseUserHeightPreferences() throws {
    var state = initialState()
    try reduce(.setWindowHeight(0.75), on: monitorID, state: &state)
    let observed = ids.map { Window(id: $0, appID: "app-\($0.rawValue)", title: "Observed", frame: viewport) }
    reconcileWindows(observed, config: Config(), state: &state)
    #expect(heights(state) == [750, 125, 125])
    try discoverWindow(observed[0], decision: Config().decision(for: observed[0]), state: &state)
    #expect(state.windows[ids[0]]?.stackHeightFraction == 0.75)
    let replacementID = WindowID(rawValue: 4)
    var replaced = Array(observed.dropFirst())
    replaced.append(Window(id: replacementID, appID: observed[0].appID, title: "Rebound", frame: viewport))
    reconcileWindows(replaced, config: Config(), windowIDReplacements: [ids[0]: replacementID], state: &state)
    #expect(state.windows[replacementID]?.stackHeightFraction == 0.75)
  }

  @Test
  func snapshotsAndTopologyRetainFractionsAndLegacyWindowsDecode() throws {
    var state = initialState()
    try reduce(.setWindowHeight(0.75), on: monitorID, state: &state)
    state.captureLayoutSnapshot()
    let saved = try JSONEncoder().encode(state.savedLayout!)
    state.savedLayout = try JSONDecoder().decode([ApplicationPlacement].self, from: saved)
    try reduce(.resetWindowHeight, on: monitorID, state: &state)
    #expect(state.restoreLayoutSnapshot(config: Config()) == 3)
    #expect(heights(state) == [750, 125, 125])
    let topology = try JSONDecoder().decode(WorkspaceTopology.self,
      from: JSONEncoder().encode(state.topology))
    #expect(RuntimeState(config: Config(), topology: topology).windows[ids[0]]?.stackHeightFraction == 0.75)
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.windows[ids[0]]!)) as! [String: Any]
    legacy.removeValue(forKey: "stackHeightFraction")
    let decoded = try JSONDecoder().decode(Window.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.stackHeightFraction == nil)
  }
}
