import DeckCore
import Foundation
import IOKit.hid

func masterHUBCheckDevice(_ module: String, _ device: IOHIDDevice?) -> MasterHUBCheckDevice {
  func number(_ key: String) -> Int? {
    guard let device else { return nil }
    return (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
  }
  return .init(module: module, connected: device != nil,
    vendorID: number(kIOHIDVendorIDKey), productID: number(kIOHIDProductIDKey), locationID: number(kIOHIDLocationIDKey))
}
