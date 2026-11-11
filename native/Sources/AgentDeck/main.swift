import AppKit
import Darwin
import ApplicationServices
import DeckCore
import ServiceManagement
import Sparkle
import SwiftUI
import WebKit
import UserNotifications

@MainActor final class DeckModel: ObservableObject {
  @Published var identifyingMasterHUB = false { didSet { masterhub?.identifying = identifyingMasterHUB } }
  @Published private(set) var masterhubConfiguration = MasterHUBConfigurationStore.load()
  @Published private(set) var masterhubProfiles = MasterHUBProfileLibrary()
  @Published private(set) var activeMasterHUBProfileID: UUID?
  @Published private(set) var masterhubProfileStatus = "Automatic profiles are off."
  @Published private(set) var profileFrontmostBundleID: String?
  @Published private(set) var profileFrontmostName = "Switch to an app, then return here"
  private var masterhubProfileStore: MasterHUBProfileStore?
  private var profileWorkspaceObserver: NSObjectProtocol?
  private var profileActivationTask: Task<Void, Never>?
  private var pendingProfileSelection = false
  private var manualProfileSelectionPending = false
  private var pendingManualProfileID: UUID?
  private var profileUndo: (id: UUID, configuration: MasterHUBConfiguration)?

  @Published private(set) var masterhubLayout: MasterHUBSurfaceSnapshot?
  @Published var checkingMasterHUBControls = false
  @Published private(set) var activeMasterHUBControl: String?
  @Published private(set) var confirmedMasterHUBControls: Set<String> = []
  private var inputHighlightGeneration = 0
  @Published private(set) var observedMasterHUBControls: Set<String> = []
  @Published private(set) var actionObservedMasterHUBControls: Set<String> = []
  @Published private(set) var masterhubCheckStartedAt = Date()
  private var hardwareCheckSaveTask: Task<Void, Never>?
  @Published private(set) var verifiedMasterHUBControls: Set<String> = []
  @Published var masterhubFeedback = ""
  private var masterhubSurface = MasterHUBSurface()
  @Published var identifiedControl = "Turn or press a control"
  @Published var masterhubModules: [String: String] = [:]
  private var rotaryControls: MasterHUBRotaryControls { masterhubConfiguration.rotaries }
  private var pendingDialDelta = 0
  private var dialSelectionTask: Task<Void, Never>?
  @Published private(set) var nowPlaying = NowPlaying()
  let displayClock = MasterHUBDisplayClock()
  private var completionTask: Task<Void, Never>?
  private var animationTask: Task<Void, Never>?
  private var mediaPolling: Task<Void, Never>?
  @Published var masterhubStatus = "Detecting MasterHUB…"
  private var instanceLock: Int32 = -1
  private var masterhub: MasterHUBController?
  @Published var snapshot: DeckSnapshot? { didSet { menuBarAttention.update(waitingCount: waitingCount) } }
  let menuBarAttention = MenuBarAttentionState()
  @Published var connected = false
  @Published private(set) var serviceAccessibilityGranted: Bool?
  private var serviceReadinessGeneration = 0
  @Published var message = "Connecting to Agent Deck…"
  @Published var search = ""
  @Published var section = (CommandLine.arguments.contains("--supervisor") || CommandLine.arguments.contains("--open-robin")) ? "Supervisor" : "MasterHUB"
  @Published var selectedSession: String?
  @Published var showCodex = false
  @Published var showSetup = !UserDefaults.standard.bool(forKey: "setupCompleted")
  @Published var installing = false
  @Published var installationMessage = ""
  @Published var installationSucceeded = false
  @Published private(set) var integrationConfiguration: [String: IntegrationConfigurationState] = [:]
  @Published var actionInFlight = false
  @Published var pendingConfirmation: ActionCommand?
  @Published var confirmText = ""
  @Published private var draftPreferences: DeckPreferences?
  private var preferencesTask: Task<Void, Never>?
  private var preferenceRevision = 0
  private var token = ""
  private var port = 19420
  lazy var supervisor = SupervisorStore(deck: self)
  private var stream: Task<Void, Never>?
  private var service: Process?
  private var startingService = false
  private var seenRequests: Set<String> = []
  private let guiControlClient = NativeGUIControlClient()
  private var updater: SPUStandardUpdaterController?
  private(set) var privateUpdates: PrivateUpdateController?
  var updatesConfigured: Bool { updater != nil || privateUpdates != nil }
  func openDemo() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = ["--demo"]; configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
      if let error { Task { @MainActor in self?.message = "Could not open demo: \(error.localizedDescription)" } }
    }
  }
  func checkForUpdates() {
    if let privateUpdates { Task { await privateUpdates.check(manual: true) } }
    else { updater?.checkForUpdates(nil) }
  }

  var preferences: DeckPreferences { draftPreferences ?? snapshot?.preferences ?? .init() }
  var allSessions: [SessionSnapshot] {
    (snapshot?.sessions.values.sorted { $0.startedAt < $1.startedAt } ?? []).filter {
      search.isEmpty || $0.workspace.localizedCaseInsensitiveContains(search)
        || $0.agentName.localizedCaseInsensitiveContains(search)
    }
  }
  var observedSessionCount: Int {
    snapshot?.sessions.values.filter { $0.status != .disconnected && $0.status != .unknown }.count ?? 0
  }
  var requests: [PendingRequest] { snapshot?.requests ?? [] }
  var waitingCount: Int { snapshot?.summary.waitingCount ?? 0 }
  var runtime: URL {
    URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["AGENT_DECK_RUNTIME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          "Library/Caches/AgentDeck"
        ).path)
  }
  init(previewSnapshot: DeckSnapshot? = nil) {
    if let previewSnapshot {
      snapshot = previewSnapshot; connected = true; showSetup = false
      nowPlaying = MasterHUBDemoMedia.state
      masterhubConfiguration = .init()
      masterhubModules = ["15-key keypad": "Input verified", "2 rollers": "Connected · input pending",
        "3 dials": "Input verified", "Screen dial": "Input verified"]
      masterhubStatus = "Preview fixture"
      refreshMasterHUB()
      return
    }
    if UserDefaults.standard.string(forKey: "masterhubVisualTheme") == nil {
      let existing = UserDefaults.standard.object(forKey: "setupCompleted") != nil || UserDefaults.standard.data(forKey: "masterhubConfiguration.v2") != nil
      UserDefaults.standard.set(existing ? "classic" : "playful", forKey: "masterhubVisualTheme")
    }
    // A helper inside this bundle is also returned by NSRunningApplication.
    // Lock only the GUI process; do not mistake deck-service for a second window.
    try? FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    instanceLock = Darwin.open(runtime.appendingPathComponent("agentdeck-ui.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard instanceLock >= 0 else { message = "Cannot open the app instance lock."; return }
    if flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
      DistributedNotificationCenter.default().postNotificationName(
        .init("com.aiagentdeck.showMainWindow"), object: nil, deliverImmediately: true)
      if let identifier = Bundle.main.bundleIdentifier,
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
          .first(where: { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && $0.executableURL?.lastPathComponent == "AgentDeck" }) {
        existing.activate(options: [])
      }
      exit(0)
    }
    if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil,
      Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil
    {
      if let updates = PrivateUpdateController() {
        privateUpdates = updates
        updates.onStatus = { [weak self] value in self?.message = value }
        updates.mayRelaunch = { [weak self] in
          guard let self else { return false }
          return PrivateUpdateRestartPolicy.canRestart(connected: self.connected, pendingRequestCount: self.requests.count,
            busy: self.supervisor.busy, tasks: self.supervisor.tasks,
            managedSessions: self.snapshot.map { Array($0.sessions.values) } ?? [], processIsAlive: PrivateUpdateController.taskProcessIsAlive)
        }
        DeckAppDelegate.mayTerminate = { [weak updates] in
          guard let updates else { return true }
          return !updates.installationMayBePending || updates.mayRelaunch?() == true
        }
        DeckAppDelegate.onTerminate = { [weak updates] in updates?.shutdown() }
        updates.start()
      } else {
        updater = SPUStandardUpdaterController(
          startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
      }
    }
    let hub = MasterHUBController()
    hub.status = { [weak self] value in
      if self?.masterhubStatus != value { self?.masterhubStatus = value }
    }
    hub.activateSurface = { [weak self] key, displayed, held in
      guard let self else { return }
      self.observeMasterHUBControl("Key \(key + 1)")
      if self.identifyingMasterHUB { return }
      self.pressMasterHUBKey(key, displayed: displayed, heldMs: held)
    }
    hub.modulesChanged = { [weak self] modules in
      if self?.masterhubModules != modules { self?.masterhubModules = modules }
    }
    hub.rotate = { [weak self] index, delta in
      guard let self else { return }
      self.observeMasterHUBControl("Roller \(index + 1)", input: delta > 0 ? "Turn forward" : "Turn backward")
      if self.identifyingMasterHUB { return }
      self.rotaryTurn(index, delta: delta)
    }
    hub.knobInput = { [weak self] event in
      guard let self else { return }
      switch event {
      case .rotated(let index, let delta): self.observeMasterHUBControl("Dial \(index + 1)", input: delta > 0 ? "Turn right" : "Turn left")
      case .button(let index, true): self.observeMasterHUBControl("Dial \(index + 1)", input: "Press")
      case .button(_, false): break
      }
      guard !self.identifyingMasterHUB else { return }
      switch event {
      case .rotated(let index, let delta): self.rotaryTurn(index + 2, delta: delta)
      case .button(let index, true): self.rotaryPress(index + 2)
      default: break
      }
    }
    hub.dialTurn = { [weak self] delta in
      self?.observeMasterHUBControl("Screen dial", input: delta > 0 ? "Turn right" : "Turn left")
      if self?.identifyingMasterHUB == true { return }
      self?.turnSelectedAgent(delta)
    }
    hub.dialFocus = { [weak self] displayed in
      self?.observeMasterHUBControl("Screen dial", input: "Press")
      if self?.identifyingMasterHUB == true { return }
      guard let self, self.connected, displayed.instanceId == self.snapshot?.instanceId else { return }
      guard !displayed.selectedSessionId.isEmpty else {
        self.message = "Turn the screen dial to choose an agent first."; return
      }
      self.perform(.init(action: "focus", sessionId: displayed.selectedSessionId, revision: displayed.revision))
    }
    hub.mediaPress = { [weak self] in
      guard let self, !self.identifyingMasterHUB else { return }
      self.runMediaControl("playpause")
    }
    hub.mediaTurn = { [weak self] delta in
      guard let self, !self.identifyingMasterHUB else { return }
      self.adjustMacAudio(delta: Float(delta) * 0.05)
    }
    masterhub = hub
    startMasterHUBProfiles()
    animationTask = Task { [weak self] in
      var tick = 0
      while !Task.isCancelled {
        if let self {
          self.applyPendingMasterHUBProfileIfSafe()
          let animated = self.displayClock.celebration != nil || self.displayClock.robinState != nil || (self.section == "Supervisor" && (self.supervisor.localConversation || self.supervisor.realtime.active || self.supervisor.busy)) || self.masterhubLayout?.page != .media && self.masterhubLayout?.tiles.contains(where: { ["WORKING", "WAITING", "CLEAR"].contains($0.tile.status) || ($0.agentId != nil && ["IDLE", "DONE"].contains($0.tile.status)) }) == true
          let robinState = self.supervisor.deviceState
          if self.displayClock.robinState != robinState { self.displayClock.robinState = robinState; self.masterhub?.setRobinState(robinState) }
          let enabled = animated && self.masterhubConfiguration.motion != false && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !self.preferences.reduceMotion && !self.identifyingMasterHUB
          let phase = enabled && self.masterhub?.allowsAnimation == true ? Double(tick % 16) / 16 : 0
          let keyPhase = floor(phase * 8) / 8
          if self.displayClock.keys.phase != keyPhase { self.displayClock.keys.phase = keyPhase }
          if (tick % 2 == 0 || phase == 0) && self.displayClock.phase != phase { self.displayClock.phase = phase }
          self.masterhub?.animate(phase, enabled: enabled)
        }
        tick += 1
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
    mediaPolling = Task { [weak self] in
      while !Task.isCancelled {
        if let self, self.masterhubLayout?.page == .media {
          let state = await SpotifyControl.nowPlaying()
          if self.nowPlaying != state { self.nowPlaying = state; self.masterhub?.updateMedia(state); self.refreshMasterHUB() }
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }
    // Defer AppKit hardware rendering until SwiftUI finishes constructing the app.
    DispatchQueue.main.async { [weak self, weak hub] in
      self?.refreshMasterHUB(); hub?.start()
    }
    guiControlClient.start(runtime: runtime)
    stream = Task { await connect() }
  }
  private func endpoint() -> Bool {
    guard let data = try? Data(contentsOf: runtime.appendingPathComponent("connection.json")),
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let token = value["token"] as? String, let port = value["port"] as? Int
    else { return false }
    if self.token != token || self.port != port {
      serviceReadinessGeneration += 1
      serviceAccessibilityGranted = nil
    }
    self.token = token
    self.port = port
    return true
  }
  private func startService() {
    guard !startingService, service?.isRunning != true else { return }
    startingService = true
    let uid = getuid()
    Task { [weak self] in
      let launchdManaged = await Task.detached(priority: .utility) { () -> Bool in
        // launchd already owns installed services. A transient reconnect must not
        // create another daemon with a different port/token and overwrite connection.json.
        let managed = Process()
        managed.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        managed.arguments = ["print", "gui/\(uid)/com.aiagentdeck.service"]
        managed.standardOutput = FileHandle.nullDevice
        managed.standardError = FileHandle.nullDevice
        guard (try? managed.run()) != nil else { return false }
        managed.waitUntilExit()
        return managed.terminationStatus == 0
      }.value
      guard let self else { return }
      defer { self.startingService = false }
      guard !launchdManaged, self.service?.isRunning != true else { return }
      let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DeckService.bundle/Contents/MacOS/deck-service")
      guard FileManager.default.isExecutableFile(atPath: url.path) else {
        self.message = "Build and install the native service to connect."
        return
      }
      let process = Process()
      process.executableURL = url
      var env = ProcessInfo.processInfo.environment
      env["AGENT_DECK_APP"] = Bundle.main.bundlePath
      env["AGENT_DECK_PORT"] = String(self.port)
      env["AGENT_DECK_RUNTIME"] = self.runtime.path
      process.environment = env
      let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Logs/AgentDeck-service.log")
      if !FileManager.default.fileExists(atPath: log.path) {
        FileManager.default.createFile(atPath: log.path, contents: nil)
      }
      if let handle = try? FileHandle(forWritingTo: log) {
        _ = try? handle.seekToEnd()
        process.standardOutput = handle
        process.standardError = handle
      }
      do {
        try process.run()
        self.service = process
      } catch { self.message = error.localizedDescription }
    }
  }
  private func connect() async {
    var delay = 1
    while !Task.isCancelled {
      if !endpoint() {
        startService()
        try? await Task.sleep(for: .seconds(1))
        continue
      }
      do {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/events")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 86_400
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
          throw URLError(.userAuthenticationRequired)
        }
        connected = true
        Task { await refreshServiceReadiness() }
        delay = 1
        message = ""
        for try await line in bytes.lines where line.hasPrefix("data: ") {
          let update = try JSONDecoder().decode(
            DeckSnapshot.self, from: Data(line.dropFirst(6).utf8))
          if snapshot?.instanceId == update.instanceId, let previous = snapshot?.stateVersion,
            let incoming = update.stateVersion, incoming < previous { continue }
          if snapshot?.instanceId != update.instanceId {
            serviceReadinessGeneration += 1
            serviceAccessibilityGranted = nil
            Task { await refreshServiceReadiness() }
          }
          let completions = RobinCompletion.fresh(previous: snapshot, current: update)
          let needsAttention = update.sessions.values.contains { [.waiting, .error].contains($0.status) && update.preferences.enabledAgents.contains($0.agentId) } || update.requests.contains { $0.state == "pending" && $0.expiresAt > DeckClock.now }
          if needsAttention, displayClock.celebration != nil {
            completionTask?.cancel(); displayClock.celebration = nil; masterhub?.showCompletion(nil)
          }
          if !needsAttention, let completion = completions.last {
            completionTask?.cancel()
            let project = update.preferences.projectNames[completion.projectKey] ?? completion.workspace
            displayClock.celebration = project; masterhub?.showCompletion(project, sessionID: completion.id)
            completionTask = Task { [weak self] in
              do { try await Task.sleep(for: .seconds(3)) } catch { return }
              self?.displayClock.celebration = nil; self?.masterhub?.showCompletion(nil)
            }
          }
          for completion in completions {
            let project = update.preferences.projectNames[completion.projectKey] ?? completion.workspace
            supervisor.announceCompletion(project: project, detail: completion.detail)
          }
          notify(update)
          if let action = update.lastAction,
            action.commandId != snapshot?.lastAction?.commandId
              || action.message != snapshot?.lastAction?.message
          {
            message = action.message
          } else if !update.lastError.isEmpty {
            message = update.lastError
          } else if let previousError = snapshot?.lastError, !previousError.isEmpty,
            message == previousError {
            message = ""
          }
          if draftPreferences == update.preferences { draftPreferences = nil }
          snapshot = update
          refreshMasterHUB()
        }
        throw URLError(.networkConnectionLost)
      } catch {
        connected = false
        serviceReadinessGeneration += 1
        serviceAccessibilityGranted = nil
        refreshMasterHUB()
        message = "Deck disconnected. Reconnecting…"
        startService()
        try? await Task.sleep(for: .seconds(delay))
        delay = min(8, delay * 2)
      }
    }
  }
  private func notify(_ update: DeckSnapshot) {
    let fresh = update.requests.filter { !seenRequests.contains($0.id) }
    seenRequests.formUnion(update.requests.map(\.id))
    guard update.preferences.notifications, !NSApplication.shared.isActive else { return }
    for request in fresh {
      let session = update.sessions[request.sessionId]
      guard !update.preferences.mutedProjects.contains(session?.projectKey ?? "") else { continue }
      let content = UNMutableNotificationContent()
      content.title = "An agent needs you"
      content.body =
        update.preferences.showSensitiveNotifications
        ? "\(session?.workspace ?? "Project"): \(request.title)"
        : "Open Agent Deck to review the request."
      UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }
  }
  var activeMasterHUBProfileName: String {
    masterhubProfiles.profiles.first { $0.id == activeMasterHUBProfileID }?.name ?? "Default"
  }
  var canUndoMasterHUBConfiguration: Bool {
    if let id = activeMasterHUBProfileID { return profileUndo?.id == id }
    return MasterHUBConfigurationStore.hasUndo
  }
  private var canSwitchMasterHUBProfile: Bool {
    MasterHUBProfileSwitchContext(identifying: identifyingMasterHUB, checking: checkingMasterHUBControls,
      actionInFlight: actionInFlight, confirmationPending: pendingConfirmation != nil,
      requestPending: requests.contains { $0.state == "pending" && $0.expiresAt > DeckClock.now },
      deviceBusy: masterhub?.canSwitchConfiguration == false).canSwitch
  }
  private func startMasterHUBProfiles() {
    let store = MasterHUBProfileStore(); masterhubProfileStore = store; masterhubProfiles = store.library
    if let error = store.loadError { masterhubProfileStatus = error }
    profileWorkspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
      object: nil, queue: .main) { [weak self] notification in
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated { self?.profileApplicationActivated(app) }
    }
    profileApplicationActivated(NSWorkspace.shared.frontmostApplication)
  }
  private func profileApplicationActivated(_ app: NSRunningApplication?) {
    guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
    profileFrontmostBundleID = app?.bundleIdentifier.flatMap { MasterHUBProfileLibrary.validBundleID($0) ? $0 : nil }
    profileFrontmostName = app?.localizedName ?? "Unknown app"
    profileActivationTask?.cancel()
    guard masterhubProfiles.automaticEnabled else { return }
    profileActivationTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
      guard let self, self.masterhubProfiles.automaticEnabled else { return }
      self.pendingProfileSelection = true; self.applyPendingMasterHUBProfileIfSafe()
    }
  }
  private func applyPendingMasterHUBProfileIfSafe() {
    guard manualProfileSelectionPending || (pendingProfileSelection && masterhubProfiles.automaticEnabled) else { return }
    guard canSwitchMasterHUBProfile else {
      if masterhubProfileStatus != "Profile switching waits for editing, held controls or pending agent decisions." {
        masterhubProfileStatus = "Profile switching waits for editing, held controls or pending agent decisions."
      }
      return
    }
    if manualProfileSelectionPending {
      manualProfileSelectionPending = false; pendingProfileSelection = false
      let selected = masterhubProfiles.profiles.first { $0.id == pendingManualProfileID }
      applyMasterHUBProfile(selected?.id, configuration: selected?.configuration ?? MasterHUBConfigurationStore.load())
      masterhubProfileStatus = "Using \(selected?.name ?? "Default") · automatic switching paused."
      return
    }
    pendingProfileSelection = false
    let selected = masterhubProfiles.profile(for: profileFrontmostBundleID)
    applyMasterHUBProfile(selected?.id, configuration: selected?.configuration ?? MasterHUBConfigurationStore.load())
    masterhubProfileStatus = selected == nil ? "No app assignment · using Default." : "Using \(selected!.name) for \(profileFrontmostName)."
  }
  @discardableResult private func persistMasterHUBProfiles(_ value: MasterHUBProfileLibrary) -> Bool {
    do {
      guard let store = masterhubProfileStore else { throw MasterHUBProfileFailure("Profiles are unavailable in preview mode.") }
      try store.save(value); masterhubProfiles = value; return true
    } catch { masterhubProfileStatus = error.localizedDescription; return false }
  }
  func setAutomaticMasterHUBProfiles(_ enabled: Bool) {
    var value = masterhubProfiles; value.automaticEnabled = enabled
    guard persistMasterHUBProfiles(value) else { return }
    profileActivationTask?.cancel(); pendingProfileSelection = enabled; manualProfileSelectionPending = false
    masterhubProfileStatus = enabled ? "Waiting for the current app profile." : "Automatic switching paused; current profile stays selected."
    if enabled { applyPendingMasterHUBProfileIfSafe() }
  }
  @discardableResult func captureMasterHUBProfile(name: String) -> UUID? {
    let profile = MasterHUBApplicationProfile(name: name, configuration: masterhubConfiguration)
    guard !profile.name.isEmpty else {
      masterhubProfileStatus = "Enter a profile name."; return nil
    }
    guard profile.name.count <= 80 else {
      masterhubProfileStatus = "Profile names must be 80 characters or fewer."; return nil
    }
    guard masterhubProfiles.profiles.count < 32 else {
      masterhubProfileStatus = "You can save up to 32 profiles. Delete one before saving another."; return nil
    }
    let folded = profile.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    guard !masterhubProfiles.profiles.contains(where: {
      $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) == folded
    }) else {
      masterhubProfileStatus = "A profile named “\(profile.name)” already exists."; return nil
    }
    var value = masterhubProfiles; value.profiles.append(profile)
    guard persistMasterHUBProfiles(value) else { return nil }
    masterhubProfileStatus = "Saved \(profile.name) from the current assignments."; return profile.id
  }
  func renameMasterHUBProfile(_ id: UUID, name: String) -> Bool {
    do {
      let updated = try masterhubProfiles.renamingProfile(id, to: name)
      guard persistMasterHUBProfiles(updated) else { return false }
      let savedName = updated.profiles.first { $0.id == id }?.name ?? name
      masterhubProfileStatus = "Profile renamed to \(savedName)."
      return true
    } catch {
      masterhubProfileStatus = error.localizedDescription
      return false
    }
  }
  func assignMasterHUBProfile(_ id: UUID, bundleID: String) {
    guard bundleID != (Bundle.main.bundleIdentifier ?? "com.aiagentdeck.app"),
      masterhubProfiles.profiles.contains(where: { $0.id == id }), MasterHUBProfileLibrary.validBundleID(bundleID) else {
      masterhubProfileStatus = "Choose a saved profile and an exact application bundle ID."; return
    }
    var value = masterhubProfiles; value.assignments[bundleID] = id
    guard persistMasterHUBProfiles(value) else { return }
    masterhubProfileStatus = "Application assignment saved."
    if value.automaticEnabled { pendingProfileSelection = true; applyPendingMasterHUBProfileIfSafe() }
  }
  func unassignMasterHUBProfile(bundleID: String) {
    let updated = masterhubProfiles.unassigningBundleID(bundleID)
    guard updated != masterhubProfiles else { return }
    guard persistMasterHUBProfiles(updated) else { return }
    masterhubProfileStatus = "Removed assignment for \(bundleID)."
    if updated.automaticEnabled { pendingProfileSelection = true; applyPendingMasterHUBProfileIfSafe() }
  }
  func selectMasterHUBProfile(_ id: UUID?) {
    let profile = masterhubProfiles.profiles.first { $0.id == id }
    guard id == nil || profile != nil else { return }
    var value = masterhubProfiles; value.automaticEnabled = false
    guard persistMasterHUBProfiles(value) else { return }
    profileActivationTask?.cancel(); pendingProfileSelection = false
    pendingManualProfileID = id; manualProfileSelectionPending = true
    masterhubProfileStatus = "Waiting to select \(profile?.name ?? "Default") safely · automatic switching paused."
    applyPendingMasterHUBProfileIfSafe()
  }
  func replaceMasterHUBProfile(_ id: UUID) {
    guard let index = masterhubProfiles.profiles.firstIndex(where: { $0.id == id }) else { return }
    var value = masterhubProfiles; value.profiles[index].configuration = masterhubConfiguration
    guard persistMasterHUBProfiles(value) else { return }
    masterhubProfileStatus = "Saved profile snapshot replaced with the current assignments."
  }
  func deleteMasterHUBProfile(_ id: UUID) {
    guard canSwitchMasterHUBProfile else { masterhubProfileStatus = "Finish editing, held controls and pending decisions before deleting profiles."; return }
    var value = masterhubProfiles; value.profiles.removeAll { $0.id == id }; value.assignments = value.assignments.filter { $0.value != id }
    if activeMasterHUBProfileID == id { value.automaticEnabled = false }
    guard persistMasterHUBProfiles(value) else { return }
    if activeMasterHUBProfileID == id { applyMasterHUBProfile(nil, configuration: MasterHUBConfigurationStore.load()) }
    if profileUndo?.id == id { profileUndo = nil }
    masterhubProfileStatus = "Profile deleted; Default and other profiles were preserved."
  }
  func exportMasterHUBProfiles() -> Data? {
    do {
      let data = try masterhubProfiles.exportData()
      let count = masterhubProfiles.profiles.count
      masterhubProfileStatus = "Exported \(count) saved profile\(count == 1 ? "" : "s")."
      return data
    } catch {
      masterhubProfileStatus = error.localizedDescription
      return nil
    }
  }
  func importMasterHUBProfiles(_ data: Data) {
    do {
      let imported = try MasterHUBProfileLibrary.decodeImport(data)
      let merged = try masterhubProfiles.addingRecoveredProfiles(imported)
      guard persistMasterHUBProfiles(merged) else { return }
      profileActivationTask?.cancel(); pendingProfileSelection = false; manualProfileSelectionPending = false
      masterhubProfileStatus = "Recovered profiles imported additively. Conflicting snapshots received new names; existing assignments were preserved. Automatic switching is off."
    } catch { masterhubProfileStatus = error.localizedDescription }
  }
  private func applyMasterHUBProfile(_ id: UUID?, configuration: MasterHUBConfiguration) {
    guard activeMasterHUBProfileID != id || masterhubConfiguration != configuration else { return }
    dialSelectionTask?.cancel(); pendingDialDelta = 0; masterhub?.cancelHeldInputs()
    activeMasterHUBProfileID = id; masterhubConfiguration = configuration
    verifiedMasterHUBControls.removeAll(); confirmedMasterHUBControls.removeAll(); actionObservedMasterHUBControls.removeAll()
    refreshMasterHUB()
  }
  func applyMasterHUBConfiguration(_ value: MasterHUBConfiguration) {
    guard value.valid else { masterhubFeedback = "Check the highlighted assignments before applying."; return }
    if let id = activeMasterHUBProfileID, let index = masterhubProfiles.profiles.firstIndex(where: { $0.id == id }) {
      var updated = masterhubProfiles; updated.profiles[index].configuration = value
      guard persistMasterHUBProfiles(updated) else { masterhubFeedback = masterhubProfileStatus; return }
      profileUndo = (id, masterhubConfiguration)
    } else {
      guard MasterHUBConfigurationStore.save(value) else { masterhubFeedback = "The default setup could not be saved."; return }
    }
    masterhubConfiguration = value; masterhub?.cancelHeldInputs()
    verifiedMasterHUBControls.removeAll(); confirmedMasterHUBControls.removeAll(); actionObservedMasterHUBControls.removeAll()
    identifyingMasterHUB = false; refreshMasterHUB()
    masterhubFeedback = "Applied to \(activeMasterHUBProfileName)."
  }
  func undoMasterHUBConfiguration() {
    if let id = activeMasterHUBProfileID {
      guard let undo = profileUndo, undo.id == id, let index = masterhubProfiles.profiles.firstIndex(where: { $0.id == id }) else { return }
      var updated = masterhubProfiles; updated.profiles[index].configuration = undo.configuration
      guard persistMasterHUBProfiles(updated) else { return }
      masterhubConfiguration = undo.configuration; profileUndo = nil
    } else {
      guard let previous = MasterHUBConfigurationStore.undo() else { return }; masterhubConfiguration = previous
    }
    verifiedMasterHUBControls.removeAll(); confirmedMasterHUBControls.removeAll(); actionObservedMasterHUBControls.removeAll()
    identifyingMasterHUB = false; masterhub?.cancelHeldInputs(); refreshMasterHUB()
    masterhubFeedback = "Previous \(activeMasterHUBProfileName) assignments restored."
  }
  func confirmMasterHUBControl(_ name: String, confirmed: Bool) {
    guard checkingMasterHUBControls, actionObservedMasterHUBControls.contains(name), !identifyingMasterHUB else { return }
    if confirmed { confirmedMasterHUBControls.insert(name) } else { confirmedMasterHUBControls.remove(name) }
    persistMasterHUBCheck()
  }
  func observeMasterHUBControl(_ name: String, input: String? = nil) {
    observedMasterHUBControls.insert(name)
    if let input { observedMasterHUBControls.insert("\(name) · \(input)") }
    if checkingMasterHUBControls && !identifyingMasterHUB {
      actionObservedMasterHUBControls.insert(input.map { "\(name) · \($0)" } ?? name)
    }
    inputHighlightGeneration += 1
    let generation = inputHighlightGeneration
    activeMasterHUBControl = name
    Task {
      try? await Task.sleep(for: .milliseconds(200))
      if generation == inputHighlightGeneration { activeMasterHUBControl = nil }
    }
    if identifyingMasterHUB { identifiedControl = name }
    if checkingMasterHUBControls { persistMasterHUBCheck() }
  }
  func beginMasterHUBCheck() {
    masterhubCheckStartedAt = Date()
    observedMasterHUBControls.removeAll(); actionObservedMasterHUBControls.removeAll()
    confirmedMasterHUBControls.removeAll()
    checkingMasterHUBControls = true; identifyingMasterHUB = true
    masterhubFeedback = "New check started. Identify all 31 inputs, then test assigned actions."
    persistMasterHUBCheck()
  }
  private func masterHUBCheckEvidence() -> MasterHUBCheckEvidence {
    MasterHUBCheckEvidence(
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
      appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
      startedAt: masterhubCheckStartedAt, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
      devices: masterhub?.checkDevices ?? MasterHUBCheckEvidence.groups.map { .init(module: $0.0, connected: false) },
      observed: observedMasterHUBControls, actionObserved: actionObservedMasterHUBControls, confirmed: confirmedMasterHUBControls)
  }
  private func persistMasterHUBCheck() {
    hardwareCheckSaveTask?.cancel()
    let evidence = masterHUBCheckEvidence()
    let directory = runtime.appendingPathComponent("HardwareChecks")
    hardwareCheckSaveTask = Task {
      do {
        try await Task.sleep(nanoseconds: 150_000_000)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let name = "\(Int(evidence.startedAt.timeIntervalSince1970 * 1000))-build\(evidence.appBuild).json"
        let output = directory.appendingPathComponent(name)
        try encoder.encode(evidence).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
      } catch is CancellationError {} catch { masterhubFeedback = "Could not save check progress: \(error.localizedDescription)" }
    }
  }
  func exportMasterHUBCheck() {
    let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "MasterHUB-Control-Check.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let evidence = masterHUBCheckEvidence()
    do {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(evidence).write(to: url, options: .atomic)
      masterhubFeedback = "Check exported. Unobserved inputs and unconfirmed actions remain unverified."
    } catch { masterhubFeedback = "Could not export check: \(error.localizedDescription)" }
  }
  func navigateMasterHUB(_ page: MasterHUBPage) {
    if page == .actions {
      masterhubSurface.navigate(page, sessionID: masterhubLayout?.selectedSessionID, requestID: masterhubLayout?.selectedRequestID)
    } else { masterhubSurface.navigate(page) }
    refreshMasterHUB()
  }
  func moveMasterHUBPage(_ delta: Int) { masterhubSurface.movePage(delta); refreshMasterHUB() }
  func reviewHandoff(_ record: AgentHandoff) {
    guard let request = snapshot?.requests.first(where: { $0.sessionId == record.sessionID && $0.state == "pending" && $0.expiresAt > DeckClock.now }) else {
      message = "This request is no longer pending. Open the original agent to review its result."; return
    }
    masterhubSurface.navigate(.actions, sessionID: record.sessionID, requestID: request.id)
    section = "MasterHUB"; refreshMasterHUB()
  }
  func refreshAppearance() { objectWillChange.send(); refreshMasterHUB() }
  private func refreshMasterHUB() {
    let live = connected ? snapshot : nil
    let layout = masterhubSurface.layout(snapshot: live, configuration: masterhubConfiguration, media: nowPlaying)
    if masterhubLayout != layout { masterhubLayout = layout }
    masterhub?.updateSurface(layout)
    var display = live
    display?.selectedSessionId = layout.selectedSessionID
    masterhub?.update(display)
  }
  func activateMasterHUBKey(_ key: Int, displayed: MasterHUBSurfaceSnapshot) {
    guard !identifyingMasterHUB, let current = masterhubLayout,
      displayed.instanceID == current.instanceID, displayed.revision == current.revision,
      displayed.tiles.indices.contains(key) else { return }
    let tile = displayed.tiles[key].tile
    if tile.requiresHold && tile.enabled {
      pendingConfirmation = .init(action: tile.action, sessionId: tile.target, requestId: tile.requestId,
        choiceId: tile.choiceId, heldMs: 700)
      let context = snapshot?.requests.first(where: { $0.id == tile.requestId })?.context ?? tile.sublabel
      confirmText = tile.action == "stop" ? "Interrupt the selected work in \(tile.sublabel)?" : "\(tile.label) once?\n\n\(context)"
      return
    }
    pressMasterHUBKey(key, displayed: displayed, heldMs: 0)
  }
  private func pressMasterHUBKey(_ key: Int, displayed: MasterHUBSurfaceSnapshot, heldMs: Int) {
    guard let current = masterhubLayout,
      let item = MasterHUBSurface.validatePress(displayed, current: current, index: key, heldMs: heldMs) else {
      masterhubFeedback = "The control changed or needs a 0.7-second hold. Try the updated key."; return
    }
    let tile = item.tile
    if checkingMasterHUBControls && ["respond", "stop"].contains(tile.action) {
      masterhubFeedback = "Approvals and interruption are disabled during device checks."; return
    }
    switch tile.action {
    case "hub.previous": moveMasterHUBPage(-1)
    case "hub.next": moveMasterHUBPage(1)
    case "hub.agents": navigateMasterHUB(.agents)
    case "hub.macPage": navigateMasterHUB(.mac)
    case "hub.mediaPage": navigateMasterHUB(.media)
    case "hub.toolsPage": navigateMasterHUB(.tools)
    case "hub.media": runMediaControl(tile.target)
    case "hub.handoffs": navigateMasterHUB(.handoffs)
    case "hub.attention": navigateMasterHUB(.attention)
    case "hub.actions": masterhubSurface.navigate(.actions, sessionID: tile.target); refreshMasterHUB()
    case "hub.request": masterhubSurface.navigate(.actions, sessionID: tile.target, requestID: tile.requestId); refreshMasterHUB()
    case "hub.mac": if let binding = item.binding { runMasterHUBBinding(binding, control: "Key \(key + 1)") }
    case "none": break
    default:
      perform(.init(action: tile.action, sessionId: tile.target, requestId: tile.requestId,
        choiceId: tile.choiceId, heldMs: heldMs)) { [weak self] result in
          self?.masterhubFeedback = result.message
          if result.ok { self?.verifiedMasterHUBControls.insert("Key \(key + 1)") }
        }
    }
  }
  func activateMasterHUBScreen() {
    guard !identifyingMasterHUB else { return }
    if masterhubLayout?.page == .media { runMediaControl("playpause") }
    else if let id = masterhubLayout?.selectedSessionID, !id.isEmpty { perform(.init(action: "focus", sessionId: id)) }
  }
  private func runMediaControl(_ command: String) {
    guard !identifyingMasterHUB else { return }
    if command == "mac" { navigateMasterHUB(.mac); return }
    if ["mute", "volumeUp", "volumeDown"].contains(command) {
      adjustMacAudio(delta: command == "mute" ? nil : command == "volumeUp" ? 0.05 : -0.05); return
    }
    Task {
      let result = await SpotifyControl.run(command)
      masterhubFeedback = result
    }
  }
  private func rotaryTurn(_ index: Int, delta: Int) {
    guard rotaryControls.bindings.indices.contains(index) else { return }
    let binding = rotaryControls.bindings[index]
    let delta = binding.reversed ? -delta : delta
    switch binding.turn {
    case .volume: adjustMacAudio(delta: Float(delta) * 0.05)
    case .pages: moveMasterHUBPage(delta)
    case .sessions: turnSelectedAgent(delta)
    case .scroll, .horizontalScroll, .zoom:
      guard AXIsProcessTrusted() else { message = "Enable Accessibility in Mac Permissions to use this dial."; return }
      if binding.turn == .scroll || binding.turn == .horizontalScroll {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
          wheel1: binding.turn == .scroll ? Int32(-delta * 3) : 0,
          wheel2: binding.turn == .horizontalScroll ? Int32(-delta * 3) : 0, wheel3: 0)?.post(tap: .cghidEventTap)
      } else {
        for down in [true, false] {
          let event = CGEvent(keyboardEventSource: nil, virtualKey: delta > 0 ? 24 : 27, keyDown: down)
          event?.flags = .maskCommand; event?.post(tap: .cghidEventTap)
        }
      }
    }
  }
  private func rotaryPress(_ index: Int) {
    guard rotaryControls.bindings.indices.contains(index) else { return }
    switch rotaryControls.bindings[index].press {
    case .none: break
    case .mute: adjustMacAudio(delta: nil)
    case .attention: navigateMasterHUB(.attention)
    case .dashboard: DeckAppDelegate.revealDashboard()
    case .resetZoom: _ = sendMacShortcut(key: 29, flags: .maskCommand)
    }
  }
  private func turnSelectedAgent(_ delta: Int) {
    guard connected else { message = "Reconnect Agent Deck to choose an agent."; return }
    pendingDialDelta += delta
    guard dialSelectionTask == nil else { return }
    dialSelectionTask = Task {
      defer { dialSelectionTask = nil }
      while pendingDialDelta != 0 && connected {
        let delta = pendingDialDelta; pendingDialDelta = 0
        do {
          var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/masterhub/turn")!)
          request.httpMethod = "POST"
          request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.httpBody = try JSONSerialization.data(withJSONObject: ["page": masterhubLayout?.page.rawValue ?? "agents", "delta": max(-1000, min(1000, delta)), "instanceId": snapshot?.instanceId ?? "", "fromSessionId": masterhubLayout?.selectedSessionID ?? ""])
          request.timeoutInterval = 4
          let (data, response) = try await URLSession.shared.data(for: request)
          if (response as? HTTPURLResponse)?.statusCode != 200 { message = "Could not select an agent. Reconnect the deck." }
          else {
            let update = try JSONDecoder().decode(DeckSnapshot.self, from: data)
            if snapshot?.instanceId != update.instanceId || (update.stateVersion ?? 0) >= (snapshot?.stateVersion ?? 0) { snapshot = update }
            masterhubSurface.navigate(.agents)
            if let snapshot { masterhubSurface.revealSelection(in: snapshot) }
            refreshMasterHUB()
          }
        } catch { message = "Dial selection failed: \(error.localizedDescription)" }
      }
      pendingDialDelta = 0
    }
  }
  private func sendMacShortcut(key: Int, flags: CGEventFlags) -> Bool {
    guard AXIsProcessTrusted(), (0...127).contains(key) else {
      masterhubFeedback = "Enable Agent Deck in Mac Permissions to use keyboard shortcuts."; return false
    }
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down) else { return false }
      event.flags = flags; event.post(tap: .cghidEventTap)
    }
    return true
  }
  private func runMasterHUBBinding(_ binding: MasterHUBKeyBinding, control: String) {
    guard !identifyingMasterHUB, binding.valid else { return }
    if checkingMasterHUBControls && binding.kind == .lockScreen {
      masterhubFeedback = "Lock screen is skipped during device checks."; return
    }
    var succeeded = false
    switch binding.kind {
    case .application, .browser:
      let url: URL?
      if binding.kind == .browser {
        url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.invalid")!)
      } else {
        url = (!binding.bundleID.isEmpty ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: binding.bundleID) : nil)
          ?? (FileManager.default.fileExists(atPath: binding.applicationPath) ? URL(fileURLWithPath: binding.applicationPath) : nil)
      }
      guard let url else { masterhubFeedback = "Choose an installed application for \(binding.label) in Customize."; return }
      NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
        Task { @MainActor in
          self?.masterhubFeedback = error.map { "Could not open \(binding.label): \($0.localizedDescription)" } ?? "Opened \(binding.label)"
          if error == nil { self?.verifiedMasterHUBControls.insert(control) }
        }
      }
      return
    case .spotlight: succeeded = sendMacShortcut(key: 49, flags: .maskCommand)
    case .screenshot: succeeded = sendMacShortcut(key: 21, flags: [.maskCommand, .maskShift])
    case .lockScreen: succeeded = sendMacShortcut(key: 12, flags: [.maskCommand, .maskControl])
    case .shortcut: succeeded = sendMacShortcut(key: binding.keyCode, flags: CGEventFlags(rawValue: binding.modifiers))
    case .dashboard: DeckAppDelegate.revealDashboard(); succeeded = true
    case .supervisor:
      if checkingMasterHUBControls { masterhubFeedback = "Voice is skipped during device checks."; return }
      section = "Supervisor"; DeckAppDelegate.revealDashboard()
      guard supervisor.deactivateCompatibility() else { masterhubFeedback = supervisor.error; return }
      if let url = AlfredCompanion.applicationURL { NSWorkspace.shared.open(url); succeeded = true }
      else { masterhubFeedback = "Install the separate Alfred app, or explicitly open the legacy assistant." }
    case .mute, .volumeUp, .volumeDown:
      do {
        if binding.kind == .mute { try MacAudio.toggleMute() }
        else { try MacAudio.adjustVolume(by: binding.kind == .volumeUp ? 0.05 : -0.05) }
        succeeded = true
      } catch { masterhubFeedback = error.localizedDescription }
    }
    if succeeded { verifiedMasterHUBControls.insert(control); masterhubFeedback = binding.label }
  }
  private func adjustMacAudio(delta: Float?) {
    do {
      if let delta { try MacAudio.adjustVolume(by: delta) }
      else { try MacAudio.toggleMute() }
      message = delta == nil ? "Output mute toggled" : "Output volume changed"
    } catch { message = error.localizedDescription }
  }
  func perform(_ command: ActionCommand, completion: ((ActionResult) -> Void)? = nil) {
    guard connected else {
      message = "Reconnect Agent Deck before sending an action."
      return
    }
    guard !actionInFlight else { return }
    actionInFlight = true
    Task {
      defer { actionInFlight = false }
      do {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/action")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(command)
        request.timeoutInterval = 12
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONDecoder().decode(ActionResult.self, from: data)
        message = result.message
        completion?(result)
      } catch { completion?(.failure(error.localizedDescription)); message = "Action failed: \(error.localizedDescription)" }
    }
  }
  func respond(_ request: PendingRequest, choice: RequestChoice) {
    let command = ActionCommand(
      action: "respond", sessionId: request.sessionId, requestId: request.id, choiceId: choice.id,
      heldMs: choice.requiresHold ? 700 : 0)
    if choice.requiresHold {
      pendingConfirmation = command
      confirmText = "Allow this action once?\n\n\(request.context)"
    } else {
      perform(command)
    }
  }
  func stop(_ session: SessionSnapshot) {
    pendingConfirmation = .init(action: "stop", sessionId: session.id, heldMs: 700)
    confirmText = "Interrupt the current work in \(session.workspace)?"
  }
  func startCodex(cwd: String, prompt: String) async -> Bool {
    do {
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/codex/start")!)
      request.httpMethod = "POST"
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["cwd": cwd, "prompt": prompt])
      request.timeoutInterval = 40
      let (data, _) = try await URLSession.shared.data(for: request)
      let result = try JSONDecoder().decode(ActionResult.self, from: data)
      message = result.message
      return result.ok
    } catch {
      message = error.localizedDescription
      return false
    }
  }
  var voiceClientID: String { guiControlClient.clientID }
  func supervisorRequest(_ path: String, body: [String: Any]? = nil) async throws -> Data {
    try await supervisorServiceRequest("supervisor/" + path, body: body)
  }
  func supervisorSnapshot() async throws -> DeckSnapshot {
    try JSONDecoder().decode(DeckSnapshot.self, from: await supervisorServiceRequest("status"))
  }
  private func supervisorServiceRequest(_ path: String, body: [String: Any]? = nil) async throws -> Data {
    guard endpoint() else { throw SupervisorNetwork.shared.problem("The agent service is unavailable. Reconnect Agent Deck.") }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
    request.httpMethod = body == nil ? "GET" : "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 20
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let (data, response) = try await SupervisorNetwork.shared.session.data(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
      throw SupervisorNetwork.shared.problem("The supervisor service rejected this request. Reconnect the app.")
    }
    return data
  }
  func refreshServiceReadiness() async {
    guard connected, endpoint() else {
      serviceReadinessGeneration += 1
      serviceAccessibilityGranted = nil
      return
    }
    serviceReadinessGeneration += 1
    let generation = serviceReadinessGeneration
    let requestToken = token
    let requestPort = port
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(requestPort)/health")!)
    request.setValue("Bearer \(requestToken)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 4
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard connected, generation == serviceReadinessGeneration,
        token == requestToken, port == requestPort else { return }
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        serviceAccessibilityGranted = nil; return
      }
      serviceAccessibilityGranted = try JSONDecoder().decode([String: Bool].self, from: data)["accessibilityGranted"]
    } catch {
      if connected, generation == serviceReadinessGeneration, token == requestToken, port == requestPort {
        serviceAccessibilityGranted = nil
      }
    }
  }
  func refreshIntegrationReadiness() {
    Task { await refreshServiceReadiness() }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let files = ["claude": ".claude/settings.json", "cursor": ".cursor/hooks.json",
      "gemini": ".gemini/settings.json", "codex": ".codex/hooks.json"]
    let hook = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/deck-hook").path
    var states: [String: IntegrationConfigurationState] = [:]
    for agent in ["claude", "codex", "cursor", "gemini", "antigravity"] {
      let text = files[agent].flatMap { try? String(contentsOf: home.appendingPathComponent($0), encoding: .utf8) }
      states[agent] = IntegrationReadiness.configuration(agent: agent, text: text, hookPath: hook)
    }
    integrationConfiguration = states
  }
  func installIntegrations(editor: Bool = false) {
    guard !installing else { return }
    installationSucceeded = false
    let executable = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Resources/install-hooks")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      installationMessage = "Installer missing. Rebuild the app bundle before installing integrations."
      message = installationMessage
      return
    }
    let process = Process()
    process.executableURL = executable
    process.arguments =
      ["--agents", preferences.enabledAgents.joined(separator: ",")]
      + ((UserDefaults.standard.string(forKey: "setupDevice") ?? "MasterHUB") == "MasterHUB" ? [] : ["--keypad"])
      + (editor ? ["--editor"] : [])
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      installing = true
      installationMessage = "Installing selected integrations…"
      message = installationMessage
      Task.detached {
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        await MainActor.run {
          self.installing = false
          self.installationSucceeded = process.terminationStatus == 0
          let details = String(data: output, encoding: .utf8) ?? "No installer output."
          self.refreshIntegrationReadiness()
          self.installationMessage = (self.installationSucceeded
            ? "Installer finished. Review connection checks: skipped or preserved settings may still need attention. Start new CLI sessions; reload Cursor windows for the bridge."
            : "Installation failed. Review the details below and retry.") + "\n\n" + details
          self.message = self.installationSucceeded ? "Setup checked. Review connection readiness." : "Integration installation failed"
        }
      }
    } catch {
      installing = false
      installationMessage = "Could not start installer: \(error.localizedDescription). Rebuild the app and retry."
      message = installationMessage
    }
  }
  func rename(_ session: SessionSnapshot) {
    let alert = NSAlert()
    alert.messageText = "Name this project"
    alert.informativeText = "The name appears in Agent Deck and on the keypad."
    let field = NSTextField(
      string: preferences.projectNames[session.projectKey] ?? session.workspace)
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
      let value = String(
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
      if !value.isEmpty { savePreferences { $0.projectNames[session.projectKey] = value } }
    }
  }
  func savePreferences(_ edit: (inout DeckPreferences) -> Void) {
    var next = preferences
    edit(&next)
    draftPreferences = next
    preferenceRevision += 1
    let expectedRevision = preferenceRevision
    let prior = preferencesTask
    preferencesTask = Task {
      await prior?.value
      do {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/preferences")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(next)
        let (_, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode != 200 {
          message = "Could not save settings."
        }
      } catch {
        message = "Settings were not saved. Reconnect the service."
        if expectedRevision == preferenceRevision { draftPreferences = nil }
      }
    }
  }
  func togglePin(_ session: SessionSnapshot) {
    savePreferences { p in
      if p.pinnedSessionIds.contains(session.id) {
        p.pinnedSessionIds.removeAll { $0 == session.id }
      } else {
        p.pinnedSessionIds.append(session.id)
      }
    }
  }
  func exportDiagnostics() {
    do {
      let data = try DeckDiagnostics.report().json()
      let preview = NSAlert()
      preview.messageText = "Review diagnostic report"
      preview.informativeText = "Includes versions, process status and hardware counts only. No chats, prompts, credentials or personal paths. Review the exact report before saving."
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 260))
      scroll.hasVerticalScroller = true
      let text = NSTextView(frame: scroll.bounds)
      text.isEditable = false; text.isSelectable = true
      text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      text.string = String(decoding: data, as: UTF8.self)
      scroll.documentView = text; preview.accessoryView = scroll
      preview.addButton(withTitle: "Save report…"); preview.addButton(withTitle: "Cancel")
      guard preview.runModal() == .alertFirstButtonReturn else { return }
      let panel = NSSavePanel()
      panel.nameFieldStringValue = "Agent-Deck-Diagnostics.json"
      panel.allowedContentTypes = [.json]
      guard panel.runModal() == .OK, let url = panel.url else { return }
      try DeckDiagnosticReport.saveNew(data, to: url)
      message = "Diagnostic report saved. Chats and credentials were excluded."
    } catch {
      message = "Could not save diagnostic report. Choose a new filename in a writable folder."
    }
  }

}

@MainActor final class DeckAppDelegate: NSObject, NSApplicationDelegate {
  static var mayTerminate: (() -> Bool)?
  static var onTerminate: (() -> Void)?
  static var openDashboard: (() -> Void)?
  static weak var dashboardWindow: NSWindow?
  static func revealDashboard() {
    guard let window = dashboardWindow else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
      window.center()
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    // Local, content-free lifecycle diagnostics distinguish a hidden window from a crashed app.
    DispatchQueue.main.async {
      let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
        "visible": window.isVisible, "minimized": window.isMiniaturized,
        "key": window.isKeyWindow, "onScreen": NSScreen.screens.contains {
          $0.visibleFrame.intersects(window.frame)
        }]
      let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/AgentDeck")
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if let data = try? JSONSerialization.data(withJSONObject: state) {
        try? data.write(to: directory.appendingPathComponent("window-health.json"), options: .atomic)
      }
    }
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    DistributedNotificationCenter.default().addObserver(self,
      selector: #selector(showDashboard), name: .init("com.aiagentdeck.showMainWindow"), object: nil)
    DispatchQueue.main.async { self.showDashboard() }
  }
  @objc func showDashboard() {
    Self.openDashboard?()
    Self.revealDashboard()
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showDashboard()
    return true
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard Self.mayTerminate?() != false else {
      let alert = NSAlert(); alert.messageText = "Finish active work before installing this update"
      alert.informativeText = "Resolve pending approvals and finish supervised tasks, then retry the update."
      alert.addButton(withTitle: "Keep Agent Deck open"); alert.runModal()
      return .terminateCancel
    }
    return .terminateNow
  }
  func applicationWillTerminate(_ notification: Notification) { Self.onTerminate?() }
}

struct DashboardWindowAccess: NSViewRepresentable {
  final class WindowView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      DeckAppDelegate.dashboardWindow = window
      DispatchQueue.main.async { DeckAppDelegate.revealDashboard() }
    }
  }
  func makeNSView(context: Context) -> WindowView { WindowView() }
  func updateNSView(_ view: WindowView, context: Context) {}
}

@MainActor private final class DeckApplicationLifetime: ObservableObject {
  let model = DeckModel()
}

private struct DashboardRoot: View {
  @ObservedObject var model: DeckModel
  var body: some View {
      MainView().environmentObject(model).frame(minWidth: 820, minHeight: 570)
        .onAppear { _ = model.supervisor }
        .background(DashboardWindowAccess())
        .sheet(isPresented: $model.showSetup) { SetupView().environmentObject(model) }
        .sheet(isPresented: $model.showCodex) { ManagedCodexView().environmentObject(model) }
        .confirmationDialog(
          "Confirm action",
          isPresented: Binding(
            get: { model.pendingConfirmation != nil },
            set: { if !$0 { model.pendingConfirmation = nil } }), titleVisibility: .visible
        ) {
          Button(
            model.pendingConfirmation?.action == "stop" ? "Interrupt work" : "Allow once",
            role: model.pendingConfirmation?.action == "stop" ? .destructive : nil
          ) {
            if let command = model.pendingConfirmation {
              model.pendingConfirmation = nil
              model.perform(command)
            }
          }
          Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
        } message: {
          Text(model.confirmText)
        }
  }
}

struct AgentDeckApp: App {
  @NSApplicationDelegateAdaptor(DeckAppDelegate.self) private var appDelegate
  // Keep the model alive without subscribing the entire Scene tree to telemetry.
  @StateObject private var lifetime = DeckApplicationLifetime()
  private var model: DeckModel { lifetime.model }
  var body: some Scene {
    Window("Agent Deck", id: "main") {
      DashboardRoot(model: model)
    }.defaultSize(width: 1050, height: 720).commands {
      CommandGroup(after: .appInfo) {
        Button("Explore MasterHUB Demo…") { model.openDemo() }
        Button("Check for Updates…") { model.checkForUpdates() }.disabled(!model.updatesConfigured)
      }
    }
    MenuBarExtra {
      MenuBarView().environmentObject(model)
    } label: {
      ObservedMenuBarStatusLabel(attention: model.menuBarAttention)
    }.menuBarExtraStyle(.window)
    Window("Mac Permissions", id: "permissions") {
      MacPermissionsView().environmentObject(model).frame(minWidth: 560, minHeight: 580)
    }.defaultSize(width: 580, height: 620)
    Settings { SettingsView().environmentObject(model).frame(width: 580, height: 490) }
  }
}
struct MainView: View {
  @ObservedObject private var permissions = MacPermissionMonitor.shared
  @EnvironmentObject var model: DeckModel
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    NavigationSplitView {
      List(selection: $model.section) {
        Label("MasterHUB", systemImage: "square.grid.3x3.fill").tag("MasterHUB")
        Label("Keypad", systemImage: "square.grid.3x3").tag("Keypad")
        Label("Attention", systemImage: "tray").badge(model.waitingCount).tag("Attention")
        Label("Sessions", systemImage: "rectangle.stack").tag("Sessions")
        Label("Handoffs", systemImage: "checkmark.bubble").tag("Handoffs")
        Label("Alfred", systemImage: "waveform.circle").tag("Supervisor")
        Label("Activity", systemImage: "clock").tag("Activity")
      }.navigationTitle("Agent Deck").safeAreaInset(edge: .bottom) {
        HStack(spacing: 7) {
          Circle().fill(model.connected ? .green : .orange).frame(width: 7, height: 7)
          Text(model.connected ? "Connected · \(model.observedSessionCount) observed" : "Reconnecting")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
        }.padding()
      }
    } detail: {
      Group {
        if model.section == "MasterHUB" {
          MasterHUBWorkspace()
        } else if model.section == "Keypad" {
          KeypadView()
        } else if model.section == "Sessions" {
          SessionListView()
        } else if model.section == "Handoffs" {
          AgentHandoffsView()
        } else if model.section == "Supervisor" {
          SupervisorView()
        } else if model.section == "Activity" {
          ActivityView()
        } else {
          AttentionView()
        }
      }.navigationTitle(model.section == "Supervisor" ? "Alfred" : model.section).safeAreaInset(edge: .top) {
        if !permissions.accessibility || (model.masterhubStatus.hasPrefix("MasterHUB connected") && !permissions.inputMonitoring) {
          HStack {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text("Agent Deck needs Mac permissions").font(.callout)
            Spacer()
            Button("Fix Mac permissions") { openWindow(id: "permissions") }
              .buttonStyle(.borderedProminent)
          }.padding(12).background(.bar)
        }
      }.toolbar {
        ToolbarItem {
          Button("Mac permissions", systemImage: "hand.raised") { openWindow(id: "permissions") }
            .help("Check and repair Mac permissions")
        }
        ToolbarItem {
          Button {
            model.showSetup = true
          } label: {
            Image(systemName: "checkmark.shield")
          }.help("Check setup")
        }
        ToolbarItem {
          Button {
            model.showCodex = true
          } label: {
            Image(systemName: "plus")
          }.help("Start a managed Codex session")
        }
        ToolbarItem { SettingsLink { Image(systemName: "slider.horizontal.3") } }
      }.safeAreaInset(edge: .bottom) {
        if !model.message.isEmpty {
          HStack {
            Image(systemName: model.connected ? "info.circle" : "wifi.slash")
            Text(model.message).font(.callout)
            Spacer()
          }.padding(12).background(.bar).accessibilityElement(children: .combine)
        }
      }
    }.onAppear {
      DeckAppDelegate.openDashboard = { openWindow(id: "main") }
    }
  }
}
struct AttentionView: View {
  @EnvironmentObject var model: DeckModel
  var body: some View {
    if model.requests.isEmpty {
      ContentUnavailableView {
        Label(
          model.waitingCount > 0 ? "Open the session to respond" : "You're all clear",
          systemImage: model.waitingCount > 0 ? "arrow.up.forward.app" : "checkmark.circle")
      } description: {
        Text(
          model.waitingCount > 0
            ? "This agent doesn't provide a request-specific response connection."
            : "Requests appear here when an agent needs your decision.")
      } actions: {
        ForEach(model.allSessions.filter { $0.status == .waiting }) { session in
          Button("Open \(session.workspace)") {
            model.perform(.init(action: "focus", sessionId: session.id))
          }
        }
      }
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("Take a moment. Know what you're allowing.").font(.title2.weight(.semibold))
          Text("Oldest unanswered request first").font(.subheadline).foregroundStyle(.secondary)
          ForEach(model.requests) { request in RequestCard(request: request) }
        }.padding(28).frame(maxWidth: 850, alignment: .leading)
      }
    }
  }
}
struct RequestCard: View {
  @EnvironmentObject var model: DeckModel
  let request: PendingRequest
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        Text(model.snapshot?.sessions[request.sessionId]?.workspace ?? "Session").font(.headline)
        Text(model.snapshot?.sessions[request.sessionId]?.agentName ?? "").font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        Text(Date(timeIntervalSince1970: request.createdAt / 1000), style: .relative).font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(request.title).font(.title3.weight(.semibold))
      ScrollView(.horizontal) {
        Text(request.context).font(.system(.body, design: .monospaced)).textSelection(.enabled)
          .padding(14).frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 180).background(
        .quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
      HStack {
        Button("Open session", systemImage: "arrow.up.forward.app") {
          model.perform(.init(action: "focus", sessionId: request.sessionId))
        }.buttonStyle(.borderless)
        Spacer()
        ForEach(request.choices.reversed()) { choice in
          Button(choice.label) { model.respond(request, choice: choice) }.buttonStyle(.bordered)
            .tint(choice.requiresHold ? .accentColor : nil).disabled(model.actionInFlight)
        }
      }
    }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 16)).overlay(
      RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
  }
}
struct SessionListView: View {
  @EnvironmentObject var model: DeckModel
  var body: some View {
    List(model.allSessions) { session in
      HStack(spacing: 14) {
        if let image = ProviderArtwork.image(provider: session.agentId, state: session.status.rawValue, phase: 0) {
          Image(nsImage: image).resizable().frame(width: 40, height: 40).accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 5) {
          HStack {
            Text(model.preferences.projectNames[session.projectKey] ?? session.workspace).font(
              .headline)
            Text(session.agentName).foregroundStyle(.secondary)
          }
          Text(session.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        Text(session.status.label).font(.caption).foregroundStyle(.secondary)
        Button {
          model.togglePin(session)
        } label: {
          Image(
            systemName: model.preferences.pinnedSessionIds.contains(session.id) ? "pin.fill" : "pin"
          )
        }.buttonStyle(.borderless).help("Pin session to the keypad")
        Button("Open") { model.perform(.init(action: "focus", sessionId: session.id)) }.disabled(
          !session.capabilities.focus || model.actionInFlight)
      }.padding(.vertical, 8).contextMenu {
        Button("Rename project…") { model.rename(session) }
        Button("Open session") { model.perform(.init(action: "focus", sessionId: session.id)) }
        if session.capabilities.interrupt {
          Button("Interrupt work", role: .destructive) { model.stop(session) }
        }
        Button(
          model.preferences.mutedProjects.contains(session.projectKey)
            ? "Unmute project" : "Mute project"
        ) {
          model.savePreferences { p in
            if p.mutedProjects.contains(session.projectKey) {
              p.mutedProjects.removeAll { $0 == session.projectKey }
            } else {
              p.mutedProjects.append(session.projectKey)
            }
          }
        }
      }
    }.searchable(text: $model.search, prompt: "Find a project or agent").overlay {
      if model.allSessions.isEmpty { ContentUnavailableView.search(text: model.search) }
    }
  }
}
struct ActivityView: View {
  @EnvironmentObject var model: DeckModel
  var body: some View {
    List(model.snapshot?.recentEvents ?? []) { event in
      HStack(alignment: .top, spacing: 12) {
        Image(
          systemName: event.outcome == "expired" ? "clock.badge.exclamationmark" : "circle.fill"
        ).foregroundStyle(.secondary).font(.caption)
        VStack(alignment: .leading, spacing: 4) {
          Text(event.title)
          Text(model.snapshot?.sessions[event.sessionId]?.workspace ?? "Agent Deck").font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(Date(timeIntervalSince1970: event.timestamp / 1000), style: .time).font(
          .caption.monospacedDigit()
        ).foregroundStyle(.secondary)
      }.padding(.vertical, 6)
    }.overlay {
      if model.snapshot?.recentEvents.isEmpty != false {
        ContentUnavailableView(
          "No recent activity", systemImage: "clock",
          description: Text("Connection and response history appears here."))
      }
    }
  }
}
struct MenuBarView: View {
  @EnvironmentObject var model: DeckModel
  @Environment(\.openWindow) var openWindow
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(model.waitingCount > 0 ? "\(model.waitingCount) need you" : "All clear").font(
          .headline)
        Spacer()
        Circle().fill(model.connected ? .green : .orange).frame(width: 7, height: 7)
      }
      if let request = model.requests.first {
        Text(model.snapshot?.sessions[request.sessionId]?.workspace ?? "Session").font(
          .subheadline.weight(.medium))
        Text(request.title).foregroundStyle(.secondary)
        Button("Review request") {
          openWindow(id: "main")
          NSApp.activate(ignoringOtherApps: true)
        }.buttonStyle(.borderedProminent)
      } else {
        Text(
          model.connected ? "Your agents can keep working." : "Reconnecting to the local service."
        ).font(.callout).foregroundStyle(.secondary)
      }
      Divider()
      HStack {
        Button("Open Agent Deck") {
          openWindow(id: "main")
          NSApp.activate(ignoringOtherApps: true)
        }
        Spacer()
        SettingsLink { Image(systemName: "gearshape") }
      }
      Button("Quit Agent Deck") { NSApp.terminate(nil) }.font(.caption).buttonStyle(.borderless)
    }.padding(18).frame(width: 320)
  }
}
struct SettingsView: View {
  @AppStorage("dashboardAnimatedArtwork") private var animatedArtwork = false
  @AppStorage("attention.soundEnabled") private var attentionSoundEnabled = true
  @EnvironmentObject var model: DeckModel
  @State private var login = false
  @State private var installerMessage = ""
  var body: some View {
    TabView {
      VStack(spacing: 16) {
        Text("Alfred runs as a separate app.").font(.headline)
        Button("Open Alfred") { model.section = "Supervisor"; DeckAppDelegate.revealDashboard() }
          .buttonStyle(.borderedProminent)
        Text("Open Alfred for voice, conversation, skills and Operations. Your legacy assistant remains available during migration.").foregroundStyle(.secondary)
      }.padding().tabItem { Label("Alfred", systemImage: "bubble.left.and.bubble.right") }
      MacPermissionsView().tabItem { Label("Permissions", systemImage: "hand.raised") }
      Form {
        Toggle("Include idle and finished root sessions on MasterHUB", isOn: Binding(
          get: { model.preferences.showIdleSessions == true },
          set: { value in model.savePreferences { $0.showIdleSessions = value } }))
        Toggle(
          "Automatically show a single active session",
          isOn: Binding(
            get: { model.preferences.automaticSingleAgent },
            set: { value in model.savePreferences { $0.automaticSingleAgent = value } }))
        Toggle(
          "Reduce motion",
          isOn: Binding(
            get: { model.preferences.reduceMotion },
            set: { value in model.savePreferences { $0.reduceMotion = value } }))
        Toggle("Play sound when an agent needs input", isOn: $attentionSoundEnabled)
        Toggle("Approve Cursor & Gemini tool calls on deck", isOn: Binding(
          get: { model.preferences.toolHookApprovals == true },
          set: { value in model.savePreferences { $0.toolHookApprovals = value } }))
          .help("Prompt on the deck for Cursor Shell/MCP and Gemini tool calls. When off, those CLIs use their own prompts without waiting.")
        Toggle("Open at login", isOn: $login).onChange(of: login) { _, value in
          do {
            if value {
              try SMAppService.mainApp.register()
            } else {
              try SMAppService.mainApp.unregister()
            }
          } catch { installerMessage = error.localizedDescription }
        }
        Button("Review setup") { model.showSetup = true }
        LabeledContent("MasterHUB", value: model.masterhubStatus)
        Text("Agents page: keys 1–10 select sessions, keys 11–15 navigate, open Attention/Actions, and switch pages. Also includes Mac, Media, Tools, and Handoffs.")
          .font(.caption)
        LabeledContent("Connection", value: model.connected ? "Connected" : "Disconnected")
        Toggle("Animate dashboard artwork", isOn: $animatedArtwork)
          .help("Adds decorative motion to the dashboard and uses more CPU. Live agent states update in either mode.")
        Button("Check for updates…") { model.checkForUpdates() }.disabled(!model.updatesConfigured)
        if let privateUpdates = model.privateUpdates {
          PrivateUpdateSettingsPanel(updates: privateUpdates)
        }
        if !model.updatesConfigured {
          Text("Signed updates will be enabled when the release feed is configured.").font(.caption)
            .foregroundStyle(.secondary)
        }
        if !installerMessage.isEmpty {
          Text(installerMessage).font(.caption).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.onAppear {
        login = SMAppService.mainApp.status == .enabled
      }
      MasterHUBSettingsView().tabItem { Label("MasterHUB", systemImage: "keyboard") }
      KeypadView().tabItem { Label("Keypad", systemImage: "square.grid.3x3") }
      Form {
        ForEach(["claude", "codex", "cursor", "gemini", "antigravity"], id: \.self) { agent in
          LabeledContent(agentName(agent)) {
            Text(
              (model.snapshot?.sessions.values.contains {
                $0.agentId == agent && $0.status != .disconnected && $0.status != .unknown
              } ?? false) ? "Session observed" : "No live session"
            ).foregroundStyle(.secondary)
          }
        }
        Button("Install selected hooks") { model.installIntegrations() }.disabled(model.installing)
        Button("Install Cursor terminal bridge") { model.installIntegrations(editor: true) }.disabled(model.installing)
        if !model.installationMessage.isEmpty {
          Text(model.installationMessage).font(.caption).textSelection(.enabled)
        }
        Text(model.message).font(.caption).foregroundStyle(.secondary)
        Text(
          "Claude and Codex CLI permissions can be answered here; Cursor and Gemini tool approvals can be enabled in General settings. Restart terminal sessions after setup."
        ).font(.caption).foregroundStyle(.secondary)
        Text(installerMessage).font(.caption)
      }.formStyle(.grouped).tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
      Form {
        Toggle(
          "Notify when an agent needs me",
          isOn: Binding(
            get: { model.preferences.notifications },
            set: { value in
              if value {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) {
                  granted, _ in
                  Task { @MainActor in model.savePreferences { $0.notifications = granted } }
                }
              } else {
                model.savePreferences { $0.notifications = false }
              }
            }))
        Toggle(
          "Include project names in notifications",
          isOn: Binding(
            get: { model.preferences.showSensitiveNotifications },
            set: { value in model.savePreferences { $0.showSensitiveNotifications = value } }))
        Text(
          "Sound is off. Request contents stay on this Mac. Muted projects do not send notifications."
        ).font(.caption).foregroundStyle(.secondary)
        Button("Review diagnostic report…") { model.exportDiagnostics() }
      }.formStyle(.grouped).tabItem { Label("Privacy", systemImage: "hand.raised") }
    }.padding(12)
  }

}
struct ManagedCodexView: View {
  @EnvironmentObject var model: DeckModel
  @Environment(\.dismiss) var dismiss
  @State private var cwd = ""
  @State private var prompt = ""
  @State private var starting = false
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("New Codex session").font(.title.weight(.semibold))
      Text(
        "This session runs through your installed Codex CLI. Your existing account, approval policy, and sandbox settings apply. Requests arrive in Attention."
      ).foregroundStyle(.secondary)
      HStack {
        Text(cwd.isEmpty ? "Choose a project folder" : cwd).lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("Choose…") {
          let panel = NSOpenPanel()
          panel.canChooseFiles = false
          panel.canChooseDirectories = true
          if panel.runModal() == .OK { cwd = panel.url?.path ?? "" }
        }
      }
      TextEditor(text: $prompt).font(.body).frame(minHeight: 140).padding(8).overlay(
        RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
      if starting { ProgressView("Starting Codex…") }
      Text(model.message).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Start session") {
          starting = true
          Task {
            if await model.startCodex(cwd: cwd, prompt: prompt) { dismiss() }
            starting = false
          }
        }.buttonStyle(.borderedProminent).disabled(
          starting || cwd.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(28).frame(width: 590, height: 430)
  }
}
if (CommandLine.arguments.contains("--export-jarvis-schema") || CommandLine.arguments.contains("--export-robin-schema")) {
  let data = try JSONSerialization.data(withJSONObject: JarvisStep.schema, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
} else if CommandLine.arguments.contains("--diagnostics") {
  do {
    print(String(decoding: try DeckDiagnostics.report().json(), as: UTF8.self))
  } catch { fputs("Could not generate diagnostic report. No user data was changed.\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--verify-private-update-delivery") {
  Task { @MainActor in
    NSApplication.shared.setActivationPolicy(.prohibited)
    guard let updates = PrivateUpdateController() else {
      fputs("Private update configuration is missing. Run this diagnostic from the configured app bundle.\n", stderr); exit(1)
    }
    await updates.check(manual: false, verifyDelivery: true)
    let passed = updates.deliveryVerified
    updates.shutdown()
    print(String(decoding: try! JSONSerialization.data(withJSONObject: ["passed": passed, "detail": updates.status,
      "scope": "Authenticated download and signature verification only; no installation, device access, or agent commands."], options: [.sortedKeys]), as: UTF8.self))
    exit(passed ? 0 : 1)
  }
  RunLoop.main.run()
 } else if CommandLine.arguments.contains("--test-robin-audio-fixture") {
  Task { @MainActor in
    NSApplication.shared.setActivationPolicy(.prohibited)
    do {
      let report = try await RobinAudioDiagnostic.runFixture()
      print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
      exit(0)
    } catch {fputs("Audio fixture failed: \(error.localizedDescription)\n",stderr);exit(1)}
  }
  RunLoop.main.run()
} else if CommandLine.arguments.contains("--test-alfred-upgrades") {
  Task { @MainActor in
    NSApplication.shared.setActivationPolicy(.prohibited)
    do { try await AlfredUpgradeDiagnostic.run(); exit(0) }
    catch { fputs("Alfred upgrade check failed: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  RunLoop.main.run()
} else if CommandLine.arguments.contains("--test-robin-workflow") {
  Task { @MainActor in
    NSApplication.shared.setActivationPolicy(.prohibited)
    do {try await RobinWorkflowDiagnostic.run();exit(0)}
    catch {fputs("Workflow test failed: \(error.localizedDescription)\n",stderr);exit(1)}
  }
  RunLoop.main.run()
} else if CommandLine.arguments.contains("--test-robin-conversation") {
  Task { @MainActor in
    NSApplication.shared.setActivationPolicy(.prohibited)
    do {
      let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
      let runtime = JarvisRuntime(deck:DeckModel(previewSnapshot:await engine.snapshot()),persist:false)
      let question = try await runtime.run("help me decide what to work on next",context:"No task has been chosen.",lessons:"")
      guard runtime.isClarifying, runtime.phase == .needsYou, question.contains("?"), runtime.receipts.isEmpty else {
        throw NSError(domain:"RobinConversation",code:1,userInfo:[NSLocalizedDescriptionKey:"Initial goal did not produce a question without execution."])
      }
      let pending = RobinConversationQuestion(project:"/fixture/a",goal:"Choose next work",question:question)
      let restored = try JSONDecoder().decode(RobinConversationQuestion.self,from:JSONEncoder().encode(pending))
      guard restored.continuing(with:"the second one").contains("Choose next work"),restored.continuing(with:"the second one").contains(question) else { throw CocoaError(.coderReadCorrupt) }
      let turns:[SupervisorMessage] = [.init(role:"user",content:"unscoped"),.init(role:"user",content:"other",project:"/fixture/b"),.init(role:"assistant",content:question,project:"/fixture/a")]
      let history = RobinConversation.history(turns,project:"/fixture/a",cloud:true)
      guard history.count == 1,history.first?["content"] == question else { throw CocoaError(.coderReadCorrupt) }
      print("PASS: actual Alfred runtime asks a focused question, waits for an answer, retains goal/question, and isolates cloud history. No model or tool executed.")
      exit(0)
    } catch { fputs("Conversation diagnostic failed: \(error.localizedDescription)\n",stderr);exit(1) }
  }
  RunLoop.main.run()
} else if CommandLine.arguments.contains("--test-robin-subscription") {
  Task { @MainActor in
    NSApplication.shared.setActivationPolicy(.prohibited)
    do {
      let modelIndex = CommandLine.arguments.firstIndex(of:"--subscription-model")
      let modelID = modelIndex.flatMap { CommandLine.arguments.indices.contains($0+1) ? CommandLine.arguments[$0+1] : nil } ?? "chatgpt"
      let reply = try await RobinChatGPTSubscription.shared.complete(messages: [
        ["role":"system", "content":"Return exactly one JSON step matching the schema. Do not inspect files or use any tools. This is a harmless connection test."],
        ["role":"user", "content":"Respond with kind respond, action null, and reply Subscription connection verified. All argument fields null."]], schema: JarvisStep.schema, modelID:modelID)
      let step = try JarvisStep.decode(Data(reply.text.utf8))
      guard step.kind == .respond else { throw NSError(domain:"RobinSubscription",code:1,userInfo:[NSLocalizedDescriptionKey:"Unexpected connection-test response."]) }
      print("PASS: Alfred received a valid response using \(modelID) official subscription sign-in. No API key used.")
      exit(0)
    } catch { fputs("Subscription connection check failed: \(error.localizedDescription)\n",stderr); exit(1) }
  }
  RunLoop.main.run()
} else if CommandLine.arguments.contains("--benchmark-robin-local") {
  Task { @MainActor in
    NSApplication.shared.setActivationPolicy(.prohibited)
    let benchmark = RobinBenchmarkController()
    await benchmark.execute(configuration: .init(), selected: "local", allConfigured: false, paidConsent: false, budgetUSD: 0, full: CommandLine.arguments.contains("--full-suite"))
    print(benchmark.status)
    exit(Task.isCancelled ? 1 : 0)
  }
  RunLoop.main.run()
} else if CommandLine.arguments.contains("--test-robin-mission") {
  Task { @MainActor in
    NSApplication.shared.setActivationPolicy(.prohibited)
    do { try await RobinMissionDiagnostic.run(); exit(0) }
    catch { fputs("Alfred mission diagnostic failed: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  RunLoop.main.run()
} else if CommandLine.arguments.contains("--test-kokoro-playback") {
  Task { @MainActor in
    NSApplication.shared.setActivationPolicy(.prohibited)
    let speech = SupervisorKokoro()
    speech.onError = { message in fputs("Kokoro playback failed: \(message)\n", stderr); exit(1) }
    speech.onFinished = { speech.shutdown(); print("PASS: Kokoro generated and played speech; completion callback delivered."); exit(0) }
    speech.speak("Hello. I am your local supervisor. Tell me what you want your agents to work on, and we will take it one step at a time.", voice: "af_heart", speed: 1)
    Task {
      try? await Task.sleep(for: .seconds(60))
      fputs("Kokoro playback timed out.\n", stderr); exit(1)
    }
  }
  RunLoop.main.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--render-masterhub-preview"),
  CommandLine.arguments.indices.contains(index + 1) {
  let arguments = CommandLine.arguments
  Task { @MainActor in
    AgentVisualStyle.isolated = true
    do { try await MasterHUBPreviewRenderer.render(to: arguments[index + 1], arguments: arguments); exit(0) }
    catch { fputs("Preview failed: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  RunLoop.main.run()
} else if CommandLine.arguments.contains("--demo") {
  AgentVisualStyle.isolated = true
  MasterHUBDemoApp.main()
} else {
  AgentDeckApp.main()
}
