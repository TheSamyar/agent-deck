import AppKit
import XCTest
@testable import DeckCore

final class MasterHUBTests: XCTestCase {
  @MainActor func testBothScreenSizesEncodeAsDecodableJPEGs() throws {
    for size in [72, 240] {
      let data = try XCTUnwrap(MasterHUBArtwork.jpeg(title: "Agent Deck", subtitle: "Working", state: "WORKING", size: size))
      let image = try XCTUnwrap(NSBitmapImageRep(data: data))
      XCTAssertEqual(image.pixelsWide, size)
      XCTAssertEqual(image.pixelsHigh, size)
      XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xd8])
    }
  }
  func testRotarySettingsRoundTripAndRejectIncompleteControlLists() throws {
    var controls = MasterHUBRotaryControls()
    controls.bindings[2].turn = .zoom
    controls.bindings[2].reversed = true
    let decoded = try JSONDecoder().decode(MasterHUBRotaryControls.self, from: JSONEncoder().encode(controls))
    XCTAssertEqual(decoded, controls)
    XCTAssertTrue(decoded.valid)
    controls.bindings.removeLast()
    XCTAssertFalse(controls.valid)
  }
  func testThreeKnobRotationAndPressFrames() {
    var decoder = MasterHUBKnobDecoder()
    XCTAssertEqual(decoder.decode([1, 0x2a, 5, 0, 0, 3, 1, 255, 0]),
      [.rotated(index: 0, delta: 1), .rotated(index: 2, delta: -1)])
    let press: [UInt8] = [1, 0x2a, 5, 0, 3, 3, 0, 1, 0]
    XCTAssertEqual(decoder.decode(press), [.button(index: 1, pressed: true)])
    XCTAssertTrue(decoder.decode(press).isEmpty)
    XCTAssertTrue(decoder.decode([1, 0x2a, 5, 0, 3, 3, 0, 0, 9]).isEmpty)
    XCTAssertTrue(decoder.decode(press).isEmpty, "Invalid later controls must not partially release earlier controls")
    XCTAssertEqual(decoder.decode([1, 0x2a, 5, 0, 3, 3, 0, 0, 0]), [.button(index: 1, pressed: false)])
    XCTAssertTrue(decoder.decode([1, 0x2a, 5, 0, 3, 3]).isEmpty)
  }
  func testScreenDialUsesDifferentDirectionConventionAndDeduplicatesButtons() {
    var decoder = MasterHUBScreenDialDecoder()
    XCTAssertEqual(decoder.decode([1, 0x44, 3, 0, 3, 1, 0]), [.rotated(index: 0, delta: 1)])
    XCTAssertEqual(decoder.decode([1, 0x44, 3, 0, 0, 1, 1]), [.rotated(index: 0, delta: -1)])
    XCTAssertEqual(decoder.decode([1, 0x44, 3, 0, 4, 1, 1]), [.button(index: 0, pressed: true)])
    XCTAssertTrue(decoder.decode([1, 0x44, 3, 0, 4, 1, 1]).isEmpty)
    XCTAssertTrue(decoder.decode([1, 0x44, 3, 0, 4, 1, 3]).isEmpty)
    XCTAssertEqual(decoder.decode([1, 0x44, 3, 0, 1, 1, 0]), [.button(index: 0, pressed: false)])
    XCTAssertTrue(decoder.decode([1, 0x45, 3, 0, 3, 1, 0]).isEmpty)
    XCTAssertTrue(decoder.decode([1, 0x44, 9, 0, 3, 1, 0]).isEmpty)
  }
  func testBothDisplayPacketFormatsReassembleAndZeroPadFinalChunk() throws {
    let data = Data((0..<1000).map { UInt8($0 % 251) })
    for target in [MasterHUBImageReports.Target.key(14), .screenDial] {
      let packets = try XCTUnwrap(MasterHUBImageReports.packets(data, target: target, reportLength: 320))
      XCTAssertEqual(packets.count, 4)
      var recovered = Data()
      for (sequence, packet) in packets.enumerated() {
        XCTAssertEqual(packet.count, 320)
        XCTAssertEqual(Int(packet[2]) | Int(packet[3]) << 8, sequence)
        XCTAssertEqual(packet[7], sequence == packets.count - 1 ? 1 : 0)
        let count = Int(packet[4]) | Int(packet[5]) << 8
        recovered.append(contentsOf: packet[8..<(8 + count)])
        XCTAssertTrue(packet[(8 + count)...].allSatisfy { $0 == 0 })
      }
      XCTAssertEqual(recovered, data)
    }
    XCTAssertEqual(MasterHUBImageReports.packets(data, target: .screenDial, reportLength: 320)?.first?[1], 0x45)
    XCTAssertEqual(MasterHUBImageReports.packets(data, target: .key(14), reportLength: 320)?.first?[6], 14)
    XCTAssertNil(MasterHUBImageReports.packets(data, target: .key(15), reportLength: 320))
    XCTAssertNil(MasterHUBImageReports.packets(data, target: .screenDial, reportLength: 8))
    XCTAssertNil(MasterHUBImageReports.packets(Data(), target: .screenDial, reportLength: 320))
  }
  func testRollerDirectionsRepeatedTicksAndInvalidReports() {
    let packet: [UInt8] = [1, 0x2a, 4, 0, 1, 2, 0, 255]
    XCTAssertEqual(MasterHUBRollerDecoder.decode(packet).first?.delta, 1)
    XCTAssertEqual(MasterHUBRollerDecoder.decode(packet).first?.delta, 1)
    XCTAssertEqual(MasterHUBRollerDecoder.decode([1, 0x2a, 4, 0, 1, 2, 255, 1]).first?.roller, 1)
    XCTAssertTrue(MasterHUBRollerDecoder.decode([1, 0x2a, 4, 0, 1, 2, 0, 3]).isEmpty)
    XCTAssertTrue(MasterHUBRollerDecoder.decode(Array(packet.prefix(7))).isEmpty)
    XCTAssertTrue(MasterHUBRollerDecoder.decode([1, 0x2b, 4, 0, 1, 2, 0, 0]).isEmpty)
  }
  func testTransitionsPaddingAndDuplicateReports() {
    var decoder = MasterHUBKeyDecoder()
    var packet: [UInt8] = [1, 0x34, 17, 0, 2, 15] + Array(repeating: 0, count: 15)
    packet[20] = 1
    XCTAssertEqual(decoder.decode(packet + [0, 0]).map(\.key), [14])
    XCTAssertTrue(decoder.decode(packet).isEmpty)
    packet[20] = 0
    XCTAssertEqual(decoder.decode(packet).first?.pressed, false)
  }
  func testMalformedPacketPreservesHeldState() {
    var decoder = MasterHUBKeyDecoder()
    var packet: [UInt8] = [1, 0x34, 17, 0, 2, 15] + Array(repeating: 0, count: 15)
    packet[6] = 1
    XCTAssertEqual(decoder.decode(packet).count, 1)
    var invalid = packet
    invalid[7] = 2
    XCTAssertTrue(decoder.decode(invalid).isEmpty)
    XCTAssertTrue(decoder.decode(Array(packet.prefix(10))).isEmpty)
    XCTAssertTrue(decoder.decode(packet).isEmpty)
    decoder.reset()
    XCTAssertEqual(decoder.decode(packet).count, 1)
  }
}
