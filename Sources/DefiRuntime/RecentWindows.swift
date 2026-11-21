import DefiModel

extension RuntimeState {
  /// Records confirmed focus only. Browsing the switcher never changes its order.
  public mutating func recordRecentWindow(_ id: WindowID) {
    let owner = transientRootWindowID(id, windows: windows)
    recentWindowIDs.removeAll { $0 == owner || windows[$0]?.isTransient != false }
    guard windows[owner]?.isTransient == false, location(containing: owner) != nil else { return }
    recentWindowIDs.insert(owner, at: 0)
  }

  public func recentWindows(selected: WindowID?) -> [WindowID] {
    let managed = monitors.flatMap { monitor in
      monitor.workspaces.flatMap { workspace in
        workspace.columns.flatMap(\.windows) + workspace.floatingWindows
      }
    }.filter { windows[$0]?.isTransient == false }
    let available = Set(managed)
    var seen = Set<WindowID>()
    let selectedOwner = selected.map { transientRootWindowID($0, windows: windows) }
    return ([selectedOwner].compactMap { $0 } + recentWindowIDs + managed).filter {
      available.contains($0) && seen.insert($0).inserted
    }
  }
}
