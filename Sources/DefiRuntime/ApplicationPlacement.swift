import DefiConfig
import DefiCore
import DefiModel
import Foundation

public struct ApplicationPlacement: Codable, Equatable, Sendable {
  public var id: String
  public var appID: String
  public var monitorID: MonitorID
  public var monitorStableID: String?
  public var workspaceID: WorkspaceID
  public var workspaceKind: WorkspaceKind
  public var workspacePosition: Int
  public var columnIndex: Int
  public var width: ColumnWidth?
  public var floatingFrame: Rect?
  public var stackIndex: Int?
  public var stackHeightFraction: Double?
}

extension RuntimeState {
  var placementReference: [ApplicationPlacement] { savedLayout ?? [] }

  public mutating func captureLayoutSnapshot() {
    applicationPlacements = []
    placementBindings = [:]
    rememberApplicationPlacements()
    savedLayout = applicationPlacements
    for monitor in monitors {
      for workspace in monitor.workspaces {
        for (columnIndex, column) in workspace.columns.enumerated() {
          for (stackIndex, id) in column.windows.enumerated() {
            if let binding = placementBindings[id],
              let index = savedLayout?.firstIndex(where: { $0.id == binding })
            {
              savedLayout?[index].columnIndex = columnIndex
              savedLayout?[index].stackIndex = stackIndex
            }
          }
        }
      }
    }
  }

  private var snapshotEligibleWindowIDs: [WindowID] {
    monitors.flatMap { monitor in
      monitor.workspaces.flatMap { $0.columns.flatMap(\.windows) + $0.floatingWindows }
    }.filter { id in
      guard let window = windows[id] else { return false }
      return !window.isModal && window.transientOwnerID == nil
        && window.floatingOrigin != .automatic && !nativeFullscreenWindowIDs.contains(id)
    }
  }

  private func layoutSnapshotMatches() -> [WindowID: ApplicationPlacement] {
    guard let savedLayout else { return [:] }
    // Live bindings take priority so an extra sibling cannot displace a saved window.
    var matches: [WindowID: ApplicationPlacement] = [:]
    var consumed = Set<String>()
    for id in snapshotEligibleWindowIDs {
      guard let window = windows[id], let binding = placementBindings[id],
        let placement = savedLayout.first(where: {
          $0.id == binding && $0.appID == window.appID.lowercased()
        }),
        consumed.insert(placement.id).inserted
      else { continue }
      matches[id] = placement
    }
    for id in snapshotEligibleWindowIDs where matches[id] == nil {
      guard let window = windows[id],
        let placement = savedLayout.first(where: {
          !consumed.contains($0.id) && $0.appID == window.appID.lowercased()
            && ($0.floatingFrame != nil) == window.floating
        })
      else { continue }
      consumed.insert(placement.id)
      matches[id] = placement
    }
    return matches
  }

  public func extraWindowIDsForSavedLayout() -> [WindowID] {
    guard savedLayout != nil else { return [] }
    let matches = layoutSnapshotMatches()
    return snapshotEligibleWindowIDs.filter { matches[$0] == nil }
  }

  @discardableResult
  public mutating func restoreLayoutSnapshot(config: Config) -> Int {
    guard let savedLayout else { return 0 }
    let selected = Dictionary(
      uniqueKeysWithValues: monitors.compactMap { monitor in
        selectedWindowID(on: monitor.id).map { (monitor.id, $0) }
      })
    let matches = layoutSnapshotMatches()
    var restored = 0
    for id in snapshotEligibleWindowIDs {
      guard var window = windows[id], !window.isModal, window.transientOwnerID == nil,
        window.floatingOrigin != .automatic, !nativeFullscreenWindowIDs.contains(id)
      else { continue }
      guard let placement = matches[id] else { continue }
      let decision = config.decision(for: window)
      guard let workspaceID = decision.workspace ?? restorePlacementWorkspace(placement),
        let target = workspaceLocation(for: workspaceID)
      else { continue }
      removeWindowFromEveryWorkspace(id, state: &self)
      placementBindings[id] = placement.id
      window.floating =
        decision.forceTiling ? false : (decision.floating || placement.floatingFrame != nil)
      if window.floating {
        if let frame = placement.floatingFrame { window.frame = frame }
        monitors[target.monitorIndex].workspaces[target.workspaceIndex].floatingWindows.append(id)
      } else {
        let columns = monitors[target.monitorIndex].workspaces[target.workspaceIndex].columns
        let index =
          columns.firstIndex { column in
            column.windows.contains { other in
              placementBindings[other].flatMap { binding in
                savedLayout.first { $0.id == binding }
              }.map { $0.columnIndex > placement.columnIndex } ?? false
            }
          } ?? min(max(0, placement.columnIndex), columns.count)
        insertPlacedWindow(
          id,
          width: placement.width ?? .fraction(layout.defaultColumnWidth),
          placement: placement, reference: savedLayout, bindings: placementBindings,
          into: &monitors[target.monitorIndex].workspaces[target.workspaceIndex],
          settings: layout, focusInsertedWindow: false, insertionIndex: index)
      }
      window.stackHeightFraction = placement.stackHeightFraction
      window.monitorID = monitors[target.monitorIndex].id
      if window.floatingOrigin == .user && !window.floating { window.floatingOrigin = nil }
      windows[id] = window
      suspendedTiledPlacements[id] = nil
      restored += 1
    }
    for monitorIndex in monitors.indices {
      for workspaceIndex in monitors[monitorIndex].workspaces.indices {
        let columns = monitors[monitorIndex].workspaces[workspaceIndex].columns
        monitors[monitorIndex].workspaces[workspaceIndex].columns = columns.enumerated().sorted {
          lhs, rhs in
          func rank(_ column: Column) -> Int {
            column.windows.compactMap { placementBindings[$0] }.compactMap { binding in
              savedLayout.first { $0.id == binding }?.columnIndex
            }.min() ?? Int.max
          }
          let left = rank(lhs.element)
          let right = rank(rhs.element)
          return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
      }
    }
    for monitorIndex in monitors.indices {
      guard let id = selected[monitors[monitorIndex].id], let location = location(containing: id),
        location.monitorID == monitors[monitorIndex].id,
        let target = workspaceLocation(for: location.workspaceID)
      else { continue }
      monitors[monitorIndex].activeWorkspace = location.workspaceID
      if let column = monitors[monitorIndex].workspaces[target.workspaceIndex].columns.firstIndex(
        where: { $0.windows.contains(id) })
      {
        monitors[monitorIndex].workspaces[target.workspaceIndex].focusedColumn = column
        monitors[monitorIndex].workspaces[target.workspaceIndex].columns[column].focusedWindow =
          monitors[monitorIndex].workspaces[target.workspaceIndex].columns[column].windows
          .firstIndex(of: id) ?? 0
        monitors[monitorIndex].workspaces[target.workspaceIndex].focusedLayer = .tiled
      } else if let index = monitors[monitorIndex].workspaces[target.workspaceIndex].floatingWindows
        .firstIndex(of: id)
      {
        monitors[monitorIndex].workspaces[target.workspaceIndex].focusedFloatingWindow = index
        monitors[monitorIndex].workspaces[target.workspaceIndex].focusedLayer = .floating
      }
    }
    maintainWorkspaceLifecycle()
    rememberApplicationPlacements()
    return restored
  }

  public mutating func loadApplicationPlacements(_ placements: [ApplicationPlacement]) {
    let groupExisting = placements.isEmpty && placementBindings.isEmpty
    applicationPlacements = placements
    let ids = Set(placements.map(\.id))
    placementBindings = placementBindings.filter { ids.contains($0.value) }
    if groupExisting { groupExistingApplicationColumns() }
    for placement in placements
    where placement.workspaceID.rawValue.hasPrefix(WorkspaceID.dynamicPrefix) {
      if let number = UInt64(
        placement.workspaceID.rawValue.dropFirst(WorkspaceID.dynamicPrefix.count)),
        number < UInt64.max
      {
        nextOrdinaryWorkspaceNumber = max(nextOrdinaryWorkspaceNumber, number + 1)
      }
    }
    rememberApplicationPlacements()
  }

  private mutating func groupExistingApplicationColumns() {
    for monitorIndex in monitors.indices {
      for workspaceIndex in monitors[monitorIndex].workspaces.indices {
        var workspace = monitors[monitorIndex].workspaces[workspaceIndex]
        let selected =
          workspace.columns.indices.contains(workspace.focusedColumn)
          ? workspace.columns[workspace.focusedColumn].windows.first : nil
        var groups: [String: [Column]] = [:]
        var order: [String] = []
        for (index, column) in workspace.columns.enumerated() {
          let applications = Set(column.windows.compactMap { windows[$0]?.appID.lowercased() })
          let key =
            applications.count == 1 && applications.first != ""
            ? "app:\(applications.first!)" : "column:\(index)"
          if groups[key] == nil { order.append(key) }
          groups[key, default: []].append(column)
        }
        workspace.columns = order.flatMap { groups[$0] ?? [] }
        if let selected,
          let index = workspace.columns.firstIndex(where: { $0.windows.contains(selected) })
        {
          workspace.focusedColumn = index
        }
        monitors[monitorIndex].workspaces[workspaceIndex] = workspace
      }
    }
  }

  public mutating func rememberApplicationPlacements() {
    placementBindings = placementBindings.filter { windows[$0.key] != nil }
    for monitor in monitors {
      for (workspacePosition, workspace) in monitor.workspaces.enumerated() {
        for (columnIndex, column) in workspace.columns.enumerated() {
          for windowID in column.windows {
            rememberPlacement(
              windowID, monitor: monitor, workspace: workspace,
              workspacePosition: workspacePosition, columnIndex: columnIndex, width: column.width)
          }
        }
        for windowID in workspace.floatingWindows {
          rememberPlacement(
            windowID, monitor: monitor, workspace: workspace,
            workspacePosition: workspacePosition, columnIndex: 0, width: nil)
        }
        // Closed windows keep their slots regardless of startup discovery order.
        let ordered = applicationPlacements.indices.filter {
          applicationPlacements[$0].workspaceID == workspace.id
            && applicationPlacements[$0].width != nil
        }.sorted {
          if applicationPlacements[$0].columnIndex == applicationPlacements[$1].columnIndex {
            return $0 < $1
          }
          return applicationPlacements[$0].columnIndex < applicationPlacements[$1].columnIndex
        }
        let activeIDs = workspace.columns.flatMap(\.windows).compactMap { placementBindings[$0] }
        let activeSet = Set(activeIDs)
        let ranks = ordered.enumerated().filter {
          activeSet.contains(applicationPlacements[$0.element].id)
        }.map(\.offset)
        for (id, rank) in zip(activeIDs, ranks) {
          if let index = applicationPlacements.firstIndex(where: { $0.id == id }) {
            applicationPlacements[index].columnIndex = rank
          }
        }
      }
    }
  }

  private mutating func rememberPlacement(
    _ windowID: WindowID, monitor: Monitor, workspace: Workspace,
    workspacePosition: Int, columnIndex: Int, width: ColumnWidth?
  ) {
    guard let window = windows[windowID], !window.appID.isEmpty,
      !window.isModal, window.transientOwnerID == nil,
      window.floatingOrigin != .automatic, !nativeFullscreenWindowIDs.contains(windowID)
    else { return }
    let occupied = Set(placementBindings.values)
    let appID = window.appID.lowercased()
    let index =
      placementBindings[windowID].flatMap { id in
        applicationPlacements.firstIndex { $0.id == id }
      } ?? applicationPlacements.firstIndex {
        $0.appID == appID && !occupied.contains($0.id)
          && $0.workspaceID == workspace.id && $0.columnIndex == columnIndex
      } ?? applicationPlacements.firstIndex { $0.appID == appID && !occupied.contains($0.id) }
    let id = index.map { applicationPlacements[$0].id } ?? UUID().uuidString
    let placement = ApplicationPlacement(
      id: id, appID: appID, monitorID: workspace.affinity ?? monitor.id,
      monitorStableID: monitorStableIDs[workspace.affinity ?? monitor.id],
      workspaceID: workspace.id, workspaceKind: workspace.kind,
      workspacePosition: index.flatMap {
        applicationPlacements[$0].workspaceID == workspace.id
          && applicationPlacements[$0].monitorID == (workspace.affinity ?? monitor.id)
          ? applicationPlacements[$0].workspacePosition : nil
      } ?? workspacePosition,
      columnIndex: index.flatMap {
        applicationPlacements[$0].workspaceID == workspace.id
          ? applicationPlacements[$0].columnIndex : nil
      } ?? columnIndex,
      width: width, floatingFrame: width == nil ? window.frame : nil,
      stackHeightFraction: window.stackHeightFraction
    )
    if let index {
      applicationPlacements[index] = placement
    } else {
      applicationPlacements.append(placement)
    }
    placementBindings[windowID] = id
  }

  mutating func savedPlacement(for window: Window) -> ApplicationPlacement? {
    guard !window.appID.isEmpty, !window.isModal, window.transientOwnerID == nil,
      window.floatingOrigin != .automatic
    else { return nil }
    let occupied = Set(placementBindings.filter { windows[$0.key] != nil }.values)
    guard
      let placement = placementReference.first(where: {
        $0.appID == window.appID.lowercased() && !occupied.contains($0.id)
          && ($0.floatingFrame != nil) == window.floating
      })
        ?? placementReference.first(where: {
          $0.appID == window.appID.lowercased() && !occupied.contains($0.id)
        })
    else { return nil }
    placementBindings[window.id] = placement.id
    return placement
  }

  mutating func restorePlacementWorkspace(_ placement: ApplicationPlacement) -> WorkspaceID? {
    if workspaceLocation(for: placement.workspaceID) != nil { return placement.workspaceID }
    guard placement.workspaceKind != .named else { return nil }
    let monitorIndex =
      placement.monitorStableID.flatMap { stableID in
        monitors.firstIndex { monitorStableIDs[$0.id] == stableID }
      } ?? monitors.firstIndex { $0.id == placement.monitorID }
    guard let monitorIndex else { return nil }
    let trailingIndex =
      monitors[monitorIndex].workspaces.firstIndex { $0.kind == .trailing }
      ?? monitors[monitorIndex].workspaces.count
    let index =
      monitors[monitorIndex].workspaces.indices.first { index in
        let workspace = monitors[monitorIndex].workspaces[index]
        let position =
          placementReference.first { $0.workspaceID == workspace.id }?.workspacePosition ?? index
        return workspace.kind != .trailing && position > placement.workspacePosition
      } ?? trailingIndex
    monitors[monitorIndex].workspaces.insert(
      Workspace(
        id: placement.workspaceID, kind: .ordinary,
        affinity: monitors[monitorIndex].id, affinityPosition: index), at: index)
    return placement.workspaceID
  }

  func siblingWorkspace(for window: Window) -> WorkspaceID? {
    guard !window.floating, !window.appID.isEmpty, !window.isModal,
      window.transientOwnerID == nil
    else { return nil }
    let candidates = monitors.filter { window.monitorID == nil || $0.id == window.monitorID }
      .flatMap { monitor in
        monitor.workspaces.filter { workspace in
          workspace.columns.contains { column in
            column.windows.contains {
              guard let sibling = windows[$0] else { return false }
              return sibling.appID.lowercased() == window.appID.lowercased()
                && !sibling.isModal && sibling.transientOwnerID == nil
            }
          }
        }.map { (monitor, $0) }
      }
    return candidates.first { $0.0.id == window.monitorID && $0.1.id == $0.0.activeWorkspace }?.1.id
      ?? candidates.first { $0.1.id == $0.0.activeWorkspace }?.1.id
      ?? candidates.first?.1.id
  }
}

func insertPlacedWindow(
  _ id: WindowID, width: ColumnWidth, placement: ApplicationPlacement?,
  reference: [ApplicationPlacement], bindings: [WindowID: String],
  into workspace: inout Workspace, settings: LayoutSettings,
  focusInsertedWindow: Bool, insertionIndex: Int?
) {
  if let placement, let stackIndex = placement.stackIndex,
    placement.workspaceID == workspace.id,
    let columnIndex = workspace.columns.firstIndex(where: { column in
      column.windows.contains { other in
        bindings[other].flatMap { binding in reference.first { $0.id == binding } }
          .map {
            $0.workspaceID == workspace.id && $0.columnIndex == placement.columnIndex
              && $0.stackIndex != nil
          } ?? false
      }
    })
  {
    let index = min(max(0, stackIndex), workspace.columns[columnIndex].windows.count)
    workspace.columns[columnIndex].windows.insert(id, at: index)
    workspace.columns[columnIndex].width = width
    if focusInsertedWindow {
      workspace.focusedColumn = columnIndex
      workspace.columns[columnIndex].focusedWindow = index
      repairWorkspaceScroll(&workspace, settings: settings)
    } else if index <= workspace.columns[columnIndex].focusedWindow {
      workspace.columns[columnIndex].focusedWindow += 1
    }
  } else {
    insertNewWindow(
      id, width: width, into: &workspace, settings: settings,
      focusInsertedWindow: focusInsertedWindow, insertionIndex: insertionIndex)
  }
}
