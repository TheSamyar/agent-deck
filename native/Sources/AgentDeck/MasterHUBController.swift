import AppKit
import ApplicationServices
import DeckCore
import IOKit.hid
import MasterHUBUSB

/// Owns the vendor HID interface on the main run loop; never seizes keyboards.
@MainActor final class MasterHUBController {
  private let auxiliary = MasterHUBAuxiliary()
  var checkDevices: [MasterHUBCheckDevice] {
    [masterHUBCheckDevice("Keypad", device), masterHUBCheckDevice("Rollers", rollerDevice)] + auxiliary.checkDevices
  }
  var mediaPress: () -> Void = {}
  var mediaTurn: (Int) -> Void = { _ in }
  func updateMedia(_ media: NowPlaying) { auxiliary.media = media; auxiliary.update(latest) }
  var knobInput: (MasterHUBEncoderEvent) -> Void = { _ in }
  var dialTurn: (Int) -> Void = { _ in }
  var dialFocus: (DeckSnapshot) -> Void = { _ in }
  var modulesChanged: ([String: String]) -> Void = { _ in }
  var rotate: (Int, Int) -> Void = { _, _ in }
  private var rollerDevice: IOHIDDevice?
  private let rollerBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
  private var inputErrors = 0
  private var lastInputError: IOReturn = 0
  private var keyReports = 0
  private var displayFailures = 0
  private var lifetimeDisplayFailures = 0
  private var rollerInitialization: Int32?
  private var rollerReports = 0
  private var rollerEvents = 0
  private var rollerState = "not connected"
  var status: (String) -> Void = { _ in }
  var activateSurface: (Int, MasterHUBSurfaceSnapshot, Int) -> Void = { _, _, _ in }
  // We own each device's open/close and report callback. Prevent the manager
  // from also scheduling/reconfiguring those same devices during enumeration.
  private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
  private var device: IOHIDDevice?
  private var decoder = MasterHUBKeyDecoder()
  private var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
  private var held: [Int: (Double, MasterHUBSurfaceSnapshot)] = [:]
  private var phase: Double = 0
  private var visualGeneration = 0
  private var feedback: [Int: (key: String, until: Double)] = [:]
  private var animationCursor = 0
  private var sleeping = false
  var allowsAnimation: Bool { !sleeping && !identifying && device != nil }
  private var animationEnabled = false
  func animate(_ value: Double, enabled: Bool) {
    animationEnabled = enabled && allowsAnimation
    auxiliary.animate(value, enabled: enabled && allowsAnimation)
    let next = enabled && allowsAnimation ? floor(value * 8) / 8 : 0
    if next != phase { phase = next; visualGeneration += 1; if held.isEmpty { renderSurface() } }
  }
  private var writingDisplay = false
  private var shown: MasterHUBSurfaceSnapshot?
  private var surface: MasterHUBSurfaceSnapshot?
  var identifying = false { didSet { artwork.removeAll(); cancelHeldInputs() } }
  private var latest: DeckSnapshot?
  private var artwork: [Int: String] = [:]
  private var timer: Timer?
  private var workspaceObservers: [NSObjectProtocol] = []

  func start() {
    auxiliary.knobInput = { [weak self] in self?.knobInput($0) }
    auxiliary.dialTurn = { [weak self] in self?.dialTurn($0) }
    auxiliary.dialFocus = { [weak self] in self?.dialFocus($0) }
    auxiliary.mediaPress = { [weak self] in self?.mediaPress() }
    auxiliary.mediaTurn = { [weak self] in self?.mediaTurn($0) }
    auxiliary.start()
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x2516] as CFDictionary)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    let result = IOHIDManagerOpen(manager, 0)
    guard result == kIOReturnSuccess else {
      status("MasterHUB: allow Input Monitoring for Agent Deck, then reopen it (\(result)).")
      return
    }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
      object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.sleeping = true; self?.detach() }
      })
    workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
      object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.sleeping = false; self?.refresh() }
      })
    workspaceObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
      object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.sleeping = true; self?.detach() }
      })
    refresh()
  }
  var canSwitchConfiguration: Bool { held.isEmpty && !writingDisplay && !identifying && auxiliary.canSwitchConfiguration }
  func cancelHeldInputs() { held.removeAll(); auxiliary.cancelHeldInputs(); renderSurface() }
  private var completionSessionID: String?
  private var completionStarted = 0.0
  func showCompletion(_ title: String?, sessionID: String? = nil) {
    visualGeneration += 1
    completionSessionID = title == nil ? nil : sessionID
    completionStarted = ProcessInfo.processInfo.systemUptime
    auxiliary.showCompletion(title); renderSurface()
  }
  private var robinState: String?
  func setRobinState(_ state: String?) {
    guard robinState != state else { return }; robinState = state; visualGeneration += 1
    auxiliary.setRobinState(state); renderSurface()
  }
  func updateSurface(_ layout: MasterHUBSurfaceSnapshot) {
    surface = layout
    auxiliary.handoffsMode = layout.page == .handoffs
    auxiliary.mediaMode = layout.page == .media
    if held.isEmpty { renderSurface() }
  }
  func update(_ snapshot: DeckSnapshot?) {
    latest = snapshot
    auxiliary.update(snapshot)

  }
  private func detachRollers() {
    if let rollerDevice {
      IOHIDDeviceUnscheduleFromRunLoop(rollerDevice, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
      IOHIDDeviceClose(rollerDevice, 0)
    }
    rollerDevice = nil
    rollerState = "not connected"
  }
  private func detach() {
    auxiliary.stop()
    detachRollers()
    if let device {
      MasterHUBDisplays.invalidate(device)
      _ = feature(false, device)
      IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
      IOHIDDeviceClose(device, 0)
    }
    device = nil
    held.removeAll()
    decoder.reset()
    shown = nil
    artwork.removeAll()
  }
  private func refresh() {
    guard !sleeping else { return }
    auxiliary.refresh()
    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    if let device, !devices.contains(device) { detach() }
    if let rollerDevice, !devices.contains(rollerDevice) { detachRollers() }
    if rollerDevice == nil {
      let rollers = devices.filter { (IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue == 0x0204 }
      if rollers.count == 1, let roller = rollers.first {
        let result = IOHIDDeviceOpen(roller, 0)
        if result == kIOReturnSuccess {
          rollerDevice = roller
          var registryID: UInt64 = 0
          if IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(roller), &registryID) == KERN_SUCCESS {
            rollerInitialization = DeckMasterHUBEnableInput(registryID)
          }
          rollerState = "listening; turn a roller to test"
          IOHIDDeviceRegisterInputReportCallback(roller, rollerBuffer, 4096, { context, result, _, _, _, report, length in
            guard let context else { return }
            let owner = Unmanaged<MasterHUBController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
              if result == kIOReturnSuccess { owner.receiveRoller(Array(UnsafeBufferPointer(start: report, count: length))) }
              else { owner.recordInputError(result) }
            }
          }, Unmanaged.passUnretained(self).toOpaque())
          IOHIDDeviceScheduleWithRunLoop(roller, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        } else { rollerState = "open failed (\(result))" }
      }
    }
    if device != nil { status("MasterHUB connected · rollers: \(rollerState)") }
    writeDiagnostics()
    guard device == nil else {
      if held.isEmpty { renderSurface() }
      return
    }
    // Select only the interface with a usable vendor image-output report.
    let candidates = devices.filter {
      (IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue == 0x01fe &&
      ((IOHIDDeviceGetProperty($0, kIOHIDMaxOutputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0) > 8
    }
    guard candidates.count == 1, let selected = candidates.first else {
      status(candidates.isEmpty ? "MasterHUB not connected" : "Multiple MasterHUB keypads: connect one keypad.")
      return
    }
    guard IOHIDDeviceOpen(selected, 0) == kIOReturnSuccess else {
      status("MasterHUB cannot open. Check Input Monitoring or close another MasterHUB app.")
      return
    }
    guard feature(true, selected) == kIOReturnSuccess else {
      IOHIDDeviceClose(selected, 0)
      status("MasterHUB could not enter software mode.")
      return
    }
    device = selected
    displayFailures = 0 // A reattached device starts a new connection-health interval.
    IOHIDDeviceRegisterInputReportCallback(selected, buffer, 4096, { context, result, _, _, _, report, length in
      guard let context else { return }
      let owner = Unmanaged<MasterHUBController>.fromOpaque(context).takeUnretainedValue()
      MainActor.assumeIsolated {
        if result == kIOReturnSuccess { owner.receive(Array(UnsafeBufferPointer(start: report, count: length))) }
        else { owner.recordInputError(result) }
      }
    }, Unmanaged.passUnretained(self).toOpaque())
    IOHIDDeviceScheduleWithRunLoop(selected, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    status("MasterHUB connected · rollers: \(rollerState)")
    renderSurface()
  }
  private func recordInputError(_ result: IOReturn) {
    inputErrors += 1
    lastInputError = result
    writeDiagnostics()
  }
  private func receiveRoller(_ report: [UInt8]) {
    rollerReports += 1
    let events = MasterHUBRollerDecoder.decode(report)
    rollerEvents += events.count
    rollerState = events.isEmpty ? "reports received; unknown format" : "working (\(rollerEvents) ticks)"
    for event in events { rotate(event.roller, event.delta) }
    status("MasterHUB connected · rollers: \(rollerState)")
    writeDiagnostics()
  }
  private func writeDiagnostics() {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/AgentDeck")
    var values: [String: Any] = ["inputBackend": "independent-devices",
      "inputErrors": inputErrors, "lastInputError": lastInputError, "keypadConnected": device != nil, "rollerConnected": rollerDevice != nil,
      "keyReports": keyReports, "displayedKeys": artwork.count, "displayFailures": displayFailures, "lifetimeDisplayFailures": lifetimeDisplayFailures,
      "inputMonitoringGranted": IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
      "accessibilityGranted": AXIsProcessTrusted(),
      "rollerReports": rollerReports, "rollerEvents": rollerEvents, "rollerState": rollerState]
    if let rollerInitialization { values["rollerInitialization"] = rollerInitialization }
    values["displayFrames"] = MasterHUBDisplays.frames
    values["lastFrameMilliseconds"] = MasterHUBDisplays.lastFrameMilliseconds
    values["maximumFrameMilliseconds"] = MasterHUBDisplays.maximumFrameMilliseconds
    values["surfaceTileCount"] = shown?.tiles.count ?? 0
    values["surfacePage"] = shown?.page.rawValue ?? "none"
    values["surfaceRevision"] = shown?.revision ?? 0
    values["orientation"] = shown?.orientation ?? 0
    values["identifying"] = identifying
    values["pid"] = ProcessInfo.processInfo.processIdentifier
    values["updatedAt"] = Date().timeIntervalSince1970
    values.merge(auxiliary.diagnostics) { _, updated in updated }
    modulesChanged([
      "15-key keypad": device == nil ? "Not detected by macOS" : "Connected · \(keyReports) reports",
      "2 rollers": rollerDevice == nil ? "Not detected by macOS" : rollerState,
      "3 dials": auxiliary.knobState, "Screen dial": auxiliary.dialState,
    ])
    if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
      try? data.write(to: directory.appendingPathComponent("masterhub-diagnostics.json"), options: .atomic)
    }
  }
  private func feature(_ enabled: Bool, _ device: IOHIDDevice) -> IOReturn {
    var bytes = [UInt8](repeating: 0, count: 32)
    bytes[0] = 3; bytes[1] = 0x3a; bytes[2] = enabled ? 1 : 0
    return bytes.withUnsafeBufferPointer {
      IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 3, $0.baseAddress!, $0.count)
    }
  }
  private func receive(_ report: [UInt8]) {
    keyReports += 1
    for event in decoder.decode(report) {
      if event.pressed, let shown {
        held[event.key] = (ProcessInfo.processInfo.systemUptime, shown)
      } else if !event.pressed, let press = held.removeValue(forKey: event.key),
        let logical = MasterHUBGeometry.logicalIndex(wire: event.key, rotation: press.1.orientation) {
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - press.0) * 1000)
        let tile = press.1.tiles[logical].tile
        if tile.enabled && tile.action != "none" {
          feedback[event.key] = (tile.target + "|" + tile.action, ProcessInfo.processInfo.systemUptime + 0.6)
          Task { [weak self] in
            for _ in 0..<5 {
              try? await Task.sleep(for: .milliseconds(200))
              self?.renderSurface()
            }
          }
        }
        activateSurface(logical, press.1, min(milliseconds, 60_000))
      }
    }
    if held.isEmpty { renderSurface() }
  }
  private func renderSurface() {
    guard !writingDisplay, held.isEmpty, let device, let surface else { return }
    let renderedGeneration = visualGeneration
    var images: [(Data, MasterHUBImageReports.Target)] = []
    var signatures = artwork
    let animationOnly = shown == surface && !identifying
    let indices = Array(surface.tiles.indices)
    let order = animationOnly ? Array(indices.dropFirst(animationCursor)) + Array(indices.prefix(animationCursor)) : indices
    for logical in order {
      let item = surface.tiles[logical]
      if animationOnly && phase != 0 && images.count >= 2 { break }
      guard let wire = MasterHUBGeometry.wireIndex(logical: logical, rotation: surface.orientation) else { continue }
      let tile = item.tile
      let celebrating = !identifying && tile.status == "DONE" && tile.target == completionSessionID
      let drawState = celebrating ? "CELEBRATE" : tile.status
      let drawPhase = celebrating ? (animationEnabled ? min(1, floor((ProcessInfo.processInfo.systemUptime - completionStarted) / 3 * 8) / 8) : 1) : phase
      let title = identifying ? "Key \(logical + 1)" : tile.label
      let subtitle = identifying ? "Identify" : tile.sublabel
      let highlighted = feedback[wire].map { $0.until > ProcessInfo.processInfo.systemUptime && $0.key == tile.target + "|" + tile.action } ?? false
      let robinKey = item.binding?.kind == .supervisor
      let signature = [robinKey ? (robinState ?? "Ready") + String(phase) : "", String(highlighted), item.agentId ?? "", String(describing: AgentVisualStyle.load(project: item.characterKey ?? title)), String(describing: item.work), String(MasterHUBArtwork.playful), title, subtitle, drawState, item.symbol, String(surface.orientation), String(tile.enabled), String(describing: item.binding), (["WORKING", "WAITING", "CLEAR", "CELEBRATE"].contains(drawState) || (item.agentId != nil && ["IDLE", "DONE"].contains(tile.status))) ? String(drawPhase) : "0"].joined(separator: "\n")
      if artwork[wire] == signature { continue }
      guard let jpeg = MasterHUBArtwork.jpeg(title: title, subtitle: subtitle, state: drawState,
        size: 72, symbol: identifying ? "hand.point.up" : item.symbol, rotation: surface.orientation, enabled: identifying || tile.enabled,
        appIcon: identifying ? nil : robinKey ? RobinArtwork.image(state: robinState ?? "Ready", phase: phase) : MasterHUBAppIcon.image(for: item.binding), phase: drawPhase, work: item.work, characterProject: item.characterKey, agentId: item.agentId ?? "", highlighted: highlighted) else { return }
      images.append((jpeg, .key(wire))); signatures[wire] = signature
      if animationOnly { animationCursor = (logical + 1) % max(1, surface.tiles.count) }
    }
    if images.isEmpty { shown = surface; return }
    writingDisplay = true
    if shown != surface { shown = nil }
    Task { [weak self] in
      let success = await MasterHUBDisplays.sendFrame(images, device: device)
      guard let self else { return }
      self.writingDisplay = false
      guard self.device === device else { return }
      if success { self.artwork = signatures; self.shown = surface }
      else { self.artwork.removeAll(); self.displayFailures += 1; self.lifetimeDisplayFailures += 1; self.status("MasterHUB display update failed. Open device checks for details."); return }
      if self.surface != surface || self.visualGeneration != renderedGeneration { self.renderSurface() }
    }
  }
}
