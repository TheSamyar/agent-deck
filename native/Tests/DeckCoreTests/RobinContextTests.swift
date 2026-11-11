import XCTest
@testable import DeckCore
final class RobinContextTests:XCTestCase {
  func testCloudRequiresSourceGrantAndProjectMatch() {
    let now=Date();let values=[RobinContextObservation(id:"one",source:"app:editor",project:"/one",text:"Allowed title",observedAt:now),RobinContextObservation(id:"two",source:"app:editor",project:"/two",text:"Other project",observedAt:now)]
    XCTAssertEqual(RobinContextPolicy.context(values,now:now,project:"/one",cloud:true),"")
    let output=RobinContextPolicy.context(values,now:now,project:"/one",cloud:true,allowedSources:["app:editor"])
    XCTAssertTrue(output.contains("Allowed title"));XCTAssertFalse(output.contains("Other project"))
  }
  func testOldAndFutureObservationsExcluded() {
    let now=Date();let values=[RobinContextObservation(id:"old",source:"agents",text:"Old",observedAt:now.addingTimeInterval(-121)),RobinContextObservation(id:"future",source:"agents",text:"Future",observedAt:now.addingTimeInterval(1))]
    XCTAssertEqual(RobinContextPolicy.context(values,now:now,project:nil,cloud:false),"")
  }
}

final class RobinPersonalHistoryScopeTests:XCTestCase {
  func testPersonalHistoryRequiresExactCurrentSourceGrantFingerprint() {
    let turn=SupervisorMessage(role:"assistant",content:"Personal event evidence",project:"",personalScope:"account:calendar")
    XCTAssertTrue(RobinConversation.history([turn],project:"",cloud:true).isEmpty)
    XCTAssertTrue(RobinConversation.history([turn],project:"",cloud:true,personalScope:"account:gmail").isEmpty)
    XCTAssertEqual(RobinConversation.history([turn],project:"",cloud:true,personalScope:"account:calendar").count,1)
  }
}
