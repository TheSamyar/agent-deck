import Combine
import DeckCore
import Foundation

/// Dedicated acoustic detection owns idle capture; speech recognition starts only after a candidate.
/// Only finalized, anchored Hey Alfred utterances reach the command router.
@MainActor final class RobinWakeListener: ObservableObject {
  @Published private(set) var status = "Wake word off · microphone off"
  @Published private(set) var listening = false
  @Published private(set) var suspended = false
  var onCommand: (RobinWakeCommand) -> Void = { _ in }
  private let voice = SupervisorVoice()
  private let runtime = AlfredWakeRuntime()
  private var subscriptions = Set<AnyCancellable>()
  private(set) var hearingSpeech = false
  private var captureOwned = false
  private var recognizing = false
  private var finalizing = false
  private var failed = false
  var inputLevel: Float { voice.inputLevel }
  var recognitionHasText: Bool { recognizing && !voice.text.isEmpty }
  var healthStatus: String { status }
  private var generation = UUID()
  private var silence: Task<Void, Never>?
  private var deadline: Task<Void, Never>?

  init() {
    runtime.onDetection = { [weak self] preroll in self?.verify(preroll) }
    runtime.onError = { [weak self] message in
      guard let self, self.captureOwned else { return }
      self.failed = true; self.pause(message: message)
    }
    voice.onFinalText = { [weak self] text in
      guard let self, self.captureOwned, self.recognizing else { return }
      self.captureOwned = false; self.recognizing = false; self.finalizing = false
      self.listening = false; self.hearingSpeech = false; self.cancelTimers()
      self.status = "Wake microphone paused"
      let command = RobinWakeCommand.parse(text)
      if command != .ignore { self.onCommand(command) }
    }
    voice.$text.removeDuplicates().dropFirst().sink { [weak self] text in
      guard let self, self.captureOwned, self.recognizing, !self.finalizing, !text.isEmpty else { return }
      self.silence?.cancel(); let id = self.generation
      self.silence = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, self.generation == id else { return }
        self.finalize()
      }
    }.store(in: &subscriptions)
    voice.$error.dropFirst().sink { [weak self] error in
      guard let self, !error.isEmpty, self.captureOwned else { return }
      self.failed = true; self.pause(message: error)
    }.store(in: &subscriptions)
  }
  func suspend() { suspended = true; pause(message: "Wake paused · microphone off · Resume to listen") }
  func resume() { suspended = false; failed = false; status = "Wake ready · microphone off" }
  func pause(message: String = "Wake paused · microphone off") {
    generation = UUID(); cancelTimers(); runtime.stop()
    if captureOwned { voice.stop() }
    captureOwned = false; recognizing = false; finalizing = false
    listening = false; hearingSpeech = false; status = message
  }
  func update(enabled: Bool, available: Bool) {
    guard enabled else {
      failed = false
      if captureOwned || listening || status != "Wake word off · microphone off" { pause(message: "Wake word off · microphone off") }
      return
    }
    guard !suspended, !failed else { return }
    guard available else { if captureOwned { pause() }; return }
    guard !captureOwned, !finalizing else { return }
    captureOwned = true; generation = UUID(); let id = generation
    status = "Loading dedicated Alfred detector · microphone off"
    Task { [weak self] in
      guard let self, self.generation == id else { return }
      do { try await self.runtime.start() }
      catch {
        guard self.generation == id else { return }
        self.failed = true; self.pause(message: error.localizedDescription); return
      }
      guard self.generation == id else { return }
      let transport = self.runtime.transport
      await self.voice.startWakeCapture { transport.submit($0) }
      guard self.generation == id else { return }
      guard self.voice.listening else {
        self.failed = true; self.pause(message: self.voice.error.isEmpty ? "Wake microphone unavailable · Resume to retry" : self.voice.error); return
      }
      self.listening = true; self.status = "Hey Alfred detector on · community model · on this Mac"
    }
  }
  private func verify(_ preroll: Data) {
    guard captureOwned, listening, !recognizing, !preroll.isEmpty else { return }
    runtime.stop(); voice.stop(); listening = false; recognizing = true; hearingSpeech = true
    status = "Wake candidate · verifying Hey Alfred"
    let id = generation
    Task { [weak self] in
      guard let self, self.generation == id else { return }
      await self.voice.start(initialPCM: preroll)
      guard self.generation == id else { return }
      guard self.voice.listening else { self.failed = true; self.pause(message: self.voice.error); return }
      self.deadline = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(8)) } catch { return }
        guard let self, self.generation == id else { return }
        self.finalize()
      }
    }
  }
  private func finalize() {
    guard recognizing, !finalizing else { return }
    silence?.cancel(); deadline?.cancel(); finalizing = true
    status = "Checking finalized wake phrase · microphone off"; voice.finishUtterance()
    let id = generation
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      guard let self, self.generation == id else { return }
      self.failed = true; self.pause(message: "Wake phrase was not finalized · microphone off · Resume to retry")
    }
  }
  private func cancelTimers() { silence?.cancel(); deadline?.cancel() }
}
