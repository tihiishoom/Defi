import DefiConfig
import DefiCore
import DefiModel
import Darwin

public func discoverWindow(
  _ original: Window,
  decision: RuleDecision,
  isNativelyFocused: Bool = false,
  isFrontmostAppSpawn: Bool = false,
  isNativeFullscreen: Bool = false,
  state: inout RuntimeState
) throws {
  guard !state.monitors.isEmpty else {
    throw ReducerError.noMonitor
  }
  if state.windows[original.id] != nil {
    var updated = original
    updated.stackHeightFraction = state.windows[original.id]?.stackHeightFraction
    state.windows[original.id] = updated
    return
  }

  var window = original
  window.forceTiling = decision.forceTiling || original.forceTiling
  window.floating =
    (((original.floating || original.isTransient) && !isNativeFullscreen) || decision.floating)
    && !window.forceTiling
  if window.forceTiling {
    window.floatingOrigin = nil
  } else if decision.floating {
    window.floatingOrigin = .configured
  } else if window.floating && window.isTransient && window.floatingOrigin == nil {
    window.floatingOrigin = .automatic
  }
  window.intrinsicSize = decision.intrinsicSize
  let transientLocation = transientPlacementLocation(for: window, state: state)
  let saved = isNativeFullscreen ? nil : state.savedPlacement(for: window)
  window.stackHeightFraction = saved?.stackHeightFraction
  if let saved, !window.forceTiling, !decision.floating {
    window.floating = saved.floatingFrame != nil
    window.floatingOrigin = window.floating ? .user : nil
  }
  let rememberedWorkspace = transientLocation == nil && decision.workspace == nil
    ? saved.flatMap { state.restorePlacementWorkspace($0) } : nil
  let siblingWorkspace = transientLocation == nil && decision.workspace == nil && rememberedWorkspace == nil
    ? state.siblingWorkspace(for: window) : nil
  let followFocusIntent = decision.followFocus && isNativelyFocused
  let targetWorkspace = decision.workspace ?? rememberedWorkspace ?? siblingWorkspace
  let ruleLocation = targetWorkspace.flatMap { state.workspaceLocation(for: $0) }
  let monitorID =
    transientLocation?.monitorID
    ?? ruleLocation.map { state.monitors[$0.monitorIndex].id }
    ?? window.monitorID
    ?? state.monitors[0].id
  let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }) ?? 0
  let workspaceID =
    transientLocation?.workspaceID
    ?? targetWorkspace
    ?? state.monitors[monitorIndex].activeWorkspace
  guard
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == workspaceID }
    )
  else {
    throw ReducerError.unknownWorkspace(workspaceID)
  }
  // Policy: a managed window spawned by the frontmost application follows
  // its assigned workspace and takes focus. The native focused-window event
  // can legitimately lag window creation, so it alone must not gate this.
  let followsFocus =
    followFocusIntent
    || (isFrontmostAppSpawn && !window.floating)

  if window.floating && !window.forceTiling {
    if let frame = saved?.floatingFrame, transientLocation == nil {
      window.frame = frame
    }
    state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.append(window.id)
    if followsFocus {
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedFloatingWindow =
        state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.count - 1
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedLayer = .floating
    }
  } else {
    let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
    let siblingColumns = workspace.columns.indices.filter { index in
      let column = workspace.columns[index]
      return column.windows.contains { state.windows[$0]?.appID.lowercased() == window.appID.lowercased() }
    }
    let siblingColumn = siblingColumns.contains(workspace.focusedColumn)
      ? workspace.focusedColumn : siblingColumns.last
    let restoredIndex = saved.flatMap { placement in
      workspace.columns.firstIndex { column in
        column.windows.contains { id in
          state.placementBindings[id].flatMap { binding in
            state.placementReference.first { $0.id == binding }
          }.map { $0.columnIndex > placement.columnIndex } ?? false
        }
      } ?? workspace.columns.count
    }
    let insertionIndex = rememberedWorkspace != nil ? restoredIndex : siblingColumn.map { $0 + 1 }
    insertPlacedWindow(
      window.id,
      width: decision.initialColumnWidth.map { .fraction($0) }
        ?? saved?.width ?? .fraction(state.layout.defaultColumnWidth),
      placement: rememberedWorkspace == nil ? nil : saved,
      reference: state.placementReference, bindings: state.placementBindings,
      into: &state.monitors[monitorIndex].workspaces[workspaceIndex],
      settings: state.layout,
      focusInsertedWindow: followsFocus,
      insertionIndex: insertionIndex
    )
    if followsFocus {
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedLayer = .tiled
    }
  }
  if followsFocus {
    state.monitors[monitorIndex].activeWorkspace = workspaceID
  }
  state.windows[window.id] = window
  state.maintainWorkspaceLifecycle()
}

public func transientPlacementLocation(
  for window: Window,
  state: RuntimeState,
  locations: WindowLocationMap? = nil
) -> (monitorID: MonitorID, workspaceID: WorkspaceID)? {
  func location(containing windowID: WindowID) -> (monitorID: MonitorID, workspaceID: WorkspaceID)? {
    locations?[windowID] ?? state.location(containing: windowID)
  }
  guard window.isTransient || window.floatingOrigin == .automatic else { return nil }
  if let ownerID = window.transientOwnerID,
    let ownerLocation = location(containing: ownerID)
  {
    return ownerLocation
  }
  let sameApplicationSelections = state.monitors.compactMap { monitor -> WindowID? in
    guard let selected = state.selectedWindowID(on: monitor.id),
      let selectedWindow = state.windows[selected],
      selectedWindow.appID == window.appID,
      window.processID.map({ selectedWindow.processID == $0 }) ?? true
    else { return nil }
    return selected
  }
  guard sameApplicationSelections.count == 1 else { return nil }
  return location(containing: sameApplicationSelections[0])
}

@discardableResult
public func moveFloatingWindow(
  _ windowID: WindowID,
  to targetMonitorID: MonitorID,
  state: inout RuntimeState
) -> Bool {
  guard
    let sourceMonitorIndex = state.monitors.firstIndex(where: { monitor in
      monitor.workspaces.contains(where: { $0.floatingWindows.contains(windowID) })
    }),
    state.monitors[sourceMonitorIndex].id != targetMonitorID,
    let sourceWorkspaceIndex = state.monitors[sourceMonitorIndex].workspaces.firstIndex(
      where: { $0.floatingWindows.contains(windowID) }
    ),
    let targetMonitorIndex = state.monitors.firstIndex(where: {
      $0.id == targetMonitorID
    }),
    let targetWorkspaceIndex = state.monitors[targetMonitorIndex].workspaces.firstIndex(
      where: { $0.id == state.monitors[targetMonitorIndex].activeWorkspace }
    )
  else {
    return false
  }

  state.suspendedTiledPlacements[windowID] = nil
  removeWindow(
    windowID,
    from: &state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex],
    settings: state.layout
  )
  state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].floatingWindows.append(
    windowID
  )
  state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].focusedFloatingWindow =
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].floatingWindows.count - 1
  state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].focusedLayer = .floating
  state.windows[windowID]?.monitorID = targetMonitorID
  return true
}

@discardableResult
public func reconcileWindows(
  _ discovered: [Window],
  config: Config,
  windowIDReplacements: [WindowID: WindowID] = [:],
  externallyChangedWindowIDs: Set<WindowID> = [],
  nativeFullscreenWindowIDs: Set<WindowID> = [],
  explicitlyRemovedWindowIDs: Set<WindowID> = [],
  viewports: [MonitorID: Rect] = [:],
  nativeFocusedWindowID: WindowID? = nil,
  frontmostProcessID: pid_t? = nil,
  state: inout RuntimeState
) -> Set<WindowID> {
  var relocatedTransientIDs = Set<WindowID>()
  state.rememberApplicationPlacements()
  let discoveredIDs = Set(discovered.map(\.id))
  let fullscreenWindowIDs = nativeFullscreenWindowIDs.subtracting(
    explicitlyRemovedWindowIDs
  )
  applyWindowIDReplacements(
    windowIDReplacements,
    discoveredWindows: Dictionary(
      discovered.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest }
    ),
    state: &state
  )
  let fullscreenSpaceHidesOtherWindows =
    !fullscreenWindowIDs.isEmpty || !state.nativeFullscreenWindowIDs.isEmpty
  for existingID in Array(state.windows.keys)
  where !discoveredIDs.contains(existingID)
    && (!fullscreenSpaceHidesOtherWindows || explicitlyRemovedWindowIDs.contains(existingID))
  {
    if explicitlyRemovedWindowIDs.contains(existingID) {
      adjustNativeFullscreenPlacements(afterRemoving: existingID, state: &state)
    }
    let survivingOwner = state.windows[existingID]?.transientOwnerID.flatMap { ownerID -> WindowID? in
      guard discoveredIDs.contains(ownerID),
        let childLocation = state.location(containing: existingID),
        let ownerLocation = state.location(containing: ownerID),
        childLocation.monitorID == ownerLocation.monitorID,
        childLocation.workspaceID == ownerLocation.workspaceID,
        state.selectedWindowID(on: childLocation.monitorID) == existingID
      else { return nil }
      return ownerID
    }
    removeWindowFromEveryWorkspace(existingID, state: &state)
    state.windows[existingID] = nil
    if let survivingOwner {
      focusWindow(survivingOwner, state: &state)
    }
    state.nativeFullscreenFloatingWindowIDs.remove(existingID)
    state.nativeFullscreenTiledPlacements[existingID] = nil
    state.pendingNativeFullscreenWidthResetWindowIDs.remove(existingID)
    state.suspendedTiledPlacements[existingID] = nil
  }

  for window in discovered {
    if state.windows[window.id] == nil {
      try? discoverWindow(
        window,
        decision: config.decision(for: window),
        isNativelyFocused: window.id == nativeFocusedWindowID,
        isFrontmostAppSpawn: window.processID != nil
          && window.processID == frontmostProcessID,
        isNativeFullscreen: fullscreenWindowIDs.contains(window.id),
        state: &state
      )
    } else {
      var updated = window
      if let existing = state.windows[window.id] {
        if updated.isTransient, !existing.forceTiling, !fullscreenWindowIDs.contains(window.id) {
          updated.floating = true
          updated.floatingOrigin = existing.floatingOrigin ?? .automatic
          if !existing.floating {
            reclassifyTiledWindowAsAutomaticFloater(window.id, state: &state)
          }
        } else if existing.floatingOrigin == .automatic,
          !fullscreenWindowIDs.contains(window.id)
        {
          reclassifyAutomaticWindow(
            window.id,
            observedFloating: updated.floating,
            state: &state
          )
        } else if existing.floatingOrigin == nil,
          !existing.forceTiling,
          updated.floatingOrigin == .automatic,
          updated.floating,
          !fullscreenWindowIDs.contains(window.id)
        {
          reclassifyTiledWindowAsAutomaticFloater(
            window.id,
            state: &state
          )
        } else {
          updated.floating = existing.floating
          updated.floatingOrigin = existing.floatingOrigin
        }
        updated.stackHeightFraction = existing.stackHeightFraction
        updated.forceTiling = existing.forceTiling
        updated.intrinsicSize = existing.intrinsicSize
        if fullscreenWindowIDs.contains(window.id) {
          updated.minimumTiledWidth = nil
          updated.maximumTiledWidth = nil
          updated.minimumTiledHeight = nil
          updated.maximumTiledHeight = nil
        } else if window.minimumTiledWidth != nil
          || window.maximumTiledWidth != nil
        {
          updated.minimumTiledWidth = window.minimumTiledWidth
          updated.maximumTiledWidth = window.maximumTiledWidth
        } else {
          // Keep learned width bounds, but retain the current snapshot's height capability.
          updated.minimumTiledWidth = existing.minimumTiledWidth
          updated.maximumTiledWidth = existing.maximumTiledWidth
        }
        if let acceptance = existing.tiledSizeAcceptance,
          updated.maximumTiledHeight != nil || isTiledSizeSnap(acceptance),
          !fullscreenWindowIDs.contains(window.id),
          ((abs(window.frame.width - acceptance.accepted.width) < 1
            && abs(window.frame.height - acceptance.accepted.height) < 1)
            || !externallyChangedWindowIDs.contains(window.id))
        {
          updated.tiledSizeAcceptance = acceptance
        } else {
          updated.tiledSizeAcceptance = nil
        }
        if existing.intrinsicSize,
          !externallyChangedWindowIDs.contains(window.id)
        {
          updated.frame.width = existing.frame.width
          updated.frame.height = existing.frame.height
        }
      }
      state.windows[window.id] = updated
    }
  }
  // ponytail: bounded convergence scan; owner-ordering can replace it if deep chains become common.
  for _ in discovered.indices {
    var relocatedInPass = false
    var locations = state.windowLocationMap()
    for window in discovered where relocateTransientIfNeeded(
      window.id,
      viewports: viewports,
      locations: &locations,
      state: &state
    ) {
      relocatedTransientIDs.insert(window.id)
      relocatedInPass = true
    }
    if relocatedInPass == false { break }
  }
  reconcileNativeFullscreenWindows(fullscreenWindowIDs, state: &state)
  state.pendingNativeFullscreenWidthResetWindowIDs.subtract(explicitlyRemovedWindowIDs)
  state.maintainWorkspaceLifecycle()
  state.rememberApplicationPlacements()
  return relocatedTransientIDs
}

private func adjustNativeFullscreenPlacements(
  afterRemoving windowID: WindowID,
  state: inout RuntimeState
) {
  guard let location = state.location(containing: windowID),
    let monitorIndex = state.monitors.firstIndex(where: { $0.id == location.monitorID }),
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == location.workspaceID }
    ),
    let columnIndex = state.monitors[monitorIndex].workspaces[workspaceIndex].columns.firstIndex(
      where: { $0.windows.contains(windowID) }
    ),
    state.monitors[monitorIndex].workspaces[workspaceIndex].columns[columnIndex].windows.count == 1
  else { return }

  let placements = state.nativeFullscreenTiledPlacements.filter {
    $0.value.monitorID == location.monitorID && $0.value.workspaceID == location.workspaceID
  }
  // A suspended sibling keeps this logical column alive after its last visible window closes.
  guard !placements.contains(where: {
    $0.key != windowID && $0.value.column.windows.contains(windowID)
  }) else { return }
  // Columns still reflect the previous fullscreen set; this pass's transitions run after removal.
  let visibleWindowIDs = Set(
    state.monitors[monitorIndex].workspaces[workspaceIndex].columns.flatMap(\.windows)
  ).subtracting(state.nativeFullscreenWindowIDs)
  let originalColumnIndex: Int
  if let placement = placements[windowID] {
    guard !placement.column.windows.contains(where: visibleWindowIDs.contains) else { return }
    originalColumnIndex = placement.columnIndex
  } else {
    // Fullscreen placeholders for floating windows do not occupy a logical tiled column.
    guard !state.nativeFullscreenWindowIDs.contains(windowID) else { return }
    let suspendedColumnIndices = Set(placements.values.filter {
      !$0.column.windows.contains(where: visibleWindowIDs.contains)
    }.map(\.columnIndex))
    originalColumnIndex = suspendedColumnIndices.sorted().reduce(columnIndex) {
      index, suspended in suspended <= index ? index + 1 : index
    }
  }

  for (fullscreenID, placement) in placements where placement.columnIndex > originalColumnIndex {
    state.nativeFullscreenTiledPlacements[fullscreenID] = SuspendedTiledPlacement(
      monitorID: placement.monitorID,
      workspaceID: placement.workspaceID,
      columnIndex: placement.columnIndex - 1,
      windowIndex: placement.windowIndex,
      column: placement.column
    )
  }
}

private func applyWindowIDReplacements(
  _ replacements: [WindowID: WindowID],
  discoveredWindows: [WindowID: Window],
  state: inout RuntimeState
) {
  for (previousID, replacementID) in replacements.sorted(by: {
    $0.key.rawValue < $1.key.rawValue
  }) {
    guard previousID != replacementID,
      state.windows[replacementID] == nil,
      var replacement = discoveredWindows[replacementID],
      let previous = state.windows.removeValue(forKey: previousID)
    else { continue }

    replacement.floating = previous.floating
    replacement.floatingOrigin = previous.floatingOrigin
    replacement.forceTiling = previous.forceTiling
    replacement.intrinsicSize = previous.intrinsicSize
    replacement.stackHeightFraction = previous.stackHeightFraction
    replacement.minimumTiledWidth = previous.minimumTiledWidth
    replacement.maximumTiledWidth = previous.maximumTiledWidth
    if previous.intrinsicSize {
      replacement.frame.width = previous.frame.width
      replacement.frame.height = previous.frame.height
    }
    state.windows[replacementID] = replacement
    var recentSeen = Set<WindowID>()
    state.recentWindowIDs = state.recentWindowIDs.map { $0 == previousID ? replacementID : $0 }
      .filter { recentSeen.insert($0).inserted }

    for monitorIndex in state.monitors.indices {
      for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
        for columnIndex in state.monitors[monitorIndex].workspaces[workspaceIndex]
          .columns.indices
        {
          state.monitors[monitorIndex].workspaces[workspaceIndex].columns[columnIndex]
            .windows = state.monitors[monitorIndex].workspaces[workspaceIndex]
            .columns[columnIndex].windows.map {
              $0 == previousID ? replacementID : $0
            }
        }
        state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows =
          state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.map {
            $0 == previousID ? replacementID : $0
          }
      }
    }
    for windowID in state.windows.keys
    where state.windows[windowID]?.transientOwnerID == previousID {
      state.windows[windowID]?.transientOwnerID = replacementID
    }
    replace(previousID, with: replacementID, in: &state.nativeFullscreenWindowIDs)
    replace(
      previousID,
      with: replacementID,
      in: &state.nativeFullscreenFloatingWindowIDs
    )
    replace(
      previousID,
      with: replacementID,
      in: &state.pendingNativeFullscreenWidthResetWindowIDs
    )
    replace(
      previousID,
      with: replacementID,
      in: &state.nativeFullscreenTiledPlacements
    )
    replace(
      previousID,
      with: replacementID,
      in: &state.suspendedTiledPlacements
    )
  }
}

private func replace(
  _ previousID: WindowID,
  with replacementID: WindowID,
  in windowIDs: inout Set<WindowID>
) {
  guard windowIDs.remove(previousID) != nil else { return }
  windowIDs.insert(replacementID)
}

private func replace(
  _ previousID: WindowID,
  with replacementID: WindowID,
  in placements: inout [WindowID: SuspendedTiledPlacement]
) {
  var replaced: [WindowID: SuspendedTiledPlacement] = [:]
  replaced.reserveCapacity(placements.count)
  for (windowID, placement) in placements {
    var column = placement.column
    column.windows = column.windows.map {
      $0 == previousID ? replacementID : $0
    }
    replaced[windowID == previousID ? replacementID : windowID] =
      SuspendedTiledPlacement(
        monitorID: placement.monitorID,
        workspaceID: placement.workspaceID,
        columnIndex: placement.columnIndex,
        windowIndex: placement.windowIndex,
        column: column
      )
  }
  placements = replaced
}

func selectedWindowID(in workspace: Workspace) -> WindowID? {
  if workspace.focusedLayer == .floating,
    workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow)
  {
    return workspace.floatingWindows[workspace.focusedFloatingWindow]
  }
  guard workspace.columns.indices.contains(workspace.focusedColumn) else { return nil }
  let column = workspace.columns[workspace.focusedColumn]
  guard column.windows.indices.contains(column.focusedWindow) else { return nil }
  return column.windows[column.focusedWindow]
}

func restoreSelection(
  _ windowID: WindowID?,
  in workspace: inout Workspace
) {
  guard let windowID else { return }
  if let floatingIndex = workspace.floatingWindows.firstIndex(of: windowID) {
    workspace.focusedFloatingWindow = floatingIndex
    workspace.focusedLayer = .floating
    return
  }
  guard
    let columnIndex = workspace.columns.firstIndex(where: {
      $0.windows.contains(windowID)
    }),
    let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID)
  else { return }
  workspace.focusedColumn = columnIndex
  workspace.columns[columnIndex].focusedWindow = windowIndex
  workspace.focusedLayer = .tiled
}
