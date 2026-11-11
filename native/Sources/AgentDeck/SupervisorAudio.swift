import AVFoundation
import CoreAudio
import AudioToolbox
import Foundation
import Combine

/// Shared local capture/playback graph gives macOS voice processing the output reference.
@MainActor final class SupervisorAudio: ObservableObject {
  static let shared = SupervisorAudio()
  let engine = AVAudioEngine()
  let player = AVAudioPlayerNode()
  @Published private(set) var capture = false
  @Published private(set) var playback = false
  private var processing = false
  var processingEnabled: Bool { processing }
  @Published private(set) var deviceChangeError = ""
  private var engineObserver: NSObjectProtocol?
  private init() {
    engine.attach(player)
    let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:24000,channels:1,interleaved:false)!
    engine.connect(player,to:engine.mainMixerNode,format:format)
    engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
      Task { @MainActor in
        guard let self, (self.capture || self.playback), !self.engine.isRunning else { return }
        self.deviceChangeError = "Audio device changed. Alfred audio stopped; press Listen to reconnect."
      }
    }
  }
  @Published private(set) var inputDeviceName = "System input"
  @Published var inputLevel: Float = 0
  var status: String { capture ? "Microphone on · " + inputDeviceName : playback ? "Speaking · microphone off" : "Microphone off" }
  private func inputDeviceError(_ message: String) -> NSError {
    NSError(domain: "AlfredAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  private func transport(of device: AudioDeviceID) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0; var bytes: UInt32 = 4
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &value) == noErr else { return nil }
    return value
  }
  private func selectInput(_ device: AudioDeviceID) throws {
    guard device != kAudioObjectUnknown, let unit = engine.inputNode.audioUnit else {
      throw inputDeviceError("No microphone is available. Connect a built-in, USB, or wired microphone before starting Alfred voice.")
    }
    var device = device
    let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    guard result == noErr else { throw inputDeviceError("Could not select the microphone. Choose a built-in, USB, or wired input before starting Alfred voice.") }
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?; var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    if AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &name) == noErr, let name {
      inputDeviceName = name.takeRetainedValue() as String
    } else { inputDeviceName = "Selected microphone" }
  }
  private func selectBuiltInInput() throws {
    guard !engine.isRunning else { return }
    inputDeviceName = "No input selected"
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var bytes: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes) == noErr, bytes > 0 else {
      throw inputDeviceError("Could not inspect microphone devices. Reconnect your microphone before starting Alfred voice.")
    }
    var devices = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
    let status = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, $0.baseAddress!) }
    guard status == noErr else { throw inputDeviceError("Could not inspect microphone devices. Reconnect your microphone before starting Alfred voice.") }
    for device in devices where transport(of: device) == kAudioDeviceTransportTypeBuiltIn {
      address.mSelector = kAudioDevicePropertyStreams; address.mScope = kAudioDevicePropertyScopeInput
      guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes) == noErr, bytes > 0 else { continue }
      try selectInput(device)
      return
    }
    // On desktop Macs without a built-in mic, use the existing wired/USB input.
    // Never activate a Bluetooth mic automatically: that can change headphone quality.
    address.mSelector = kAudioHardwarePropertyDefaultInputDevice; address.mScope = kAudioObjectPropertyScopeGlobal
    var device = AudioDeviceID(kAudioObjectUnknown); bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &device) == noErr,
      let transport = transport(of: device) else { throw inputDeviceError("Choose a built-in, USB, or wired microphone before starting Alfred voice.") }
    guard transport != kAudioDeviceTransportTypeBluetooth && transport != kAudioDeviceTransportTypeBluetoothLE else {
      throw inputDeviceError("Alfred did not activate your Bluetooth microphone because it can reduce music and Discord audio quality. Choose a built-in, USB, or wired input in Sound settings, then press Listen.")
    }
    try selectInput(device)
  }
  func prepareCapture(voiceProcessing: Bool = false) throws {
    deviceChangeError = ""
    try selectBuiltInInput()
    if processing != voiceProcessing {
      guard !engine.isRunning else {throw NSError(domain:"SupervisorAudio",code:1,userInfo:[NSLocalizedDescriptionKey:"Stop playback before starting the microphone."])}
      try engine.inputNode.setVoiceProcessingEnabled(voiceProcessing)
      processing = voiceProcessing
    }
    if processing {
      engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
    }
  }
  private func stopIfUnused() {
    guard !capture, !playback else { return }
    engine.stop()
    inputLevel = 0
    if processing {
      do { try engine.inputNode.setVoiceProcessingEnabled(false); processing = false }
      catch { NSLog("Alfred audio processing teardown: %@", error.localizedDescription) }
    }
  }
  func beginCapture() throws {capture=true;do{try start()}catch{capture=false;stopIfUnused();throw error}}
  func endCapture() {capture=false;inputLevel=0;stopIfUnused()}
  func beginPlayback() throws {deviceChangeError="";playback=true;do{try start();player.play()}catch{playback=false;stopIfUnused();throw error}}
  func endPlayback() {player.stop();playback=false;stopIfUnused()}
  func enqueueSpeech(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) throws {
    let target=player.outputFormat(forBus:0)
    guard let converter=AVAudioConverter(from:buffer.format,to:target),
      let converted=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:AVAudioFrameCount(Double(buffer.frameLength)*target.sampleRate/buffer.format.sampleRate)+32) else { throw NSError(domain:"RobinAudio",code:2) }
    var consumed=false
    var error:NSError?
    converter.convert(to:converted,error:&error) { _, status in
      if consumed {status.pointee = .noDataNow; return nil}
      consumed=true;status.pointee = .haveData;return buffer
    }
    if let error {throw error}
    guard converted.frameLength>0 else {return}
    player.scheduleBuffer(converted,completionCallbackType:.dataPlayedBack) {_ in completion()}
    try beginPlayback()
  }
  private func start() throws {if !engine.isRunning {engine.prepare();try engine.start()}}
}

/// Audio-thread state only; reports a sustained near-field speech onset.
final class SupervisorSpeechDetector: @unchecked Sendable {
  private(set) var level:Float = 0
  private var voicedFrames = 0
  private var quietFrames = 0
  private(set) var speechActive = false
  private var latched = false
  func process(_ buffer: AVAudioPCMBuffer) -> Bool {
    guard let samples=buffer.floatChannelData?[0],buffer.frameLength>0 else {return false}
    var energy:Float=0
    for index in 0..<Int(buffer.frameLength) {energy += samples[index]*samples[index]}
    level=min(1,sqrt(energy/Float(buffer.frameLength))*8)
    let voiced=level>0.2
    if voiced { voicedFrames += Int(buffer.frameLength); quietFrames = 0 }
    else {
      quietFrames += Int(buffer.frameLength); voicedFrames = 0
      if Double(quietFrames) / buffer.format.sampleRate >= 0.35 { speechActive = false; latched = false }
    }
    if !latched && Double(voicedFrames)/buffer.format.sampleRate>=0.12 { latched = true; speechActive = true; return true }
    return false
  }
}
