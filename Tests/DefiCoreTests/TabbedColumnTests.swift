import DefiCore
import DefiModel
import Foundation
import Testing

struct TabbedColumnTests {
  @Test func `Tabs reserve a strip and each receive the full column height`() {
    let first = WindowID(rawValue: 1), second = WindowID(rawValue: 2)
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    var column = Column(windows: [first, second], focusedWindow: 0, width: .fraction(0.5))
    column.display = .tabbed
    workspace.columns = [column]
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 800)
    let frames = computeLayout(workspace: workspace, viewport: viewport, settings: LayoutSettings())
    #expect(frames.count == 2)
    #expect(frames[0].frame == frames[1].frame)
    #expect(frames[0].frame.height > 700)
    #expect(frames[0].frame.width < 510)
    #expect(frames[0].frame.y >= columnTabBarHeight)
    #expect(workspace.columns[0].inactiveTabWindowIDs == [second])
    try? focusWindow(.previous, in: &workspace)
    #expect(workspace.columns[0].focusedWindow == 1)
    #expect(workspace.columns[0].inactiveTabWindowIDs == [first])
    try? focusWindow(.next, in: &workspace)
    #expect(workspace.columns[0].focusedWindow == 0)
  }

  @Test func `Old column snapshots decode as stacked`() throws {
    let column = Column(window: WindowID(rawValue: 1), width: .fraction(0.5))
    let encoded = try JSONEncoder().encode(column)
    let decoded = try JSONDecoder().decode(Column.self, from: encoded)
    #expect(decoded.display == nil)
    #expect(!decoded.isTabbed)
    #expect(decoded.inactiveTabWindowIDs.isEmpty)
    #expect(try parseCommand("toggle-column-tabbed-display") == .toggleColumnTabbedDisplay)
  }

  @Test func `Joining a tabbed column bypasses vertical stack constraints`() throws {
    let first = WindowID(rawValue: 1), second = WindowID(rawValue: 2)
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    var target = Column(window: first, width: .fraction(0.5))
    target.display = .tabbed
    workspace.columns = [target, Column(window: second, width: .fraction(0.5))]
    workspace.focusedColumn = 1
    var checkedStack = false
    try joinFocusedWindow(.left, in: &workspace, settings: LayoutSettings(), stackFit: { _ in
      checkedStack = true
      return .fits
    })
    #expect(!checkedStack)
    #expect(workspace.columns.count == 1)
    #expect(workspace.columns[0].isTabbed)
    #expect(workspace.columns[0].focusedWindow == 1)
  }
}
