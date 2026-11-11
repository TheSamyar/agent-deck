import Foundation

/// A single integrated editor terminal and the PIDs in its process tree.
public struct EditorTerminalEntry: Sendable, Equatable {
  public let id: String
  public let processTree: [Int]

  public init(id: String, processTree: [Int]) {
    self.id = id
    self.processTree = processTree
  }
}

/// Latest poll snapshot reported by an editor extension instance.
public struct EditorBridgeSnapshot: Sendable, Equatable {
  public let instanceId: String
  public var updatedAt: Double
  public var terminals: [EditorTerminalEntry]

  public init(instanceId: String, updatedAt: Double, terminals: [EditorTerminalEntry]) {
    self.instanceId = instanceId
    self.updatedAt = updatedAt
    self.terminals = terminals
  }
}

/// Unambiguous editor bridge instance and terminal matched to a session PID.
public struct EditorBridgeTarget: Sendable, Equatable {
  public let instanceId: String
  public let terminalId: String

  public init(instanceId: String, terminalId: String) {
    self.instanceId = instanceId
    self.terminalId = terminalId
  }
}

/// Command queued for an editor extension instance to execute on a terminal.
public struct EditorBridgeCommand: Sendable, Equatable {
  public let id: String
  public let terminalId: String
  public let action: String

  public init(id: String, terminalId: String, action: String) {
    self.id = id
    self.terminalId = terminalId
    self.action = action
  }
}

/// Tracks live editor bridge polls, queued commands, and acknowledged command results.
public struct EditorTerminalBridgeRegistry: Sendable {
  private static let maxBridgesBeforePrune = 32
  private static let maxLiveBridges = 64
  private static let maxTrackedCommands = 256

  private let staleAfterMs: Double
  private var bridges: [String: EditorBridgeSnapshot] = [:]
  private var pendingCommands: [String: EditorBridgeCommand] = [:]
  private var pendingInstanceOrder: [String] = []
  private var pendingCommandIDs: Set<String> = []
  private var pendingCommandOrder: [String] = []
  private var results: [String: ActionResult] = [:]
  private var resultOrder: [String] = []

  public init(staleAfterMs: Double = 5000) {
    self.staleAfterMs = staleAfterMs
  }

  /// Records a poll from an editor instance, pruning stale bridges and storing expected command results.
  public mutating func recordPoll(
    instanceId: String,
    terminals: [EditorTerminalEntry],
    result: (id: String, ok: Bool, message: String)? = nil,
    now: Double
  ) {
    guard !instanceId.isEmpty else { return }
    let validTerminals = terminals.filter { !$0.id.isEmpty }
    bridges[instanceId] = EditorBridgeSnapshot(
      instanceId: instanceId,
      updatedAt: now,
      terminals: validTerminals
    )
    if bridges.count > Self.maxBridgesBeforePrune {
      bridges = bridges.filter { now - $0.value.updatedAt < staleAfterMs }
    }
    if bridges.count > Self.maxLiveBridges {
      let evictOrder = bridges.values
        .filter { $0.instanceId != instanceId }
        .sorted { $0.updatedAt < $1.updatedAt }
      for victim in evictOrder.prefix(bridges.count - Self.maxLiveBridges) {
        bridges.removeValue(forKey: victim.instanceId)
      }
    }
    if let result, !result.id.isEmpty, pendingCommandIDs.contains(result.id) {
      let actionResult = ActionResult(
        ok: result.ok,
        state: result.ok ? "acknowledged" : "failed",
        message: result.message,
        commandId: result.id
      )
      if results[result.id] == nil {
        resultOrder.append(result.id)
      }
      results[result.id] = actionResult
      while results.count > Self.maxTrackedCommands, !resultOrder.isEmpty {
        let oldest = resultOrder.removeFirst()
        results.removeValue(forKey: oldest)
      }
    }
  }

  /// Resolves an unambiguous live bridge target owning `pid`, failing closed on ambiguity.
  public func findTarget(forSessionPID pid: Int, now: Double) -> EditorBridgeTarget? {
    guard pid > 0 else { return nil }
    var matchedTarget: EditorBridgeTarget?
    for bridge in bridges.values where now - bridge.updatedAt < staleAfterMs {
      let matchingTerminals = bridge.terminals.filter { $0.processTree.contains(pid) }
      if matchingTerminals.count > 1 { return nil }
      if let terminal = matchingTerminals.first {
        if matchedTarget != nil { return nil }
        matchedTarget = EditorBridgeTarget(instanceId: bridge.instanceId, terminalId: terminal.id)
      }
    }
    return matchedTarget
  }

  /// Enqueues a command for the given editor instance and tracks its ID for result acceptance.
  public mutating func enqueueCommand(
    instanceId: String,
    commandId: String,
    terminalId: String,
    action: String
  ) {
    guard !instanceId.isEmpty, !commandId.isEmpty, !terminalId.isEmpty, !action.isEmpty else {
      return
    }
    if let overwritten = pendingCommands[instanceId] {
      removeTrackedCommandID(overwritten.id)
      pendingInstanceOrder.removeAll { $0 == instanceId }
    } else {
      while pendingCommands.count >= Self.maxTrackedCommands, !pendingInstanceOrder.isEmpty {
        let oldestInstance = pendingInstanceOrder.removeFirst()
        if let evicted = pendingCommands.removeValue(forKey: oldestInstance) {
          removeTrackedCommandID(evicted.id)
        }
      }
    }
    pendingCommands[instanceId] = EditorBridgeCommand(
      id: commandId,
      terminalId: terminalId,
      action: action
    )
    pendingInstanceOrder.append(instanceId)
    if pendingCommandIDs.insert(commandId).inserted {
      pendingCommandOrder.append(commandId)
      while pendingCommandIDs.count > Self.maxTrackedCommands, !pendingCommandOrder.isEmpty {
        let oldest = pendingCommandOrder.removeFirst()
        pendingCommandIDs.remove(oldest)
      }
    }
  }

  /// Atomically pops the next pending command for `instanceId`.
  public mutating func takePendingCommand(for instanceId: String) -> EditorBridgeCommand? {
    guard let command = pendingCommands.removeValue(forKey: instanceId) else { return nil }
    pendingInstanceOrder.removeAll { $0 == instanceId }
    return command
  }

  /// Cancels an awaited command, removing it from pending queues and tracked IDs/results.
  public mutating func cancelCommand(instanceId: String, commandId: String) {
    if pendingCommands[instanceId]?.id == commandId {
      pendingCommands.removeValue(forKey: instanceId)
      pendingInstanceOrder.removeAll { $0 == instanceId }
    }
    removeTrackedCommandID(commandId)
    if results.removeValue(forKey: commandId) != nil {
      resultOrder.removeAll { $0 == commandId }
    }
  }

  /// Consumes a stored result for `commandId` once available, clearing its tracked command ID.
  public mutating func takeResult(for commandId: String) -> ActionResult? {
    guard let result = results.removeValue(forKey: commandId) else { return nil }
    resultOrder.removeAll { $0 == commandId }
    removeTrackedCommandID(commandId)
    return result
  }

  private mutating func removeTrackedCommandID(_ commandId: String) {
    if pendingCommandIDs.remove(commandId) != nil {
      pendingCommandOrder.removeAll { $0 == commandId }
    }
  }
}

/// Destination for executing a session focus or stop action.
public enum SessionActionRoute: Equatable, Sendable {
  case managedCodex(stop: Bool)
  case bridge(EditorBridgeTarget, raiseWindowFirst: Bool)
  case localTerminalInterrupt
  case guiFocus
  case unsupported
}

/// Pure router deciding how a session action should be dispatched.
public enum SessionActionRouter {
  public static func route(
    action: String,
    session: SessionSnapshot,
    bridgeTarget: EditorBridgeTarget?
  ) -> SessionActionRoute {
    if session.hostInstanceId == "managed-codex" {
      if action == "focus" || action == "stop" {
        return .managedCodex(stop: action == "stop")
      }
      return .unsupported
    }
    if let bridgeTarget, action == "focus" || action == "stop" {
      return .bridge(bridgeTarget, raiseWindowFirst: action == "focus")
    }
    if action == "stop" {
      return .localTerminalInterrupt
    }
    if action == "focus" {
      return .guiFocus
    }
    return .unsupported
  }
}
