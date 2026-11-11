import Foundation

public enum MasterHUBPage: String, Codable, CaseIterable, Sendable {
  case agents, mac, media, tools, attention, actions, handoffs
  public var title: String {
    switch self { case .handoffs: "Handoffs"; case .agents: "Agents"; case .mac: "Mac"; case .media: "Media"; case .tools: "Tools"; case .attention: "Attention"; case .actions: "Agent Actions" }
  }
}
public struct MasterHUBSurfaceTile: Codable, Equatable, Identifiable, Sendable {
  public var id: String { tile.key }
  public var tile: TileSnapshot
  public var symbol: String
  public var agentId: String? = nil
  public var characterKey: String? = nil
  public var work: SessionWork? = nil
  public var binding: MasterHUBKeyBinding?
  public init(_ tile: TileSnapshot, symbol: String = "", binding: MasterHUBKeyBinding? = nil) {
    self.tile = tile; self.symbol = symbol; self.binding = binding
  }
}
public struct MasterHUBSurfaceSnapshot: Codable, Equatable, Sendable {
  public var instanceID: String
  public var revision: Int
  public var page: MasterHUBPage
  public var pageIndex: Int
  public var pageCount: Int
  public var selectedSessionID: String
  public var selectedRequestID: String? = nil
  public var orientation: Int
  public var tiles: [MasterHUBSurfaceTile]
  public var columns: Int { orientation % 2 == 0 ? 5 : 3 }
}

/// Independent 15-key state. Status changes do not reorder targets or switch views.
public struct MasterHUBSurface {
  public private(set) var page: MasterHUBPage = .agents
  public private(set) var pageIndex = 0
  private var actionSessionID: String?
  private var actionRequestID: String?
  private var agentSlots: [String?] = []
  private var slotPins: [String] = []
  private var revision = 0
  private var signature = Data()
  public init() {}
  public mutating func navigate(_ destination: MasterHUBPage, sessionID: String? = nil, requestID: String? = nil) {
    page = destination; pageIndex = 0; actionSessionID = sessionID; actionRequestID = requestID
  }
  public mutating func movePage(_ delta: Int) { pageIndex = max(0, pageIndex + delta) }
  public mutating func revealSelection(in snapshot: DeckSnapshot) {
    guard page == .agents else { return }
    synchronizeSlots(Self.orderedSessions(snapshot), pins: snapshot.preferences.pinnedSessionIds)
    if let index = agentSlots.firstIndex(where: { $0 == snapshot.selectedSessionId }) { pageIndex = index / 10 }
  }
  private mutating func synchronizeSlots(_ sessions: [SessionSnapshot], pins: [String]) {
    if pins != slotPins { agentSlots.removeAll(); slotPins = pins }
    let active = Set(sessions.map(\.id))
    for index in agentSlots.indices { if let id = agentSlots[index], !active.contains(id) { agentSlots[index] = nil } }
    for session in sessions where !agentSlots.contains(where: { $0 == session.id }) {
      if let empty = agentSlots.firstIndex(where: { $0 == nil }) { agentSlots[empty] = session.id }
      else { agentSlots.append(session.id) }
    }
    while agentSlots.last.map({ $0 == nil }) == true { agentSlots.removeLast() }
  }
  public static func orderedSessions(_ snapshot: DeckSnapshot) -> [SessionSnapshot] {
    let pins = snapshot.preferences.pinnedSessionIds
    return snapshot.sessions.values.filter {
      snapshot.preferences.enabledAgents.contains($0.agentId) && $0.status != .disconnected && $0.status != .unknown
        && (snapshot.preferences.showIdleSessions == true || [.working, .waiting, .error].contains($0.status))
    }.sorted {
      let left = pins.firstIndex(of: $0.id) ?? Int.max, right = pins.firstIndex(of: $1.id) ?? Int.max
      if left != right { return left < right }
      if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
      return $0.id < $1.id
    }
  }
  public mutating func layout(snapshot: DeckSnapshot?, configuration: MasterHUBConfiguration, media: NowPlaying? = nil) -> MasterHUBSurfaceSnapshot {
    let sessions = snapshot.map { value in page == .handoffs ? AgentHandoff.records(value).compactMap { value.sessions[$0.sessionID] } : Self.orderedSessions(value) } ?? []
    let pending = (snapshot?.requests ?? []).filter { $0.state == "pending" && $0.expiresAt > DeckClock.now }
      .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    let preferred = page == .actions ? actionSessionID ?? snapshot?.selectedSessionId : snapshot?.selectedSessionId
    // An explicitly opened action context must never silently retarget another agent.
    let selected = sessions.first { $0.id == preferred } ?? (page == .actions && actionSessionID != nil ? nil : sessions.first)
    var items: [MasterHUBSurfaceTile] = []
    var pages = 1
    var currentRequestID: String?
    func entry(_ label: String, _ subtitle: String = "", symbol: String = "", action: String = "none",
      target: String = "", status: String = "IDLE", enabled: Bool = true, hold: Bool = false,
      request: String = "", choice: String = "") -> MasterHUBSurfaceTile {
      .init(.init(key: "", label: label, sublabel: subtitle, status: status, action: action, target: target,
        requestId: request, choiceId: choice, enabled: enabled, requiresHold: hold), symbol: symbol)
    }
    switch page {
    case .agents:
      synchronizeSlots(sessions, pins: snapshot?.preferences.pinnedSessionIds ?? [])
      pages = max(1, (agentSlots.count + 9) / 10); pageIndex = min(pageIndex, pages - 1)
      let indexed = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id,$0) })
      for slot in agentSlots.dropFirst(pageIndex * 10).prefix(10) {
        guard let id = slot, let session = indexed[id] else { items.append(entry("",enabled:false)); continue }
        let duplicates = sessions.filter { $0.workspace == session.workspace && $0.agentId == session.agentId }
        let ordinal = duplicates.count > 1 ? " · \((duplicates.firstIndex(where: { $0.id == session.id }) ?? 0) + 1)" : ""
        let symbol: String
        switch session.status {
        case .working: symbol = session.work?.awaitingResults == true ? "hourglass" : "gearshape.2"
        case .waiting: symbol = "hand.raised"
        case .done: symbol = "checkmark.circle"
        case .error: symbol = "exclamationmark.triangle"
        case .idle: symbol = "terminal"
        default: symbol = "questionmark.circle"
        }
        var item = entry(snapshot?.preferences.projectNames[session.projectKey] ?? session.workspace,
          session.agentName + ordinal, symbol: symbol, action: "focus", target: session.id,
          status: session.status.rawValue, enabled: session.capabilities.focus)
        item.agentId = session.agentId; item.characterKey = session.projectKey; item.work = session.work
        item.tile.detail = session.capabilities.focus ? session.cwd : session.capabilities.reason
        items.append(item)
      }
      if items.count < 10, snapshot != nil, pending.isEmpty, sessions.allSatisfy({ $0.status == .idle || $0.status == .done }) {
        items.append(entry("All clear", "Alfred online", symbol: "checkmark.shield", status: "CLEAR", enabled: false))
      }
    case .handoffs:
      let records = snapshot.map(AgentHandoff.records) ?? []
      pages = max(1, (records.count + 9) / 10); pageIndex = min(pageIndex, pages - 1)
      for record in records.dropFirst(pageIndex * 10).prefix(10) {
        var item = entry(record.project, record.state.label,
          symbol: record.state == .waiting ? "hand.raised" : record.state == .error ? "exclamationmark.triangle" : "checkmark.circle",
          action: "focus", target: record.sessionID, status: record.state.rawValue, enabled: record.canFocus)
        item.agentId = snapshot?.sessions[record.sessionID]?.agentId
        item.characterKey = snapshot?.sessions[record.sessionID]?.projectKey
        items.append(item)
      }
    case .mac:
      pageIndex = 0
      for binding in configuration.macKeys {
        items.append(.init(.init(key: "", label: binding.label, sublabel: binding.kind.title,
          action: "hub.mac", target: binding.id), symbol: binding.kind.symbol, binding: binding))
      }
    case .tools:
      pageIndex = 0
      let symbols = ["doc.on.doc.fill", "doc.on.clipboard.fill", "arrow.uturn.backward", "arrow.uturn.forward", "magnifyingglass", "square.and.arrow.down.fill", "rectangle.2.swap", "viewfinder", "sparkle.magnifyingglass", "square.grid.3x3.fill"]
      for (index, binding) in MasterHUBConfiguration.utilityKeys.enumerated() {
        items.append(.init(.init(key: "", label: binding.label, status: "TOOLS", action: "hub.mac", target: binding.id), symbol: symbols[index], binding: binding))
      }
    case .media:
      pageIndex = 0
      let controls: [(String, String, String)] = [
        ("Spotify", "music.note", "open"), ("Play / Pause", "playpause.fill", "playpause"),
        ("Previous", "backward.end.fill", "previous track"), ("Next", "forward.end.fill", "next track"),
        ("Shuffle", "shuffle", "shuffle"), ("Repeat", "repeat", "repeat"),
        ("Quieter", "speaker.minus.fill", "volumeDown"), ("Louder", "speaker.plus.fill", "volumeUp"),
        ("Mute", "speaker.slash.fill", "mute"), ("Your Mac", "desktopcomputer", "mac")]
      for (label, symbol, command) in controls {
        let active = command == "playpause" ? media?.playing == true : command == "shuffle" ? media?.shuffle == true : command == "repeat" ? media?.repeating == true : false
        let title = command == "playpause" ? (media?.playing == true ? "Pause" : "Play") : label
        let icon = command == "playpause" ? (media?.playing == true ? "pause.fill" : "play.fill") : symbol
        items.append(entry(title, active ? "On" : "", symbol: icon, action: "hub.media", target: command, status: active ? "DONE" : "MEDIA"))
      }
    case .attention:
      pages = max(1, (pending.count + 9) / 10); pageIndex = min(pageIndex, pages - 1)
      for request in pending.dropFirst(pageIndex * 10).prefix(10) {
        let session = snapshot?.sessions[request.sessionId]
        items.append(entry(session?.workspace ?? "Agent request", request.title,
          symbol: "exclamationmark.bubble", action: "hub.request", target: request.sessionId,
          status: "WAITING", request: request.id))
      }
    case .actions:
      if selected == nil { pageIndex = 0 }
      if let selected {
        items.append(entry("Open session", selected.workspace, symbol: "arrow.up.forward.app",
          action: "focus", target: selected.id, enabled: selected.capabilities.focus))
        var interrupt = entry("Interrupt", "Hold 0.7 seconds", symbol: "stop.circle",
          action: "stop", target: selected.id, enabled: selected.capabilities.interrupt, hold: true)
        interrupt.tile.detail = selected.capabilities.interrupt ? "Interrupt this agent’s verified work" : selected.capabilities.reason
        items.append(interrupt)
        let selectedRequests = pending.filter { $0.sessionId == selected.id }
        let selectedRequest = actionRequestID == nil ? selectedRequests.first
          : selectedRequests.first { $0.id == actionRequestID }
        if let request = selectedRequest {
          currentRequestID = request.id
          pages = max(1, (request.choices.count + 7) / 8)
          pageIndex = min(pageIndex, pages - 1)
          for choice in request.choices.dropFirst(pageIndex * 8).prefix(8) {
            items.append(entry(choice.label, request.title, symbol: choice.requiresHold ? "hand.raised" : "arrowshape.turn.up.left",
              action: "respond", target: selected.id, status: "WAITING", hold: choice.requiresHold,
              request: request.id, choice: choice.id))
          }
        } else {
          pageIndex = 0
          items.append(entry(actionRequestID == nil ? "No pending request" : "Request finished",
            actionRequestID == nil ? "Nothing to answer" : "Return to Attention", symbol: "checkmark.circle", enabled: false))
        }
      }
    }
    while items.count < 10 {
      let emptyLabel = page == .agents && sessions.isEmpty && items.isEmpty ? "All quiet" : page == .attention && pending.isEmpty && items.isEmpty ? "All clear" : ""
      items.append(entry(emptyLabel, symbol: emptyLabel.isEmpty ? "" : "checkmark.circle", enabled: false))
    }
    items = Array(items.prefix(10))
    items.append(entry("Previous", "\(pageIndex + 1) of \(pages)", symbol: "chevron.left", action: "hub.previous", enabled: pageIndex > 0))
    items.append(entry("Attention", "\(pending.count) waiting", symbol: "tray", action: "hub.attention", status: pending.isEmpty ? "IDLE" : "WAITING"))
    items.append(entry("Agent actions", selected?.workspace ?? "Choose an agent", symbol: "slider.horizontal.3",
      action: "hub.actions", target: selected?.id ?? "", enabled: selected != nil))
    items.append(entry(page == .agents ? "Handoffs" : page == .mac ? "Media" : page == .media ? "Tools" : page == .tools ? "Agents" : "Mac",
      symbol: page == .agents ? "checkmark.bubble" : page == .mac ? "music.note" : page == .media ? "square.grid.2x2" : page == .tools ? "terminal" : "desktopcomputer",
      action: page == .agents ? "hub.handoffs" : page == .mac ? "hub.mediaPage" : page == .media ? "hub.toolsPage" : page == .tools ? "hub.agents" : "hub.macPage"))
    items.append(entry("Next", "\(pageIndex + 1) of \(pages)", symbol: "chevron.right", action: "hub.next", enabled: pageIndex + 1 < pages))
    // Agent actions require a live service; Mac actions remain available offline.
    if snapshot == nil {
      for index in items.indices where !items[index].tile.action.hasPrefix("hub.") {
        items[index].tile.enabled = false
      }
    }
    for index in items.indices { items[index].tile.key = String(index) }
    let state = MasterHUBSurfaceSnapshot(instanceID: snapshot?.instanceId ?? "offline", revision: 0,
      page: page, pageIndex: pageIndex, pageCount: pages, selectedSessionID: selected?.id ?? "", selectedRequestID: currentRequestID,
      orientation: configuration.keypadRotation, tiles: items)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let encoded = (try? encoder.encode(state)) ?? Data()
    if encoded != signature { revision += 1; signature = encoded }
    var result = state; result.revision = revision
    return result
  }
  public static func validatePress(_ displayed: MasterHUBSurfaceSnapshot, current: MasterHUBSurfaceSnapshot,
    index: Int, heldMs: Int) -> MasterHUBSurfaceTile? {
    guard displayed.instanceID == current.instanceID,
      displayed.orientation == current.orientation, displayed.page == current.page, displayed.pageIndex == current.pageIndex,
      displayed.tiles.indices.contains(index), current.tiles.indices.contains(index) else { return nil }
    let item = displayed.tiles[index], latest = current.tiles[index]
    // A background status change must not cancel focus on the same agent. All
    // consequential actions retain the full surface revision and exact tile check.
    if item.tile.action == "focus" {
      guard latest.tile.action == "focus", item.tile.target == latest.tile.target,
        latest.tile.enabled else { return nil }
    } else if ["hub.mac", "hub.media"].contains(item.tile.action) {
      guard latest.tile.enabled, item.tile.action == latest.tile.action, item.tile.target == latest.tile.target,
        item.binding == latest.binding else { return nil }
    } else {
      guard displayed.revision == current.revision, item == latest else { return nil }
    }
    guard item.tile.enabled, !item.tile.requiresHold || heldMs >= 700 else { return nil }
    return item
  }
}
