import AppKit
import Combine
import DeckCore
import Darwin
import Foundation
import Sparkle
import SwiftUI

/// GitHub credentials remain inside `gh`; Sparkle receives only verified local bytes.
@MainActor final class PrivateUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
  @Published private(set) var status = "Ready to check private releases."
  @Published private(set) var checking = false
  @Published private(set) var deliveryVerified = false
  @Published var automatic: Bool {
    didSet { UserDefaults.standard.set(automatic, forKey: "privateUpdates.automatic") }
  }
  @Published var includePreviews: Bool {
    didSet { UserDefaults.standard.set(includePreviews, forKey: "privateUpdates.previews") }
  }
  var onStatus: ((String) -> Void)?
  var mayRelaunch: (() -> Bool)?
  private let repository: String
  private let publicKey: Data
  private let helper: URL
  private let currentBuild: String
  private var scheduler: Task<Void, Never>?
  private var controller: SPUStandardUpdaterController?
  private var server: Process?
  private var cache: URL?
  private var localFeed: URL?
  private var localArchive: URL?
  private var manifest: PrivateUpdateManifest?
  private var pendingInstall: (() -> Void)?
  private var deferredInstallTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var updateAwaitingInstallation = false
  private var deliveryProbe: CheckedContinuation<Void, Error>?
  var installationMayBePending: Bool { updateAwaitingInstallation || controller?.updater.sessionInProgress == true || pendingInstall != nil }

  func shutdown() {
    scheduler?.cancel(); scheduler = nil
    recoveryTask?.cancel(); recoveryTask = nil
    stopServer()
  }

  static func taskProcessIsAlive(_ task: SupervisedTask) -> Bool {
    guard let pid = task.pid else { return false }
    guard pid > 0, pid <= Int(Int32.max) else { return true }
    if let witness = ProcessWitness.read(pid) { return task.processBirth == nil || task.processBirth == witness.birth }
    if Darwin.kill(Int32(pid), 0) == 0 { return true }
    return errno != ESRCH
  }

  static func repository(in bundle: Bundle) -> String? {
    guard let value = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      let url = URL(string: value), url.scheme == "https", url.host == "github.com",
      url.user == nil, url.password == nil else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 3, parts[2] == "releases",
      parts.prefix(2).allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else { return nil }
    return parts[0] + "/" + parts[1]
  }

  init?(bundle: Bundle = .main) {
    guard let repository = Self.repository(in: bundle),
      let encoded = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      let key = Data(base64Encoded: encoded), key.count == 32,
      let helper = bundle.resourceURL?.appendingPathComponent("Updates/private-update.py"),
      FileManager.default.fileExists(atPath: helper.path) else { return nil }
    self.repository = repository; self.publicKey = key; self.helper = helper
    self.currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    automatic = UserDefaults.standard.object(forKey: "privateUpdates.automatic") as? Bool ?? true
    includePreviews = UserDefaults.standard.object(forKey: "privateUpdates.previews") as? Bool
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "").hasPrefix("0.")
    super.init()
  }

  func start() {
    guard scheduler == nil else { return }
    recoveryTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        if await self.recoverServiceAfterUpdate() { return }
        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
      }
    }
    scheduler = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 20_000_000_000)
      while !Task.isCancelled {
        guard let self else { return }
        if self.automatic { await self.check(manual: false) }
        if self.pendingInstall != nil, self.mayRelaunch?() == true {
          let handler = self.pendingInstall; self.pendingInstall = nil; handler?()
        }
        do { try await Task.sleep(nanoseconds: 21_600_000_000_000) } catch { return }
      }
    }
  }

  func check(manual: Bool, verifyDelivery: Bool = false) async {
    if updateAwaitingInstallation || pendingInstall != nil {
      if manual { controller?.checkForUpdates(nil) }
      return
    }
    guard !checking, controller?.updater.sessionInProgress != true else { return }
    checking = true
    deliveryVerified = false
    defer { checking = false }
    say("Checking private releases…", manual: manual)
    stopServer()
    let cacheRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/AgentDeck/PrivateUpdates")
    let directory = cacheRoot.appendingPathComponent(UUID().uuidString)
    do {
      try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheRoot.path)
      _ = try await run(["clean", "--directory", cacheRoot.path])
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      cache = directory
      var arguments = ["inspect", "--repository", repository, "--output-dir", directory.path, "--candidates"]
      if includePreviews || verifyDelivery { arguments.append("--include-prereleases") }
      let candidates = try JSONDecoder().decode(Releases.self, from: await run(arguments)).releases
      guard !candidates.isEmpty, candidates.count <= 30, Set(candidates.map(\.index)).count == candidates.count,
        candidates.allSatisfy({ (0..<30).contains($0.index) }) else { throw problem("The release list is invalid.") }
      var chosen: (Release, PrivateUpdateManifest, Data)?
      for candidate in candidates {
        // Derive paths from bounded indices; never trust helper-provided filesystem paths.
        let feed = try Data(contentsOf: directory.appendingPathComponent(String(candidate.index)).appendingPathComponent("appcast.xml"))
        let verified = try PrivateUpdateManifest.verify(feed: feed, publicKey: publicKey, repository: repository, tag: candidate.tag)
        if chosen == nil || verified.build.compare(chosen!.1.build, options: .numeric) == .orderedDescending {
          chosen = (candidate, verified, feed)
        }
      }
      guard let (response, verified, feed) = chosen else { throw problem("No verified release is available.") }
      let feedFile = directory.appendingPathComponent("appcast.xml")
      try feed.write(to: feedFile, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: feedFile.path)
      guard let asset = response.assets.first(where: {
        $0.name == verified.downloadURL.lastPathComponent && $0.size == verified.archiveLength && $0.id > 0
      }) else { throw problem("The signed update does not match the release archive.") }
      guard verifyDelivery || verified.build.compare(currentBuild, options: .numeric) == .orderedDescending else {
        say("You’re up to date. Latest verified release: " + verified.version + ".", manual: manual)
        stopServer(); return
      }
      say("Downloading and verifying " + verified.version + "…", manual: manual)
      _ = try await run(["download", "--repository", repository, "--asset-id", String(asset.id),
        "--output", directory.appendingPathComponent("update.zip").path,
        "--max-bytes", String(verified.archiveLength)])
      let archive = try Data(contentsOf: directory.appendingPathComponent("update.zip"), options: .mappedIfSafe)
      try verified.verify(archive: archive, publicKey: publicKey)
      let capability = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      let (process, port) = try await startServer(directory: directory, token: capability)
      server = process; manifest = verified
      localFeed = URL(string: "http://127.0.0.1:\(port)/\(capability)/appcast.xml")
      localArchive = URL(string: "http://127.0.0.1:\(port)/\(capability)/update.zip")
      let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
      updater.updater.automaticallyChecksForUpdates = false
      updater.updater.automaticallyDownloadsUpdates = false
      try updater.updater.start()
      controller = updater
      if verifyDelivery {
        guard let localArchive else { throw problem("The verified local archive is unavailable.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (delivered, response) = try await session.data(from: localArchive)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw problem("Local update delivery failed.") }
        try verified.verify(archive: delivered, publicKey: publicKey)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          deliveryProbe = continuation
          updater.updater.checkForUpdateInformation()
          Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, let continuation = self.deliveryProbe else { return }
            self.deliveryProbe = nil; continuation.resume(throwing: self.problem("Sparkle feed verification timed out."))
          }
        }
        deliveryVerified = true
        say("Private update feed, archive delivery, and Sparkle signature checks passed.", manual: manual)
        stopServer(); return
      }
      say("Verified update ready: " + verified.version + ".", manual: manual)
      if manual { updater.checkForUpdates(nil) } else { updater.updater.checkForUpdatesInBackground() }
    } catch {
      stopServer()
      say("Update check: " + error.localizedDescription, manual: manual)
    }
  }

  func feedURLString(for updater: SPUUpdater) -> String? { localFeed?.absoluteString }

  func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
    guard let continuation = deliveryProbe else { return }
    deliveryProbe = nil
    if appcast.items.contains(where: { $0.versionString == manifest?.build && $0.fileURL == manifest?.downloadURL }) {
      continuation.resume()
    } else { continuation.resume(throwing: problem("Sparkle did not load the verified release.")) }
  }

  func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
    // The signed remote enclosure is the identity; only its transport is replaced.
    guard item.fileURL == manifest?.downloadURL, let localArchive else {
      request.url = nil; return
    }
    request.url = localArchive
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    request.setValue(nil, forHTTPHeaderField: "Cookie")
    UserDefaults.standard.set(item.versionString, forKey: "privateUpdates.restartHelperForBuild")
  }

  func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { updateAwaitingInstallation = true }

  func userDidCancelDownload(_ updater: SPUUpdater) { clearDeferredInstall() }

  func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
    guard mayRelaunch?() == true else {
      pendingInstall = installHandler
      say("Update ready. Finish pending approvals and supervised tasks before restarting.", manual: true)
      deferredInstallTask?.cancel()
      deferredInstallTask = Task { [weak self] in
        while let self, self.pendingInstall != nil {
          try? await Task.sleep(nanoseconds: 2_000_000_000)
          if Task.isCancelled { return }
          if self.mayRelaunch?() == true {
            let handler = self.pendingInstall; self.pendingInstall = nil; handler?(); return
          }
        }
      }
      return true
    }
    return false
  }

  func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    // Replacement occurs after termination. The new app restarts the helper safely.
    if let manifest { UserDefaults.standard.set(manifest.build, forKey: "privateUpdates.restartHelperForBuild") }
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    clearDeferredInstall()
    if let continuation = deliveryProbe { deliveryProbe = nil; continuation.resume(throwing: error) }
    say("Update: " + error.localizedDescription, manual: false)
  }

  private func say(_ value: String, manual: Bool) { status = value; if manual { onStatus?(value) } }
  private func problem(_ message: String) -> NSError { NSError(domain: "PrivateUpdates", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

  private func stopServer() {
    clearDeferredInstall()
    if server?.isRunning == true { server?.terminate() }
    server = nil; controller = nil; localFeed = nil; localArchive = nil; manifest = nil
    if let cache { try? FileManager.default.removeItem(at: cache) }
    cache = nil
  }

  private func clearDeferredInstall() {
    deferredInstallTask?.cancel(); deferredInstallTask = nil
    pendingInstall = nil; updateAwaitingInstallation = false
  }

  /// Runs in the newly launched bundle, after Sparkle's replacement is complete.
  private func recoverServiceAfterUpdate() async -> Bool {
    guard let expected = UserDefaults.standard.string(forKey: "privateUpdates.restartHelperForBuild"),
      PrivateUpdateRestartPolicy.applies(expectedBuild: expected, currentBuild: currentBuild) else { return true }
    do {
      let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/AgentDeck/connection.json")
      let connection = try JSONDecoder().decode(ServiceConnection.self, from: Data(contentsOf: file))
      guard (1...65535).contains(connection.port), !connection.token.isEmpty,
        connection.token.count <= 4096, let birth = ProcessWitness.readBirth(connection.servicePid) else { return false }
      func read(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(connection.port)\(path)")!)
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization"); request.timeoutInterval = 4
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4 * 1024 * 1024 else { throw problem("Service restart is waiting for a verified connection.") }
        return data
      }
      let snapshot = try JSONDecoder().decode(DeckSnapshot.self, from: await read("/status"))
      let tasks = try JSONDecoder().decode([SupervisedTask].self, from: await read("/supervisor/tasks"))
      guard PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: snapshot.requests.count,
        busy: mayRelaunch?() != true, tasks: tasks, managedSessions: Array(snapshot.sessions.values), processIsAlive: Self.taskProcessIsAlive) else {
        status = "Updated app is ready. Finish current approvals and supervised tasks before its service restarts."
        return false
      }
      let label = "gui/\(getuid())/com.aiagentdeck.service"
      let process = Process(), output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = ["print", label]
      process.standardOutput = output; process.standardError = FileHandle.nullDevice
      try process.run(); let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
      guard process.terminationStatus == 0,
        PrivateUpdateRestartPolicy.launchdServiceMatches(text, pid: connection.servicePid,
          programPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DeckService.bundle/Contents/MacOS/deck-service").path),
        ProcessWitness.readBirth(connection.servicePid) == birth else { return false }
      let restart = Process(); restart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      restart.arguments = ["kickstart", "-k", label]
      restart.standardOutput = FileHandle.nullDevice; restart.standardError = FileHandle.nullDevice
      try restart.run(); restart.waitUntilExit()
      guard restart.terminationStatus == 0 else { return false }
      UserDefaults.standard.removeObject(forKey: "privateUpdates.restartHelperForBuild")
      return true
    } catch { return false }
  }

  private struct ServiceConnection: Decodable { let port: Int; let token: String; let servicePid: Int }

  private struct Asset: Decodable { let id: Int; let name: String; let size: Int }
  private struct Release: Decodable { let index: Int; let tag: String; let assets: [Asset] }
  private struct Releases: Decodable { let releases: [Release] }

  private func run(_ arguments: [String]) async throws -> Data {
    let script = helper.path
    return try await Task.detached(priority: .utility) {
      let process = Process(), output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = [script] + arguments
      process.standardOutput = output; process.standardError = FileHandle.nullDevice
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        throw NSError(domain: "PrivateUpdates", code: 1,
          userInfo: [NSLocalizedDescriptionKey: envelope?["error"] ?? "GitHub access failed. Run gh auth login in Terminal, then check again."])
      }
      return data
    }.value
  }

  private func startServer(directory: URL, token: String) async throws -> (Process, Int) {
    let script = helper.path
    return try await Task.detached(priority: .utility) {
      let process = Process(), output = Pipe(), input = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = [script, "serve", "--directory", directory.path]
      process.standardOutput = output; process.standardInput = input; process.standardError = FileHandle.nullDevice
      try process.run()
      try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["token": token]))
      try input.fileHandleForWriting.close()
      var data = Data()
      while data.count < 4096 {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }; data.append(chunk)
        if data.contains(10) { break }
      }
      guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
        let port = response["port"], (1...65535).contains(port), process.isRunning else {
        if process.isRunning { process.terminate() }
        throw NSError(domain: "PrivateUpdates", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Could not prepare the verified update download."])
      }
      return (process, port)
    }.value
  }
}

struct PrivateUpdateSettingsPanel: View {
  @ObservedObject var updates: PrivateUpdateController
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Private release updates").font(.headline)
      Text(updates.status).font(.caption).textSelection(.enabled)
      Toggle("Check automatically every 6 hours", isOn: $updates.automatic)
      Toggle("Include preview releases", isOn: $updates.includePreviews)
      Button(updates.checking ? "Checking…" : "Check now") { Task { await updates.check(manual: true) } }
        .disabled(updates.checking)
      HStack {
        Button("Copy GitHub sign-in command") {
          NSPasteboard.general.clearContents(); NSPasteboard.general.setString("gh auth login --hostname github.com", forType: .string)
        }
        Button("Open Terminal") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
      }
      Text("Uses your GitHub sign-in on this Mac. Each feed and download must pass signature verification before an update is offered.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}
