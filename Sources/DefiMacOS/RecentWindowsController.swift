import AppKit
import DefiModel
import QuartzCore

public struct RecentWindowEntry: Sendable {
  public let window: Window
  public let workspace: String

  public init(window: Window, workspace: String) {
    self.window = window
    self.workspace = workspace
  }
}

/// A keyboard-owned picker; previews are read from the existing bounded cache.
@MainActor
public final class RecentWindowsController {
  private var entries: [RecentWindowEntry] = []
  private var selected = 0
  private var panel: RecentWindowsPanel?
  private var heldModifiers: NSEvent.ModifierFlags = []
  private var previews = false
  private let inputMode: (HotKeyManager.RecentWindowsKeyHandler?) -> Void
  private let choose: (RecentWindowEntry) -> Void
  public var isOpen: Bool { panel?.isVisible == true }

  public init(inputMode: @escaping (HotKeyManager.RecentWindowsKeyHandler?) -> Void,
    choose: @escaping (RecentWindowEntry) -> Void) {
    self.inputMode = inputMode
    self.choose = choose
  }

  public func open(entries: [RecentWindowEntry], previews: Bool) {
    guard !entries.isEmpty else { return }
    self.entries = entries
    self.previews = previews
    selected = entries.count > 1 ? 1 : 0
    heldModifiers = NSEvent.modifierFlags.intersection([.command, .option, .control])
    let panel = RecentWindowsPanel(contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .popUpMenu
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.onKey = { [weak self] event in self?.key(event) }
    panel.onFlags = { [weak self] event in
      guard let self, !heldModifiers.isEmpty,
        event.modifierFlags.intersection(heldModifiers).isEmpty else { return }
      commit()
    }
    panel.onResign = { [weak self] in self?.close() }
    self.panel = panel
    inputMode { [weak self] code, flags in
      DispatchQueue.main.async { [weak self] in
        if flags & CGEventFlags.maskCommand.rawValue != 0 && code == 48 { self?.close() }
        else { self?.key(code: code, shift: flags & CGEventFlags.maskShift.rawValue != 0) }
      }
    }
    render()
    panel.makeKeyAndOrderFront(nil)
  }

  public func advance(backward: Bool) {
    guard !entries.isEmpty else { return }
    selected = (selected + (backward ? entries.count - 1 : 1)) % entries.count
    render()
  }

  public func close() {
    inputMode(nil)
    panel?.onResign = nil
    panel?.orderOut(nil)
    panel = nil
    entries = []
  }

  private func commit() {
    guard entries.indices.contains(selected) else { close(); return }
    let entry = entries[selected]
    close()
    choose(entry)
  }

  private func key(_ event: NSEvent) {
    key(code: event.keyCode, shift: event.modifierFlags.contains(.shift))
  }

  private func key(code: UInt16, shift: Bool) {
    switch code {
    case 53: close()
    case 36, 76: commit()
    case 48: advance(backward: shift)
    case 123, 126: advance(backward: true)
    case 124, 125: advance(backward: false)
    default: break
    }
  }

  private func render() {
    guard let panel, entries.indices.contains(selected) else { return }
    let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
      ?? NSScreen.main
    let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
    let width = min(620, area.width - 40), height = min(480, area.height - 40)
    panel.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2,
      width: width, height: height), display: false)
    let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    root.material = .hudWindow
    root.state = .active
    root.wantsLayer = true
    root.layer?.cornerRadius = 16
    root.layer?.masksToBounds = true
    let entry = entries[selected]
    let image = NSView(frame: NSRect(x: 20, y: 85, width: width - 40, height: height - 145))
    image.wantsLayer = true
    image.layer?.contentsGravity = .resizeAspect
    if previews, CGPreflightScreenCaptureAccess(),
      let picture = WindowCaptureStore.shared.picture(entry.window.id),
      picture.appID == entry.window.appID {
      image.layer?.contents = picture.contents
    } else if let process = entry.window.processID,
      let app = NSRunningApplication(processIdentifier: process), let icon = app.icon {
      image.layer?.contents = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    root.addSubview(image)
    func label(_ value: String, y: CGFloat, size: CGFloat) {
      let field = NSTextField(labelWithString: value)
      field.font = .systemFont(ofSize: size, weight: size > 14 ? .semibold : .regular)
      field.alignment = .center
      field.lineBreakMode = .byTruncatingMiddle
      field.frame = NSRect(x: 20, y: y, width: width - 40, height: 24)
      root.addSubview(field)
    }
    label(entry.window.title.isEmpty ? entry.window.appID : entry.window.title, y: height - 42, size: 17)
    let app = entry.window.processID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
      ?? entry.window.appID
    label("\(app)  ·  \(entry.workspace)  ·  \(selected + 1) / \(entries.count)", y: 49, size: 13)
    label("Tab / Arrows: select    Return: open    Esc: cancel", y: 20, size: 12)
    panel.contentView = root
  }
}

@MainActor
private final class RecentWindowsPanel: NSPanel {
  var onKey: ((NSEvent) -> Void)?
  var onFlags: ((NSEvent) -> Void)?
  var onResign: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override func keyDown(with event: NSEvent) { onKey?(event) }
  override func flagsChanged(with event: NSEvent) { onFlags?(event) }
  override func resignKey() { super.resignKey(); onResign?() }
}
