import XCTest
@testable import DeckCore

final class JarvisFastPathTests: XCTestCase {
  func testOpenUsesExactIdentityWithoutGrantingAccess() {
    let grants=JarvisGrants()
    let step=JarvisFastPath.step(for:"Open Cursor",grants:grants)!
    XCTAssertEqual(step.arguments.application,"com.todesktop.230313mzl4w4u92")
    XCTAssertEqual(JarvisPolicy.authorize(step.proposal!,grants:grants),.denied("Application is not approved."))
  }
  func testExplicitFileReadGetsOnlyContainingApprovedProject() {
    var grants=JarvisGrants();grants.projects=["/tmp/project"]
    let inside=JarvisFastPath.step(for:"read '/tmp/project/file.txt'",grants:grants)!
    XCTAssertEqual(JarvisPolicy.authorize(inside.proposal!,grants:grants),.allowed)
    let outside=JarvisFastPath.step(for:"read '/tmp/private.txt'",grants:grants)!
    XCTAssertEqual(JarvisPolicy.authorize(outside.proposal!,grants:grants),.denied("An approved project is required."))
  }
  func testAmbiguousAndCompoundRequestsUseController() {
    XCTAssertNil(JarvisFastPath.step(for:"open Cursor and delete my files",grants:.init()))
    XCTAssertNil(JarvisFastPath.step(for:"read that file",grants:.init()))
  }
}
