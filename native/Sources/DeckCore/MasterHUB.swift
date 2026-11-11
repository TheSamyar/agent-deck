import Foundation

/// MasterHUB M4315 input framing, independently implemented from protocol notes.
/// Reference: github.com/goniszewski/OpenStreamHub (MIT/Apache-2.0).
public struct MasterHUBKeyDecoder {
  public static let vendorID = 0x2516
  public static let keypadID = 0x01fe
  public static let rollerID = 0x0204
  public struct Transition: Equatable {
    public let key: Int
    public let pressed: Bool
  }
  private var keys = Array(repeating: false, count: 15)
  public init() {}
  public mutating func reset() { keys = Array(repeating: false, count: 15) }
  /// Unknown or malformed packets never change the held-key state.
  public mutating func decode(_ report: [UInt8]) -> [Transition] {
    guard report.count >= 4, report[0] == 1, report[1] == 0x34 else { return [] }
    let length = Int(report[2]) | Int(report[3]) << 8
    guard length == 17, report.count >= 4 + length,
      report[4] == 0 || report[4] == 2, report[5] == 15,
      report[6..<21].allSatisfy({ $0 <= 1 }) else { return [] }
    var events: [Transition] = []
    for key in 0..<15 {
      let pressed = report[6 + key] == 1
      if keys[key] != pressed { events.append(.init(key: key, pressed: pressed)) }
      keys[key] = pressed
    }
    return events
  }
}

/// M032LE reports are discrete directions; identical packets are separate ticks.
public enum MasterHUBRollerDecoder {
  public struct Rotation: Equatable {
    public let roller: Int
    public let delta: Int
  }
  public static func decode(_ report: [UInt8]) -> [Rotation] {
    guard report.count >= 8, report[0] == 1, report[1] == 0x2a,
      report[2] == 4, report[3] == 0, report[4] == 1, report[5] == 2,
      report[6...7].allSatisfy({ $0 == 0 || $0 == 1 || $0 == 255 }) else { return [] }
    return (0..<2).compactMap { index in
      report[6 + index] == 255 ? nil : Rotation(roller: index, delta: report[6 + index] == 0 ? 1 : -1)
    }
  }
}

public enum MasterHUBEncoderEvent: Equatable, Sendable {
  case rotated(index: Int, delta: Int)
  case button(index: Int, pressed: Bool)
}

private func masterHUBPayload(_ report: [UInt8], channel: UInt8) -> [UInt8]? {
  guard report.count >= 4, report[0] == 1, report[1] == channel else { return nil }
  let count = Int(report[2]) | Int(report[3]) << 8
  guard count > 0, count <= report.count - 4 else { return nil }
  return Array(report[4..<(4 + count)])
}

public struct MasterHUBKnobDecoder {
  private var pressed = [false, false, false]
  public init() {}
  public mutating func reset() { pressed = [false, false, false] }
  public mutating func decode(_ report: [UInt8]) -> [MasterHUBEncoderEvent] {
    guard let payload = masterHUBPayload(report, channel: 0x2a), payload.count == 5,
      payload[1] == 3, payload[0] == 0 || payload[0] == 3 else { return [] }
    let rotation = payload[0] == 0
    guard payload[2...4].allSatisfy({ $0 <= 1 || (rotation && $0 == 255) }) else { return [] }
    var events: [MasterHUBEncoderEvent] = []
    for index in 0..<3 {
      let value = payload[2 + index]
      if rotation {
        if value != 255 { events.append(.rotated(index: index, delta: value == 1 ? 1 : -1)) }
      } else if pressed[index] != (value == 1) {
        pressed[index] = value == 1
        events.append(.button(index: index, pressed: pressed[index]))
      }
    }
    return events
  }
}

public struct MasterHUBScreenDialDecoder {
  private var pressed = false
  public init() {}
  public mutating func reset() { pressed = false }
  public mutating func decode(_ report: [UInt8]) -> [MasterHUBEncoderEvent] {
    guard let payload = masterHUBPayload(report, channel: 0x44), payload.count >= 3 else { return [] }
    let selector = payload[0], value = payload[2]
    if (selector == 0 || selector == 3), value <= 1 {
      return [.rotated(index: 0, delta: value == 0 ? 1 : -1)]
    }
    if (selector == 4 && value <= 1) || (selector == 1 && value == 0) {
      let next = value == 1
      guard next != pressed else { return [] }
      pressed = next
      return [.button(index: 0, pressed: next)]
    }
    return []
  }
}

public enum MasterHUBImageReports {
  public enum Target { case key(Int), screenDial }
  public static func packets(_ data: Data, target: Target, reportLength: Int) -> [[UInt8]]? {
    guard reportLength > 8, reportLength <= 65535, !data.isEmpty, data.count <= 4 * 1024 * 1024 else { return nil }
    let command: UInt8, key: UInt8
    switch target {
    case .key(let index):
      guard (0..<15).contains(index) else { return nil }
      command = 0x36; key = UInt8(index)
    case .screenDial: command = 0x45; key = 0
    }
    let capacity = reportLength - 8, bytes = Array(data)
    guard (bytes.count + capacity - 1) / capacity <= 65536 else { return nil }
    return stride(from: 0, to: bytes.count, by: capacity).enumerated().map { sequence, offset in
      let count = min(capacity, bytes.count - offset)
      var report = [UInt8](repeating: 0, count: reportLength)
      report[0] = 2; report[1] = command
      report[2] = UInt8(sequence & 255); report[3] = UInt8(sequence >> 8)
      report[4] = UInt8(count & 255); report[5] = UInt8(count >> 8)
      report[6] = key; report[7] = offset + count == bytes.count ? 1 : 0
      report.replaceSubrange(8..<(8 + count), with: bytes[offset..<(offset + count)])
      return report
    }
  }
}
