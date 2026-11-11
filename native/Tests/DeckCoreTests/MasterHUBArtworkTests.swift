import AppKit
import XCTest
@testable import DeckCore

final class MasterHUBArtworkTests: XCTestCase {
  @MainActor func testClearFramesCanBeReusedWithoutFreezingMotion() throws {
    let first = try XCTUnwrap(MasterHUBArtwork.jpeg(title: "Clear cache fixture", subtitle: "", state: "CLEAR", size: 72, phase: 0))
    XCTAssertEqual(first, MasterHUBArtwork.jpeg(title: "Clear cache fixture", subtitle: "", state: "CLEAR", size: 72, phase: 0))
    let next = try XCTUnwrap(MasterHUBArtwork.jpeg(title: "Clear cache fixture", subtitle: "", state: "CLEAR", size: 72, phase: 0.5))
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { XCTAssertEqual(first, next) }
    else { XCTAssertNotEqual(first, next) }
    XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(data: first)).pixelsWide, 72)
  }
  @MainActor func testQuietDialIsStaticAndDecodable() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    let face = MasterHUBDialPresentation(snapshot: await engine.snapshot())
    XCTAssertEqual(face.project, "All quiet")
    XCTAssertTrue(face.sessionID.isEmpty)
    let data = try XCTUnwrap(MasterHUBArtwork.jpeg(dial: face))
    XCTAssertEqual(data, MasterHUBArtwork.jpeg(dial: face, phase: 0.5))
    let image = try XCTUnwrap(NSBitmapImageRep(data: data))
    XCTAssertEqual(image.pixelsWide, 240)
    XCTAssertEqual(image.pixelsHigh, 240)
    XCTAssertNotEqual(data, MasterHUBArtwork.jpeg(dial: MasterHUBDialPresentation(snapshot: nil)))
    XCTAssertNotNil(MasterHUBArtwork.jpeg(dial: face, robinState: "Listening"))
  }
  @MainActor func testProviderDisplaysHaveDistinctIdentityAndWorkingFrames() throws {
    for size in [72, 240] {
      let render: (String, Double) -> Data? = { provider, phase in
        MasterHUBArtwork.jpeg(title: "Project", subtitle: "Provider\nWorking", state: "WORKING", size: size,
          symbol: "terminal", phase: phase, agentId: provider)
      }
      let codex = try XCTUnwrap(render("codex", 0))
      XCTAssertNotEqual(codex, try XCTUnwrap(render("claude", 0)))
      let nextFrame = try XCTUnwrap(render("codex", 0.25))
      if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        XCTAssertEqual(codex, nextFrame, "Reduce Motion must keep working artwork static")
      } else {
        XCTAssertNotEqual(codex, nextFrame, "Working artwork must animate when Reduce Motion is off")
      }
      let image = try XCTUnwrap(NSBitmapImageRep(data: codex))
      XCTAssertEqual(image.pixelsWide, size)
    }
  }
  @MainActor func testReactorFramesAndStateColors() throws {
    let working = try XCTUnwrap(ReactorArtwork.image(provider: "codex", state: "WORKING", phase: 0)?.tiffRepresentation)
    XCTAssertNotEqual(working, try XCTUnwrap(ReactorArtwork.image(provider: "codex", state: "WAITING", phase: 0)?.tiffRepresentation))
    XCTAssertEqual(ReactorArtwork.color("ERROR"), .systemRed)
    XCTAssertEqual(ReactorArtwork.color("DISCONNECTED"), .systemGray)
    XCTAssertEqual(ReactorArtwork.color("DONE"), .systemGreen)
  }
  @MainActor func testReleaseFeedbackIsVisualOnlyAndCachedSeparately() throws {
    let normal = try XCTUnwrap(MasterHUBArtwork.jpeg(title:"Open",subtitle:"",state:"IDLE",size:72,symbol:"terminal"))
    let feedback = try XCTUnwrap(MasterHUBArtwork.jpeg(title:"Open",subtitle:"",state:"IDLE",size:72,symbol:"terminal",highlighted:true))
    XCTAssertNotEqual(normal, feedback)
    XCTAssertEqual(normal, MasterHUBArtwork.jpeg(title:"Open",subtitle:"",state:"IDLE",size:72,symbol:"terminal"))
  }
  @MainActor func testInvalidDimensionsFailWithoutAllocating() {
    for size in [Int.min, -1, 0, 513, Int.max] {
      XCTAssertNil(MasterHUBArtwork.jpeg(title: "Project", subtitle: "Ready", state: "IDLE", size: size))
    }
  }
  @MainActor func testRealDisplaySizesProduceDecodableJPEG() throws {
    for size in [72, 240] {
      let data = try XCTUnwrap(MasterHUBArtwork.jpeg(title: String(repeating: "Long project ", count: 15),
        subtitle: "Ready for input", state: "IDLE", size: size))
      let image = try XCTUnwrap(NSBitmapImageRep(data: data))
      XCTAssertEqual(image.pixelsWide, size)
      XCTAssertEqual(image.pixelsHigh, size)
    }
  }
}
