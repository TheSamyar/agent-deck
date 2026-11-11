import XCTest
@testable import DeckCore

final class JarvisPolicyTests: XCTestCase {
  func testModelCannotGrantItselfAppWebsiteOrCommandAccess() {
    let grants = JarvisGrants()
    XCTAssertEqual(JarvisPolicy.authorize(.init(kind: .openApplication, application: "unapproved"), grants: grants), .denied("Application is not approved."))
    XCTAssertEqual(JarvisPolicy.authorize(.init(kind: .navigate, application: "browser", origin: "https://example.com"), grants: grants), .denied("Application is not approved."))
    XCTAssertEqual(JarvisPolicy.authorize(.init(kind: .projectCommand), grants: grants), .denied("An approved project is required."))
  }
  func testPathTraversalIsDeniedAndDestructiveActionsNeedConfirmation() {
    var grants = JarvisGrants(); grants.projects = ["/tmp/project"]; grants.applications = ["editor"]
    XCTAssertEqual(JarvisPolicy.authorize(.init(kind: .writeFile, project: "/tmp/project", path: "/tmp/project/../other/private"), grants: grants), .denied("File is outside the approved project."))
    XCTAssertEqual(JarvisPolicy.authorize(.init(kind: .deleteFile, project: "/tmp/project", path: "/tmp/project/file"), grants: grants), .confirmationRequired)
    XCTAssertEqual(JarvisPolicy.authorize(.init(kind: .sendMessage, application: "editor"), grants: grants), .confirmationRequired)
    XCTAssertEqual(JarvisPolicy.authorize(.init(kind: .purchase), grants: grants), .confirmationRequired)
  }
}
