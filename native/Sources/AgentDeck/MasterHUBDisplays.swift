import AppKit
import DeckCore
import IOKit.hid

private final class DisplayLease: @unchecked Sendable {
  private let lock = NSLock()
  private var valid = true
  func cancel() { lock.lock(); valid = false; lock.unlock() }
  var active: Bool { lock.lock(); defer { lock.unlock() }; return valid }
}

/// One serial USB writer. Owners allow one frame in flight and keep only their
/// newest desired surface, so animations cannot build an unbounded write queue.
@MainActor enum MasterHUBDisplays {
  private static let queue = DispatchQueue(label: "com.aiagentdeck.display", qos: .userInitiated)
  static private(set) var frames = 0
  static private(set) var lastFrameMilliseconds: Double = 0
  static private(set) var maximumFrameMilliseconds: Double = 0
  private static var leases: [UInt: DisplayLease] = [:]
  private static func key(_ device: IOHIDDevice) -> UInt { UInt(IOHIDDeviceGetService(device)) }
  static func invalidate(_ device: IOHIDDevice) {
    leases.removeValue(forKey: key(device))?.cancel()
    // Teardown alone waits for the current packet before closing its IOHID handle.
    queue.sync {}
  }
  static func sendFrame(_ images: [(Data, MasterHUBImageReports.Target)], device: IOHIDDevice) async -> Bool {
    let length = (IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
    var packets: [[UInt8]] = []
    for (jpeg, target) in images {
      guard let imagePackets = MasterHUBImageReports.packets(jpeg, target: target, reportLength: length) else { return false }
      packets += imagePackets
    }
    let id = key(device)
    let lease = leases[id] ?? DisplayLease(); leases[id] = lease
    let start = ProcessInfo.processInfo.systemUptime
    let success: Bool = await withCheckedContinuation { continuation in
      queue.async {
        for packet in packets {
          guard lease.active else { continuation.resume(returning: false); return }
          let result = packet.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 2, $0.baseAddress!, $0.count)
          }
          guard result == kIOReturnSuccess else { continuation.resume(returning: false); return }
        }
        continuation.resume(returning: lease.active)
      }
    }
    lastFrameMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
    maximumFrameMilliseconds = max(maximumFrameMilliseconds, lastFrameMilliseconds)
    frames += 1
    return success
  }
}
