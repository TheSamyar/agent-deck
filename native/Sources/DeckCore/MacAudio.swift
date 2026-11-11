import CoreAudio
import Foundation

/// Uses the current output device, avoiding AppleScript/Automation permissions.
public enum MacAudio {
  private static func output() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var device: AudioDeviceID = 0
    var size = UInt32(MemoryLayout.size(ofValue: device))
    let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    guard result == noErr, device != 0 else { throw Failure("No audio output device is available.") }
    return device
  }
  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
  private static func channels(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyAddress] {
    let available = (0...2).compactMap { element -> AudioObjectPropertyAddress? in
      var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: UInt32(element))
      var writable = DarwinBoolean(false)
      guard AudioObjectHasProperty(device, &address),
        AudioObjectIsPropertySettable(device, &address, &writable) == noErr, writable.boolValue else { return nil }
      return address
    }
    if let main = available.first(where: { $0.mElement == 0 }) { return [main] }
    return available
  }
  public static func adjustVolume(by delta: Float32) throws {
    let device = try output()
    let addresses = channels(device, kAudioDevicePropertyVolumeScalar)
    guard !addresses.isEmpty else { throw Failure("This audio output has fixed volume. Use its hardware volume control or select an adjustable output in Sound settings.") }
    for var address in addresses {
      var value: Float32 = 0
      var size = UInt32(MemoryLayout.size(ofValue: value))
      guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { throw Failure("Could not read output volume.") }
      value = min(1, max(0, value + delta))
      guard AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr else { throw Failure("Could not change output volume.") }
    }
  }
  public static func toggleMute() throws {
    let device = try output()
    let addresses = channels(device, kAudioDevicePropertyMute)
    guard !addresses.isEmpty else { throw Failure("This audio output does not support software mute.") }
    var first = addresses[0], muted: UInt32 = 0
    var size = UInt32(MemoryLayout.size(ofValue: muted))
    guard AudioObjectGetPropertyData(device, &first, 0, nil, &size, &muted) == noErr else { throw Failure("Could not read output mute.") }
    muted = muted == 0 ? 1 : 0
    for var address in addresses {
      guard AudioObjectSetPropertyData(device, &address, 0, nil, size, &muted) == noErr else { throw Failure("Could not change output mute.") }
    }
  }
}
