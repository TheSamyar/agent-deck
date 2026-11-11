import AppKit
import DeckCore
import IOKit.hid
import MasterHUBUSB

/// Independent connections for the three-knob and 240×240 screen-dial modules.
@MainActor final class MasterHUBAuxiliary {
  var knobInput: (MasterHUBEncoderEvent) -> Void = { _ in }
  var dialTurn: (Int) -> Void = { _ in }
  var dialFocus: (DeckSnapshot) -> Void = { _ in }
  private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
  private var knobs: IOHIDDevice?
  private var dial: IOHIDDevice?
  var checkDevices: [MasterHUBCheckDevice] {
    [masterHUBCheckDevice("Small dials", knobs), masterHUBCheckDevice("Screen dial", dial)]
  }
  private let knobBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
  private let dialBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
  private var knobDecoder = MasterHUBKnobDecoder()
  private var dialDecoder = MasterHUBScreenDialDecoder()
  private var latest: DeckSnapshot?
  private var shown: DeckSnapshot?
  private var pressedSnapshot: DeckSnapshot?
  private var holding = false
  private var heldKnobButtons = Set<Int>()
  var canSwitchConfiguration: Bool { !holding && heldKnobButtons.isEmpty && !writingDisplay && !changingTarget }
  private var robinState: String?
  func setRobinState(_ state: String?) { guard robinState != state else { return }; robinState = state; render() }
  var celebration: String?
  func showCompletion(_ title: String?) { celebration = title; render() }
  var handoffsMode = false
  var mediaMode = false
  var media = NowPlaying()
  var mediaPress: () -> Void = {}
  var mediaTurn: (Int) -> Void = { _ in }
  private var pressedMedia = false
  private var signature = ""
  private var writingDisplay = false
  private var changingTarget = false
  private var shownMedia = false
  private var phase: Double = 0
  func animate(_ value: Double, enabled: Bool) {
    let next = enabled ? value : 0
    if phase != next { phase = next; render() }
  }
  private(set) var knobState = "Not detected by macOS"
  private(set) var dialState = "Not detected by macOS"
  private var knobReports = 0, knobEvents = 0, dialReports = 0, dialEvents = 0
  private var displayFailures = 0
  private var lifetimeDisplayFailures = 0
  private var knobInitialization: Int32 = -1
  private var started = false
  var diagnostics: [String: Any] {
    ["knobsConnected": knobs != nil, "screenDialConnected": dial != nil,
      "mediaMode": mediaMode, "mediaPlaying": media.playing, "mediaArtworkBytes": media.artwork?.count ?? 0,
      "knobState": knobState, "screenDialState": dialState,
      "knobReports": knobReports, "knobEvents": knobEvents, "knobInitialization": knobInitialization,
      "screenDialReports": dialReports, "screenDialEvents": dialEvents,
      "screenDialDisplayFailures": displayFailures, "screenDialLifetimeDisplayFailures": lifetimeDisplayFailures]
  }
  func start() {
    guard !started else { return }
    started = true
    IOHIDManagerSetDeviceMatchingMultiple(manager, [
      [kIOHIDVendorIDKey: 0x2516, kIOHIDProductIDKey: 0x0202],
      [kIOHIDVendorIDKey: 0x2516, kIOHIDProductIDKey: 0x0206],
    ] as CFArray)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    _ = IOHIDManagerOpen(manager, 0)
    refresh()
  }
  func refresh() {
    guard started else { return }
    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    if let knobs, !devices.contains(knobs) { close(knobs); self.knobs = nil; knobDecoder.reset(); heldKnobButtons.removeAll(); knobState = "Not detected by macOS" }
    if let dial, !devices.contains(dial) { close(dial); self.dial = nil; resetDial(); dialState = "Not detected by macOS" }
    if knobs == nil {
      let candidates = devices.filter { product($0) == 0x0202 }
      if candidates.count == 1, let selected = candidates.first {
        if IOHIDDeviceOpen(selected, 0) == kIOReturnSuccess {
          knobs = selected; knobState = "Connected · turn a dial to test"
          var registryID: UInt64 = 0
          if IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(selected), &registryID) == KERN_SUCCESS {
            knobInitialization = DeckMasterHUBEnableInput(registryID)
          }
          IOHIDDeviceRegisterInputReportCallback(selected, knobBuffer, 4096, { context, result, _, _, _, report, length in
            guard let context else { return }
            let owner = Unmanaged<MasterHUBAuxiliary>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.receiveKnob(result, Array(UnsafeBufferPointer(start: report, count: length))) }
          }, Unmanaged.passUnretained(self).toOpaque())
          IOHIDDeviceScheduleWithRunLoop(selected, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        } else { knobState = "Cannot open · close other MasterHUB apps" }
      } else if candidates.count > 1 { knobState = "Multiple modules · connect one three-dial module" }
    }
    if dial == nil {
      let candidates = devices.filter { product($0) == 0x0206 }
      if candidates.count == 1, let selected = candidates.first {
        if IOHIDDeviceOpen(selected, 0) == kIOReturnSuccess {
          dial = selected
          IOHIDDeviceRegisterInputReportCallback(selected, dialBuffer, 4096, { context, result, _, _, _, report, length in
            guard let context else { return }
            let owner = Unmanaged<MasterHUBAuxiliary>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.receiveDial(result, Array(UnsafeBufferPointer(start: report, count: length))) }
          }, Unmanaged.passUnretained(self).toOpaque())
          IOHIDDeviceScheduleWithRunLoop(selected, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
          if mode(selected, enabled: true) {
            displayFailures = 0
            dialState = "Connected · turn to choose, press to focus"
          } else {
            close(selected); dial = nil; dialState = "Could not enable screen-dial software mode"
          }
        } else { dialState = "Cannot open · close other MasterHUB apps" }
      } else if candidates.count > 1 { dialState = "Multiple modules · connect one screen dial" }
    }
    render()
  }
  func stop() {
    if let knobs { close(knobs) }; knobs = nil; knobDecoder.reset(); heldKnobButtons.removeAll()
    if let dial { _ = mode(dial, enabled: false); close(dial) }; dial = nil; resetDial()
    knobState = "Not detected by macOS"; dialState = "Not detected by macOS"
  }
  func cancelHeldInputs() { pressedSnapshot = nil; holding = false; heldKnobButtons.removeAll() }
  func update(_ snapshot: DeckSnapshot?) { latest = snapshot; if !holding { render() } }
  private func product(_ device: IOHIDDevice) -> Int {
    (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
  }
  private func close(_ device: IOHIDDevice) {
    MasterHUBDisplays.invalidate(device)
    IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    IOHIDDeviceClose(device, 0)
  }
  private func mode(_ device: IOHIDDevice, enabled: Bool) -> Bool {
    var report = [UInt8](repeating: 0, count: 32)
    report[0] = 3; report[1] = 0x49; report[2] = enabled ? 1 : 0
    return report.withUnsafeBufferPointer {
      IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 3, $0.baseAddress!, $0.count) == kIOReturnSuccess
    }
  }
  private func resetDial() {
    signature = ""; shown = nil; pressedSnapshot = nil; holding = false; dialDecoder.reset()
  }
  private func receiveKnob(_ result: IOReturn, _ report: [UInt8]) {
    guard result == kIOReturnSuccess else { knobState = "Input error (\(result))"; return }
    knobReports += 1
    let events = knobDecoder.decode(report); knobEvents += events.count
    knobState = events.isEmpty ? "Input received · checking format" : "Working · \(knobEvents) events"
    for event in events {
      if case .button(let index, let down) = event {
        if down { heldKnobButtons.insert(index) } else { heldKnobButtons.remove(index) }
      }
      knobInput(event)
    }
  }
  private func receiveDial(_ result: IOReturn, _ report: [UInt8]) {
    guard result == kIOReturnSuccess else { dialState = "Input error (\(result))"; return }
    dialReports += 1
    let events = dialDecoder.decode(report); dialEvents += events.count
    dialState = events.isEmpty ? "Input received · checking format" : "Working · \(dialEvents) events"
    for event in events {
      switch event {
      case .rotated(_, let delta): if !holding { if mediaMode { mediaTurn(delta) } else { dialTurn(delta) } }
      case .button(_, true): if changingTarget { continue }; holding = true; pressedSnapshot = shown; pressedMedia = mediaMode
      case .button(_, false):
        if holding { if pressedMedia { mediaPress() } else if let captured = pressedSnapshot { dialFocus(captured) } }
        holding = false; pressedSnapshot = nil; render()
      }
    }
  }
  private func render() {
    guard !holding, !writingDisplay, let dial else { return }
    let presentation = MasterHUBDialPresentation(snapshot: latest, handoffs: handoffsMode)
    let next = mediaMode ? "media:\(media.trackID):\(media.title):\(media.artist):\(media.playing):\(media.artwork?.count ?? 0)" : String(describing: robinState) + String(describing: celebration) + String(describing: AgentVisualStyle.load(project: presentation.projectKey)) + String(MasterHUBArtwork.playful) + String(describing: presentation) + (["WORKING", "WAITING", "IDLE", "DONE"].contains(presentation.state) ? String(phase) : "")
    if next == signature { shown = latest; return }
    guard let jpeg = mediaMode ? MasterHUBArtwork.jpeg(media: media) : MasterHUBArtwork.jpeg(dial: presentation, phase: phase, celebration: celebration, robinState: robinState) else { return }
    let captured = latest
    let capturedMedia = mediaMode
    changingTarget = shown?.selectedSessionId != captured?.selectedSessionId || shownMedia != mediaMode
    writingDisplay = true
    if changingTarget { shown = nil }
    Task { [weak self] in
      let success = await MasterHUBDisplays.sendFrame([(jpeg, .screenDial)], device: dial)
      guard let self else { return }
      self.writingDisplay = false; self.changingTarget = false
      guard self.dial === dial else { return }
      if success { self.signature = next; self.shown = captured; self.shownMedia = capturedMedia }
      else { self.signature = ""; self.displayFailures += 1; self.lifetimeDisplayFailures += 1; self.dialState = "Screen transfer failed · reconnect module"; return }
      self.render()
    }
  }
}
