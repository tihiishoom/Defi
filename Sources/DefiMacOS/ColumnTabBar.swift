import AppKit
import DefiModel

public struct ColumnTab: Sendable, Equatable {
  public let windowID: WindowID
  public let appID: String
  public let title: String
  public init(windowID: WindowID, appID: String, title: String) {
    self.windowID = windowID; self.appID = appID; self.title = title
  }
}

public struct ColumnTabBar: Sendable, Equatable {
  public let monitorID: MonitorID
  public let workspaceID: WorkspaceID
  public let selectedWindowID: WindowID
  public let frame: Rect
  public let tabs: [ColumnTab]
  public init(monitorID: MonitorID, workspaceID: WorkspaceID, selectedWindowID: WindowID,
    frame: Rect, tabs: [ColumnTab]) {
    self.monitorID = monitorID; self.workspaceID = workspaceID
    self.selectedWindowID = selectedWindowID; self.frame = frame; self.tabs = tabs
  }
}

/// Nonactivating surfaces leave keyboard focus with the selected application.
@MainActor
public final class ColumnTabBarManager {
  private var panels: [WindowID: NSPanel] = [:]
  private var models: [WindowID: ColumnTabBar] = [:]
  public init() {}

  public func update(_ bars: [ColumnTabBar], select: @escaping (ColumnTabBar, ColumnTab) -> Void) {
    let current = Set(bars.map(\.selectedWindowID))
    for id in Array(panels.keys) where !current.contains(id) {
      panels.removeValue(forKey: id)?.close()
      models.removeValue(forKey: id)
    }
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    for bar in bars {
      let panel: NSPanel
      if let existing = panels[bar.selectedWindowID] { panel = existing }
      else {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
          backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.ignoresCycle]
        panel.level = .normal
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = false
        panel.animationBehavior = .none
        panels[bar.selectedWindowID] = panel
      }
      let rect = NSRect(x: bar.frame.x, y: top - bar.frame.y - bar.frame.height,
        width: bar.frame.width, height: bar.frame.height)
      let changed = models[bar.selectedWindowID] != bar
      if changed {
        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        let width = rect.width / CGFloat(max(bar.tabs.count, 1))
        for (index, tab) in bar.tabs.enumerated() {
          let button = ColumnTabButton(title: tab.title.isEmpty ? tab.appID : tab.title,
            action: { select(bar, tab) })
          button.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: rect.height)
          button.bezelStyle = .inline
          button.font = .systemFont(ofSize: 12,
            weight: tab.windowID == bar.selectedWindowID ? .semibold : .regular)
          button.contentTintColor = tab.windowID == bar.selectedWindowID ? .controlAccentColor : .secondaryLabelColor
          button.toolTip = tab.title.isEmpty ? tab.appID : tab.title
          button.lineBreakMode = .byTruncatingTail
          view.addSubview(button)
        }
        panel.contentView = view
        models[bar.selectedWindowID] = bar
      }
      if panel.frame != rect { panel.setFrame(rect, display: true) }
      if changed || !panel.isVisible {
        panel.order(.above, relativeTo: Int(bar.selectedWindowID.rawValue))
      }
    }
  }
}

@MainActor
private final class ColumnTabButton: NSButton {
  private let onClick: () -> Void
  init(title: String, action: @escaping () -> Void) {
    onClick = action
    super.init(frame: .zero)
    self.title = title
    target = self
    self.action = #selector(choose)
  }
  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  @objc private func choose() { onClick() }
}
