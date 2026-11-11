import SwiftUI
import AppKit
import DeckCore

/// Exercises real turn-taking capture/playback without calling a model or executing tasks.
struct RobinAcousticTestPanel: View {
  @StateObject private var exchange = RobinConversationExchange()
  @ObservedObject private var audio = SupervisorAudio.shared
  let stopOtherAudio: () -> Void
  let configuration: SupervisorConfiguration
  var onFinished: () -> Void = {}
  @State private var stage = 0
  @State private var firstPhrase = false
  @State private var replyPhrase = false
  @State private var recovery = false
  @State private var playbackHeard = false
  @State private var otherAudioConfirmed = false
  @State private var overlappingCapture = false
  @State private var status = "Not tested. Requires your microphone and speakers."
  @State private var report = ""
  @State private var deadline: Task<Void, Never>?

  var body: some View {
    GroupBox("Real microphone + speaker test") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Local audio only. No AI request, cloud upload, or task execution. Spoken interruption is disabled; Alfred takes turns.").font(.caption)
        Text(status)
        ProgressView(value: Double(exchange.inputLevel)).accessibilityLabel("Actual microphone input")
        Text(exchange.transcript.isEmpty ? exchange.phase : exchange.transcript).font(.caption)
        HStack {
          Button("Start spoken test") { start() }.disabled(stage > 0 && stage < 4)
          Button("Cancel / mute") { cancel() }.disabled(stage == 0 || stage == 4)
          if stage == 3 {
            Button("Resume recovery") {
              status = "Say: Ready again."
              exchange.resume(configuration: configuration)
              armDeadline()
            }
          }
        }
        Toggle("I heard Alfred's reply clearly, with no self-conversation", isOn: $playbackHeard).disabled(!replyPhrase)
        Toggle("My music and Discord audio stayed normal during this test", isOn: $otherAudioConfirmed).disabled(!replyPhrase)
        Button("Save test report") { saveReport() }
        if !report.isEmpty { Text(report).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
      }
      .onChange(of: audio.capture) { _, capture in
        if capture && exchange.phase == "Speaking" { overlappingCapture = true }
      }
      .onChange(of: exchange.phase) { _, phase in
        if phase == "Speaking" && audio.capture { overlappingCapture = true }
      }
      .onDisappear { cancel() }
      .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in cancel() }
      .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in cancel() }
    }
  }

  private func start() {
    stopOtherAudio(); exchange.stop(); deadline?.cancel()
    stage = 1; firstPhrase = false; replyPhrase = false; recovery = false
    playbackHeard = false; otherAudioConfirmed = false; overlappingCapture = false; report = ""
    status = "Say: Alfred voice test."
    exchange.startSession(configuration: configuration, onAnswer: receive, onInterrupt: {}, onLater: { cancel() })
    armDeadline()
  }

  private func receive(_ text: String) {
    deadline?.cancel()
    let normalized = text.lowercased()
    if stage == 1 {
      guard normalized.contains("alfred"), normalized.contains("test") else {
        status = "Phrase was not recognized. Restart and say: Alfred voice test."
        finish(); return
      }
      firstPhrase = true; stage = 2
      status = "Listen to Alfred. Wait for Listening, then say: Alfred ready."
      var speaking = configuration; speaking.speakReplies = true
      exchange.respond(text: "This is Alfred's turn-taking test. My microphone is off while I speak. When the screen says Listening, say Alfred ready.", configuration: speaking)
      armDeadline(seconds: 45)
    } else if stage == 2 {
      guard normalized.contains("alfred"), normalized.contains("ready") else {
        status = "Reply phrase was not recognized; restart the test."
        finish(); return
      }
      replyPhrase = true; stage = 3; exchange.pause(message: "Microphone off · recovery test")
      status = "Microphone muted. Press Resume recovery, then say: Ready again."
    } else if stage == 3 {
      recovery = normalized.contains("ready") && normalized.contains("again")
      status = recovery ? "Capture and recovery complete. Confirm what you actually heard, then save the report." : "Recovery phrase was not recognized; restart the test."
      finish()
    }
  }

  private func armDeadline(seconds: Double = 20) {
    deadline?.cancel()
    deadline = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      status = "No completed answer in \(Int(seconds)) seconds. Microphone off; test incomplete."
      finish()
    }
  }

  private func finish() {
    deadline?.cancel(); exchange.stop(); stage = 4; onFinished(); saveReport()
  }

  private func cancel() {
    deadline?.cancel(); exchange.stop()
    if stage > 0 && stage < 4 { status = "Cancelled. Microphone off; incomplete checks remain incomplete." }
    if stage > 0 { stage = 4; onFinished() }
  }

  private func saveReport() {
    let values: [String: Any] = [
      "recognition": firstPhrase ? "passed" : "missing",
      "postPlaybackRecognition": replyPhrase ? "passed" : "missing",
      "muteRecovery": recovery ? "passed" : "missing",
      "captureDuringPlayback": overlappingCapture,
      "playbackUserConfirmed": playbackHeard,
      "musicAndDiscordUserConfirmed": otherAudioConfirmed,
      "inputDevice": audio.inputDeviceName,
      "spokenInterruption": "disabled: turn-taking default",
      "physicalAcousticLatencyMeasured": false,
      "guidedChecksComplete": firstPhrase && replyPhrase && recovery && !overlappingCapture && playbackHeard && otherAudioConfirmed
    ]
    report = String(decoding: (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted])) ?? Data(), as: UTF8.self)
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/AgentDeck")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let url = directory.appendingPathComponent("robin-acoustic-test.json")
      try Data(report.utf8).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch { status = "Could not save the test report; results remain visible." }
  }
}
