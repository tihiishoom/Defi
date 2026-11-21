import AppKit
import ApplicationServices
import DefiModel
import DefiRuntime

@MainActor
public func confirmClosingLayoutWindows(_ windows: [Window]) -> Bool {
  let alert = NSAlert()
  alert.alertStyle = .warning
  alert.messageText = "Close \(windows.count) windows outside the saved layout?"
  let list = windows.map { window in
    let app =
      window.processID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
      ?? window.appID
    return "\(app): \(window.title.prefix(100))"
  }.joined(separator: "\n")
  alert.informativeText =
    "Only windows managed by Defi are included. Unsaved documents may ask for attention; closing stops at the first window that stays open."
  let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 160))
  let text = NSTextView(frame: scroll.bounds)
  text.string = list
  text.isEditable = false
  text.isVerticallyResizable = true
  text.autoresizingMask = [.width]
  scroll.documentView = text
  scroll.hasVerticalScroller = true
  alert.accessoryView = scroll
  alert.addButton(withTitle: "Close Windows").keyEquivalent = ""
  alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
  NSApplication.shared.activate(ignoringOtherApps: true)
  return alert.runModal() == .alertFirstButtonReturn
}

@MainActor
public func presentSavedLayoutMessage(_ message: String) {
  presentDefiAlert(title: "Defi Saved Layout", message: message)
}

extension MacOSPlatform {
  public func requestClosingLayoutWindow(_ id: WindowID) async -> Bool {
    guard let target = elements[id] else { return false }
    let reference = UncheckedSendable(value: target)
    return await Task.detached(priority: .userInitiated) {
      var pid: pid_t = 0
      guard AXUIElementGetPid(reference.value, &pid) == .success,
        pid != ProcessInfo.processInfo.processIdentifier
      else { return false }
      let app = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(app, 0.25)
      func currentWindows() -> [AXUIElement]? {
        var value: CFTypeRef?
        guard
          AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success
        else { return nil }
        return value as? [AXUIElement]
      }
      guard let windows = currentWindows(),
        let window = windows.first(where: { CFEqual($0, reference.value) })
      else { return false }
      AXUIElementSetMessagingTimeout(window, 0.25)
      var close: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &close)
          == .success,
        let close, CFGetTypeID(close) == AXUIElementGetTypeID()
      else { return false }
      let button = unsafeDowncast(close, to: AXUIElement.self)
      AXUIElementSetMessagingTimeout(button, 0.25)
      guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
        return false
      }
      for _ in 0..<10 {
        try? await Task.sleep(for: .milliseconds(100))
        guard let windows = currentWindows() else {
          var role: CFTypeRef?
          return AXUIElementCopyAttributeValue(reference.value, kAXRoleAttribute as CFString, &role)
            == .invalidUIElement
        }
        if !windows.contains(where: { CFEqual($0, reference.value) }) { return true }
      }
      return false
    }.value
  }
}
