import DefiModel

extension RuntimeState {
  /// Records confirmed focus only. Browsing the switcher never changes its order.
  public mutating func recordRecentWindow(_ id: WindowID) {
    recentWindowIDs.removeAll { $0 == id || windows[$0] == nil }
    guard windows[id] != nil, location(containing: id) != nil else { return }
    recentWindowIDs.insert(id, at: 0)
  }

  public func recentWindows(selected: WindowID?) -> [WindowID] {
    let managed = monitors.flatMap { monitor in
      monitor.workspaces.flatMap { workspace in
        workspace.columns.flatMap(\.windows) + workspace.floatingWindows
      }
    }.filter { windows[$0] != nil }
    let available = Set(managed)
    var seen = Set<WindowID>()
    return ([selected].compactMap { $0 } + recentWindowIDs + managed).filter {
      available.contains($0) && seen.insert($0).inserted
    }
  }
}
