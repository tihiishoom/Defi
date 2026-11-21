import AppKit
import Synchronization

/// Only a drag pasteboard written during this physical gesture qualifies. A
/// stale file from an earlier drag cannot turn text selection into edge scrolling.
struct FileDragGesture {
  private var baseline: Int?
  private(set) var active = false

  mutating func press(changeCount: Int) { baseline = changeCount; active = false }
  mutating func drag(changeCount: Int, hasFiles: Bool) {
    guard let baseline else { return }
    active = hasFiles && changeCount != baseline
  }
  mutating func release() { baseline = nil; active = false }
}

final class FileDragTracker: Sendable {
  private let active = Mutex(false)
  @MainActor private var gesture = FileDragGesture()

  var isActive: Bool { active.withLock { $0 } }

  @MainActor func observe(_ type: NSEvent.EventType) {
    let pasteboard = NSPasteboard(name: .drag)
    switch type {
    case .leftMouseDown:
      gesture.press(changeCount: pasteboard.changeCount)
    case .leftMouseDragged:
      gesture.drag(changeCount: pasteboard.changeCount, hasFiles:
        pasteboard.availableType(from: [.fileURL, .init("NSFilenamesPboardType"),
          .init("com.apple.pasteboard.promised-file-url")]) != nil)
    case .leftMouseUp:
      gesture.release()
    default: return
    }
    active.withLock { $0 = gesture.active }
  }

  @MainActor func reset() { gesture.release(); active.withLock { $0 = false } }
}
