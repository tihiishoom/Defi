import AppKit
import Observation
import SwiftUI

/// Native controls receive status-bar clicks and scroll input. The final button
/// opens the same menu as the single-workspace status item.
@MainActor
public final class WorkspaceMenuStrip {
  private let state: MenuBarState
  private let commandHandler: (String) -> Void
  private var item: NSStatusItem?
  private var view: StripView?
  private var menu: NSHostingMenu<MenuBarContent>?

  public init(state: MenuBarState, commandHandler: @escaping (String) -> Void) {
    self.state = state
    self.commandHandler = commandHandler
    observe()
  }

  private func observe() {
    withObservationTracking {
      update()
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
  }

  private func update() {
    guard state.isInserted, state.workspaceStyle == .strip else {
      if let item { NSStatusBar.system.removeStatusItem(item) }
      item = nil
      view = nil
      menu = nil
      return
    }
    let strip: StripView
    if let view {
      strip = view
    } else {
      let item = NSStatusBar.system.statusItem(withLength: 34)
      guard let button = item.button else {
        NSStatusBar.system.removeStatusItem(item)
        return
      }
      strip = StripView()
      strip.autoresizingMask = [.width, .height]
      strip.frame = button.bounds
      strip.onScroll = commandHandler
      button.addSubview(strip)
      self.item = item
      view = strip
      menu = NSHostingMenu(rootView: MenuBarContent(state: state, commandHandler: commandHandler))
    }
    let visible = state.workspaces.filter { $0.isOccupied || $0.id == state.activeWorkspace }
    let active = visible.firstIndex { $0.id == state.activeWorkspace } ?? 0
    let start = min(max(active - 2, 0), max(visible.count - 5, 0))
    var x: CGFloat = 3
    let height = NSStatusBar.system.thickness
    strip.subviews.forEach { $0.removeFromSuperview() }
    for workspace in visible.dropFirst(start).prefix(5) {
      let selected = workspace.id == state.activeWorkspace
      let button = StripButton(title: workspace.label) { [commandHandler] in
        commandHandler("workspace \(workspace.id)")
      }
      button.font = .monospacedDigitSystemFont(ofSize: 12, weight: selected ? .bold : .medium)
      button.toolTip = workspace.label
      button.setAccessibilityLabel(selected ? "Workspace \(workspace.label), current" : "Workspace \(workspace.label)")
      let width = min(max(button.intrinsicContentSize.width, 24), 82)
      button.frame = NSRect(x: x, y: 1, width: width, height: height - 2)
      if selected {
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        button.layer?.cornerRadius = 5
      }
      strip.addSubview(button)
      x += width + 2
    }
    let more = StripButton(title: "⋯") { [weak self, weak strip] in
      guard let self, let strip else { return }
      state.refreshAccessibilityPermission()
      menu?.popUp(positioning: nil, at: NSPoint(x: strip.bounds.maxX - 22, y: 0), in: strip)
    }
    more.setAccessibilityLabel("Defi menu")
    more.toolTip = "Defi menu"
    more.frame = NSRect(x: x, y: 1, width: 22, height: height - 2)
    strip.addSubview(more)
    item?.length = x + 25
  }
}

private final class StripButton: NSButton {
  private let perform: () -> Void

  init(title: String, perform: @escaping () -> Void) {
    self.perform = perform
    super.init(frame: .zero)
    self.title = title
    target = self
    action = #selector(pressed)
    bezelStyle = .inline
    isBordered = false
    lineBreakMode = .byTruncatingTail
  }

  required init?(coder: NSCoder) { nil }
  @objc private func pressed() { perform() }
}

private final class StripView: NSView {
  var onScroll: ((String) -> Void)?
  private var accumulated: CGFloat = 0
  private var didStep = false
  private var lastWheelStep = -Double.infinity

  override func scrollWheel(with event: NSEvent) {
    guard event.momentumPhase.isEmpty else { return }
    if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
      accumulated = 0
      didStep = false
    }
    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      accumulated = 0
      didStep = false
      return
    }
    let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
      ? event.scrollingDeltaY : event.scrollingDeltaX
    guard delta != 0 else { return }
    if !event.phase.isEmpty {
      guard !didStep else { return }
      accumulated += delta
      guard abs(accumulated) >= 12 else { return }
      didStep = true
    } else {
      guard event.timestamp - lastWheelStep >= 0.22 else { return }
      lastWheelStep = event.timestamp
    }
    onScroll?(delta > 0 ? "focus-workspace up" : "focus-workspace down")
  }
}
